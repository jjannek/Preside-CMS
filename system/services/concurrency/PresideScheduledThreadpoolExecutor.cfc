/**
 * Scheduler for Preside's recurring background heartbeats. Formerly a thin
 * subclass of cfconcurrent's ScheduledThreadPoolExecutor (java.util.concurrent
 * backed, JVM-only); now implemented on the engine-agnostic
 * [[api-basethreadedexecutor]] with the identical public surface.
 *
 * Scheduling semantics: FIXED-DELAY, permanently (decided 2026-08-07, see
 * docs/cfconcurrent-plan.md section 6.1 in the parent repo). Each run, on
 * completion, schedules the next via a fresh delayed one-shot thread — so the
 * gap between runs is measured from the END of the previous run. The old Java
 * scheduleAtFixedRate measured from the START and burst-caught-up after slow
 * runs; for polling heartbeats fixed-delay is the saner behaviour. The method
 * KEEPS the scheduleAtFixedRate name so the 11 heartbeat consumers are
 * untouched.
 *
 * A further deliberate divergence: a task run that throws does NOT kill the
 * schedule (the error is reported and the next run is scheduled anyway).
 * java.util.concurrent silently suppressed all subsequent runs on the first
 * uncaught exception — a classic footgun for always-on heartbeats.
 *
 * @singleton      true
 * @presideService true
 */
component extends="preside.system.services.concurrency.BaseThreadedExecutor" {

	public any function init() {
		var appName = _getAppName();

		super.init( serviceName="PresideScheduledThreadPool-#appName#" );

		variables._storedTasks = {};

		return this;
	}

// SCHEDULING
	public any function scheduleAtFixedRate(
		  required string  id
		, required any     task
		, required numeric initialDelay
		, required numeric period
		,          string  timeUnit = getObjectFactory().SECONDS
		,          string  hostname = cgi.server_name
	) {
		cancelTask( arguments.id );

		var factory = getObjectFactory();
		var future  = new preside.system.services.concurrency.TaskFuture();

		variables._storedTasks[ arguments.id ] = {
			  task     = arguments.task
			, future   = future
			, periodMs = factory.toMs( arguments.period, arguments.timeUnit )
			, hostname = arguments.hostname
		};

		_spawnTick( arguments.id, factory.toMs( arguments.initialDelay, arguments.timeUnit ) );

		return future;
	}

	public any function cancelTask( required string id ) {
		if ( StructKeyExists( variables._storedTasks, arguments.id ) ) {
			var entry = variables._storedTasks[ arguments.id ];

			entry.future.cancel( true );
			StructDelete( variables._storedTasks, arguments.id );

			return entry;
		}
	}

	/**
	 * Executed from within each tick thread: runs the task once, then
	 * schedules the next tick (fixed-delay). Not for external use.
	 */
	public void function runScheduledTick( required string id ) {
		var entry = variables._storedTasks[ arguments.id ] ?: NullValue();

		if ( IsNull( local.entry ) || entry.future.isCancelled() || isStopped() ) {
			return;
		}

		request.__presideBgThreadHost = entry.hostname;

		entry.future.markRunning();
		try {
			entry.task.run();
		} catch( any e ) {
			try {
				SystemOutput( "[#getServiceName()#] error in scheduled task [#arguments.id#]: #e.message# #e.detail ?: ''#. The schedule continues; next run in #entry.periodMs#ms.", true );
			} catch( any logErr ) {}
		}

		if ( !entry.future.isCancelled() && !isStopped() && StructKeyExists( variables._storedTasks, arguments.id ) ) {
			_spawnTick( arguments.id, entry.periodMs );
		}
	}

// LIFECYCLE
	public any function stop() {
		for( var id in variables._storedTasks ) {
			variables._storedTasks[ id ].future.cancel( true );
		}

		return super.stop();
	}

// shutdown behaviour for when application is reloading
	public void function shutdown(){
		stop();
	}

// MONITORING
	public struct function getStoredTasks() {
		return variables._storedTasks;
	}

	public struct function getTaskStatuses() {
		var tasks     = getStoredTasks();
		var statuses  = StructNew( "linked" );
		var taskNames = StructKeyArray( tasks );

		ArraySort( taskNames, "textnocase" );

		for( var taskName in taskNames ) {
			var future = tasks[ taskName ].future;
			var task   = tasks[ taskName ].task;

			statuses[ taskName ] = {
				  isUp    = !future.isDone() && !future.isCancelled()
				, lastRun = task.getLastRun()
				, uptime  = task.getUptime()
			};
		}

		return statuses;
	}

// private helpers
	private void function _spawnTick( required string id, required numeric delayMs ) {
		var threadName = "#getServiceName()#-tick-#CreateUUId()#";

		thread name=threadName xid=arguments.id xdelay=arguments.delayMs xexecutor=this {
			if ( attributes.xdelay > 0 ) {
				sleep( attributes.xdelay );
			}
			attributes.xexecutor.runScheduledTick( attributes.xid );
		}
	}

	private string function _getAppName() {
		var appSettings = getApplicationMetadata();

		return appSettings.PRESIDE_APPLICATION_ID ?: ( appSettings.name ?: "" );
	}

}
