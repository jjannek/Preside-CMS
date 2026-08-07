/**
 * Minimal Future returned by Preside's threaded executor services (see
 * [[api-basethreadedexecutor]]). Replaces the java.util.concurrent Future
 * objects the retired cfconcurrent library used to return.
 *
 * Contract, measured against the actual consumers (AbstractHeartBeat and
 * TaskManagerService): isDone(), isCancelled() and cancel().
 *
 * @nowirebox true
 */
component displayname="TaskFuture" {

	public any function init() {
		variables._status    = "scheduled"; // scheduled | running | done
		variables._cancelled = false;

		return this;
	}

	public boolean function isDone() {
		return variables._cancelled || variables._status == "done";
	}

	public boolean function isCancelled() {
		return variables._cancelled;
	}

	/**
	 * Requests cancellation. Unlike its java.util.concurrent counterpart this
	 * cannot interrupt a run already in flight: it flips the cancelled flag so
	 * the task is never (re)scheduled again and any in-flight run completes
	 * naturally. Returns false only when the task has already completed.
	 */
	public boolean function cancel( boolean mayInterruptIfRunning=true ) {
		if ( variables._status == "done" ) {
			return false;
		}

		variables._cancelled = true;

		return true;
	}

// used by the executor services, not by consumers
	public void function markRunning() {
		variables._status = "running";
	}
	public void function markDone() {
		variables._status = "done";
	}

}
