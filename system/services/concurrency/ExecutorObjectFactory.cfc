/**
 * Replacement for the one slice of cfconcurrent's ObjectFactory that Preside
 * actually consumed: the TimeUnit constants (only MILLISECONDS is read, by
 * AbstractHeartBeat) plus unit-to-milliseconds conversion for the executor
 * services. The constants are plain strings, not java.util.concurrent.TimeUnit
 * objects — no consumer does more than pass them back into the executor.
 *
 * @nowirebox true
 */
component displayname="ExecutorObjectFactory" {

	this.NANOSECONDS  = "NANOSECONDS";
	this.MICROSECONDS = "MICROSECONDS";
	this.MILLISECONDS = "MILLISECONDS";
	this.SECONDS      = "SECONDS";
	this.MINUTES      = "MINUTES";
	this.HOURS        = "HOURS";
	this.DAYS         = "DAYS";

	public any function init() {
		return this;
	}

	public numeric function toMs( required numeric value, required string unit ) {
		switch( UCase( arguments.unit ) ) {
			case "NANOSECONDS" : return arguments.value / 1000000;
			case "MICROSECONDS": return arguments.value / 1000;
			case "MILLISECONDS": return arguments.value;
			case "SECONDS"     : return arguments.value * 1000;
			case "MINUTES"     : return arguments.value * 60000;
			case "HOURS"       : return arguments.value * 3600000;
			case "DAYS"        : return arguments.value * 86400000;
		}

		throw( type="preside.executor.badTimeUnit", message="Unknown time unit [#arguments.unit#] passed to executor service." );
	}

}
