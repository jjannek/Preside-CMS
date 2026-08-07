/**
 * Engine-agnostic replacement for the cfconcurrent executor services
 * (retired 2026-08: JVM-only — java.util.concurrent pools + a Lucee-internal
 * Java proxy jar — and therefore impossible on rustcfml).
 *
 * Exposes exactly the lifecycle + submission surface Preside consumed from
 * cfconcurrent's AbstractExecutorService/ExecutorService, implemented on
 * plain cfthread so the identical code runs on both Lucee and rustcfml.
 *
 * Deliberate behaviour notes (vs the Java-backed original):
 *  - Bounded concurrency is enforced with an internal counter + FIFO queue
 *    rather than a thread pool. When the queue overflows, the task is
 *    dropped LOUDLY (SystemOutput + future marked cancelled) — the Java
 *    DiscardPolicy dropped it silently and left the future pending forever.
 *  - cancel() on a running task cannot interrupt the thread; it prevents any
 *    further scheduling and the in-flight run completes naturally. Hard task
 *    interruption remains ThreadUtil's job, as before.
 *  - The multi-site hostname is delivered to worker threads via
 *    request.__presideBgThreadHost, which RequestContextDecorator's
 *    getServerName() consults, so autoSetSiteByHost() resolves the same site
 *    it did under cfconcurrent's Java proxy (which faked the servlet request's
 *    server name instead).
 *  - cfconcurrent's storage-scope plumbing (getBaseStorageScope() etc.) and
 *    logMessage() had no consumers outside cfconcurrent itself — consciously
 *    dropped, not ported.
 *
 * NB: no closures are used for shared-state mutation in this service — rustcfml
 * closures capture enclosing scopes by copy, so mutations from a closure would
 * be lost. Plain lock blocks only.
 *
 * NB2: deliberately NOT annotated with nowirebox — Preside's binder filter
 * (config/WireBox.cfc:_containsNoWireboxInstruction) walks the EXTENDS chain,
 * so nowirebox here would silently filter the executor subclasses out of
 * registration too (found the hard way via app-smoke: "requested a missing
 * dependency ... presideTaskManagerExecutor"). Being registered but never
 * requested by name is harmless, like AbstractHeartBeat.
 */
component displayname="BaseThreadedExecutor" {

	public any function init(
		  required string  serviceName
		,          numeric maxConcurrent     = 0
		,          numeric maxWorkQueueSize  = 10000
		,          string  threadNamePattern = ""
	) {
		variables._serviceName   = arguments.serviceName;
		variables._maxConcurrent = arguments.maxConcurrent > 0 ? arguments.maxConcurrent : _defaultConcurrency();
		variables._maxQueueSize  = arguments.maxWorkQueueSize;
		variables._status        = "stopped";
		variables._activeCount   = 0;
		variables._workQueue     = [];
		variables._objectFactory = new preside.system.services.concurrency.ExecutorObjectFactory();

		return this;
	}

// LIFECYCLE (names + semantics preserved from cfconcurrent)
	public any function start() {
		variables._status = "started";
		return this;
	}

	public any function stop() {
		lock name="#getServiceName()#-state" type="exclusive" timeout=10 {
			for( var queued in variables._workQueue ) {
				queued.future.cancel( true );
			}
			variables._workQueue = [];
			variables._status    = "stopped";
		}

		return this;
	}

	public void function shutdown() {
		stop();
	}

	public any function pause() {
		variables._status = "paused";
		return this;
	}

	public any function unPause() {
		if ( isStopped() ) {
			start();
		} else {
			variables._status = "started";
		}
		return this;
	}

	public string  function getStatus()  { return variables._status; }
	public boolean function isStarted()  { return getStatus() == "started"; }
	public boolean function isStopped()  { return getStatus() == "stopped"; }
	public boolean function isPaused()   { return getStatus() == "paused";  }

// SUBMISSION
	/**
	 * Submits a task (an object exposing call() or run()) for one-shot
	 * background execution. Returns a TaskFuture.
	 */
	public any function submit( any task, string hostname=cgi.server_name ) {
		if ( isStarted() ) {
			var future   = new preside.system.services.concurrency.TaskFuture();
			var launched = false;
			var dropped  = false;

			lock name="#getServiceName()#-state" type="exclusive" timeout=10 {
				if ( variables._activeCount < variables._maxConcurrent ) {
					variables._activeCount++;
					launched = true;
				} else if ( ArrayLen( variables._workQueue ) < variables._maxQueueSize ) {
					ArrayAppend( variables._workQueue, { task=arguments.task, future=future, hostname=arguments.hostname } );
				} else {
					dropped = true;
				}
			}

			if ( launched ) {
				_spawnWorker( arguments.task, future, arguments.hostname );
			} else if ( dropped ) {
				future.cancel( true );
				SystemOutput( "[#getServiceName()#] work queue full (#variables._maxQueueSize#) - task DROPPED. This suggests background work is being submitted far faster than it completes.", true );
			}

			return future;
		} else if ( isPaused() ) {
			SystemOutput( "[#getServiceName()#] Service paused... ignoring submission", true );
		} else if ( isStopped() ) {
			throw( "Service is stopped... not accepting new tasks" );
		}
	}

	/**
	 * Called from worker threads when a run completes; releases the slot and
	 * launches the next queued task, if any.
	 */
	public void function workerFinished() {
		var next = NullValue();

		lock name="#getServiceName()#-state" type="exclusive" timeout=10 {
			variables._activeCount--;
			if ( isStarted() && ArrayLen( variables._workQueue ) ) {
				next = variables._workQueue[ 1 ];
				ArrayDeleteAt( variables._workQueue, 1 );
				variables._activeCount++;
			}
		}

		if ( !IsNull( local.next ) ) {
			_spawnWorker( next.task, next.future, next.hostname );
		}
	}

// SHARED WITH SUBCLASSES
	public string function getServiceName() {
		return variables._serviceName;
	}

	public any function getObjectFactory() {
		return variables._objectFactory;
	}

	public numeric function getMaxConcurrent() {
		return variables._maxConcurrent;
	}

// PRIVATE
	private void function _spawnWorker( required any task, required any future, required string hostname ) {
		var threadName = "#getServiceName()#-worker-#CreateUUId()#";

		thread name=threadName xtask=arguments.task xfuture=arguments.future xhost=arguments.hostname xexecutor=this {
			request.__presideBgThreadHost = attributes.xhost;

			try {
				attributes.xfuture.markRunning();
				if ( StructKeyExists( attributes.xtask, "call" ) ) {
					attributes.xtask.call();
				} else {
					attributes.xtask.run();
				}
			} catch( any e ) {
				try {
					SystemOutput( "[#attributes.xexecutor.getServiceName()#] uncaught error in background task: #e.message# #e.detail ?: ''#", true );
				} catch( any logErr ) {}
			}

			attributes.xfuture.markDone();
			attributes.xexecutor.workerFinished();
		}
	}

	private numeric function _defaultConcurrency() {
		try {
			return CreateObject( "java", "java.lang.Runtime" ).getRuntime().availableProcessors() + 1;
		} catch( any e ) {
			return 8;
		}
	}

}
