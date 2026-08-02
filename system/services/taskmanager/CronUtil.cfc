/**
 * Service providing cron parsing and other cron related utility functions.
 *
 * Cron expressions use Quartz syntax and are parsed natively, in CFML.
 *
 * This previously delegated to the `cron-utils` Java library, loaded at runtime through
 * Lucee's OSGi machinery (`lucee.loader.engine.CFMLEngineFactory` +
 * `lucee.runtime.osgi.OSGiUtil`). That is JVM- and Lucee-specific, so it cannot run on
 * rustcfml — it was the single hard blocker for booting the application there. The
 * behaviour below is a like-for-like replacement, validated against the previous
 * implementation on Lucee.
 *
 * Supported per field: `*`, `?`, single values, lists (`1,2`), ranges (`1-5`), steps
 * (`*&##47;5`, `5/10`, `1-30/5`), month/day names (`JAN`..`DEC`, `SUN`..`SAT`) and the Quartz
 * specials `L`, `L-n`, `LW`, `nW` (day-of-month) and `nL`, `n#m` (day-of-week).
 *
 * NOTE: descriptions returned by describeCronTabExression() are English only. The Java
 * library localised them via `CronDescriptor`; there is no equivalent here and Preside
 * ships no i18n keys for cron descriptions.
 *
 * @singleton      true
 * @presideService true
 */
component displayName="Cron util" {

// CONSTRUCTOR
	public any function init() {
		variables._monthNames = { JAN=1, FEB=2, MAR=3, APR=4, MAY=5, JUN=6, JUL=7, AUG=8, SEP=9, OCT=10, NOV=11, DEC=12 };
		variables._dayNames   = { SUN=1, MON=2, TUE=3, WED=4, THU=5, FRI=6, SAT=7 };
		variables._dayLabels  = [ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" ];
		variables._monthLabels= [ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" ];

		return this;
	}

// PUBLIC API METHODS
	public string function validateExpression( required string crontabExpression ) {
		try {
			_parseExpression( arguments.crontabExpression );
		} catch ( any e ) {
			return e.message;
		}

		return "";
	}

	public string function getNextRunDate( required string crontabExpression, date lastRun=Now() ) {
		if ( arguments.crontabExpression == "disabled" ) {
			return "";
		}

		var parsed  = _parseExpression( arguments.crontabExpression );
		var nextRun = _calculateNextRun( parsed, arguments.lastRun );

		if ( !IsDate( nextRun ) ) {
			return "";
		}

		return DateFormat( nextRun, "yyyy-mm-dd" ) & "T" & TimeFormat( nextRun, "HH:mm:ss" );
	}

	public string function describeCronTabExression( required string crontabExpression, required string locale ) {
		if ( arguments.crontabExpression == "disabled" ) {
			return "disabled";
		}

		return _describe( _parseExpression( arguments.crontabExpression ) );
	}


// PRIVATE HELPERS: PARSING
	private struct function _parseExpression( required string expression ) {
		var fields = ListToArray( Trim( _convertToValidQuartzCron( arguments.expression ) ), " " );

		if ( ArrayLen( fields ) < 6 || ArrayLen( fields ) > 7 ) {
			throw(
				  type    = "preside.cron.invalid"
				, message = "Invalid cron expression [#arguments.expression#]. Expected 6 or 7 space separated fields (second minute hour day-of-month month day-of-week [year]) but received #ArrayLen( fields )#."
			);
		}

		if ( Trim( fields[ 4 ] ) == "?" && Trim( fields[ 6 ] ) == "?" ) {
			throw(
				  type    = "preside.cron.invalid"
				, message = "Invalid cron expression [#arguments.expression#]. Day-of-month and day-of-week cannot both be '?'."
			);
		}

		var parsed = {
			  seconds        = _parseNumericField( fields[ 1 ], 0, 59, "second" )
			, minutes        = _parseNumericField( fields[ 2 ], 0, 59, "minute" )
			, hours          = _parseNumericField( fields[ 3 ], 0, 23, "hour"   )
			, months         = _parseNumericField( fields[ 5 ], 1, 12, "month", variables._monthNames )
			, years          = ArrayLen( fields ) == 7 ? _parseNumericField( fields[ 7 ], 1970, 2199, "year" ) : []
			, useDayOfMonth  = Trim( fields[ 4 ] ) != "?"
			, raw            = {
				  second     = Trim( fields[ 1 ] )
				, minute     = Trim( fields[ 2 ] )
				, hour       = Trim( fields[ 3 ] )
				, dayOfMonth = Trim( fields[ 4 ] )
				, month      = Trim( fields[ 5 ] )
				, dayOfWeek  = Trim( fields[ 6 ] )
				, year       = ArrayLen( fields ) == 7 ? Trim( fields[ 7 ] ) : ""
			  }
		};

		StructAppend( parsed, _parseDayOfMonthField( fields[ 4 ] ) );
		StructAppend( parsed, _parseDayOfWeekField( fields[ 6 ] ) );

		return parsed;
	}

	/**
	 * Quartz does not allow both day-of-month and day-of-week to be specified;
	 * replace one with '?' when both are used. (Unchanged from the original.)
	 */
	private string function _convertToValidQuartzCron( expression ) {
		var expressions = ListToArray( arguments.expression, " " );

		if ( ArrayLen( expressions ) >= 6 ) {
			if ( expressions[ 4 ] == "*" && expressions[ 6 ] != "?" ) {
				expressions[ 4 ] = "?";
			} else if ( expressions[ 4 ] != "?" ) {
				expressions[ 6 ] = "?"
			}
		}

		return ArrayToList( expressions, " " );
	}

	private struct function _parseDayOfMonthField( required string value ) {
		var result = { daysOfMonth=[], domLast=false, domLastOffset=0, domLastWeekday=false, domNearestWeekdays=[] };
		var field  = Trim( arguments.value );

		if ( field == "?" ) {
			return result;
		}

		var plain = [];
		var parts = ListToArray( field, "," );

		for( var i=1; i<=ArrayLen( parts ); i++ ) {
			var part = Trim( parts[ i ] );

			if ( part == "L" ) {
				result.domLast = true;
			} else if ( part == "LW" ) {
				result.domLastWeekday = true;
			} else if ( ReFindNoCase( "^L-[0-9]+$", part ) ) {
				result.domLast       = true;
				result.domLastOffset = Val( ListLast( part, "-" ) );
			} else if ( ReFindNoCase( "^[0-9]+W$", part ) ) {
				ArrayAppend( result.domNearestWeekdays, Val( Left( part, Len( part )-1 ) ) );
			} else {
				ArrayAppend( plain, part );
			}
		}

		if ( ArrayLen( plain ) ) {
			result.daysOfMonth = _parseNumericField( ArrayToList( plain, "," ), 1, 31, "day-of-month" );
		}

		return result;
	}

	private struct function _parseDayOfWeekField( required string value ) {
		var result = { daysOfWeek=[], dowLast=[], dowNth=[] };
		var field  = Trim( arguments.value );

		if ( field == "?" ) {
			return result;
		}

		var plain = [];
		var parts = ListToArray( field, "," );

		for( var i=1; i<=ArrayLen( parts ); i++ ) {
			var part = Trim( parts[ i ] );

			if ( ReFindNoCase( "^[0-9A-Z]+L$", part ) && part != "L" ) {
				ArrayAppend( result.dowLast, _fieldValueToNumber( Left( part, Len( part )-1 ), variables._dayNames, "day-of-week", 1, 7 ) );
			} else if ( Find( "##", part ) ) {
				var nthParts = ListToArray( part, "##" );
				if ( ArrayLen( nthParts ) != 2 || !IsNumeric( nthParts[ 2 ] ) ) {
					throw( type="preside.cron.invalid", message="Invalid day-of-week value [#part#]. Expected the form <day>##<nth>, e.g. 6##3." );
				}
				ArrayAppend( result.dowNth, {
					  dow = _fieldValueToNumber( nthParts[ 1 ], variables._dayNames, "day-of-week", 1, 7 )
					, nth = Val( nthParts[ 2 ] )
				} );
			} else {
				ArrayAppend( plain, part );
			}
		}

		if ( ArrayLen( plain ) ) {
			result.daysOfWeek = _parseNumericField( ArrayToList( plain, "," ), 1, 7, "day-of-week", variables._dayNames );
		}

		return result;
	}

	private array function _parseNumericField(
		  required string  value
		, required numeric minValue
		, required numeric maxValue
		, required string  fieldName
		,          struct  names = {}
	) {
		var field = Trim( arguments.value );
		var parts = ListToArray( field, "," );

		if ( !ArrayLen( parts ) ) {
			throw( type="preside.cron.invalid", message="Invalid #arguments.fieldName# value []. The field cannot be empty." );
		}

		var allowed = {};

		for( var i=1; i<=ArrayLen( parts ); i++ ) {
			var part = Trim( parts[ i ] );
			var step = 1;

			if ( Find( "/", part ) ) {
				var stepParts = ListToArray( part, "/" );

				if ( ArrayLen( stepParts ) != 2 || !IsNumeric( Trim( stepParts[ 2 ] ) ) || Val( stepParts[ 2 ] ) < 1 ) {
					throw( type="preside.cron.invalid", message="Invalid #arguments.fieldName# value [#part#]. Step values must take the form <range>/<positive number>." );
				}

				step = Val( stepParts[ 2 ] );
				part = Trim( stepParts[ 1 ] );
			}

			var rangeStart = arguments.minValue;
			var rangeEnd   = arguments.maxValue;

			if ( part == "*" || part == "?" ) {
				// full range
			} else if ( Find( "-", part ) ) {
				var rangeParts = ListToArray( part, "-" );

				if ( ArrayLen( rangeParts ) != 2 ) {
					throw( type="preside.cron.invalid", message="Invalid #arguments.fieldName# range [#part#]. Expected the form <from>-<to>." );
				}

				rangeStart = _fieldValueToNumber( rangeParts[ 1 ], arguments.names, arguments.fieldName, arguments.minValue, arguments.maxValue );
				rangeEnd   = _fieldValueToNumber( rangeParts[ 2 ], arguments.names, arguments.fieldName, arguments.minValue, arguments.maxValue );
			} else {
				rangeStart = _fieldValueToNumber( part, arguments.names, arguments.fieldName, arguments.minValue, arguments.maxValue );
				rangeEnd   = step > 1 ? arguments.maxValue : rangeStart;
			}

			if ( rangeEnd < rangeStart ) {
				// wrap-around range, e.g. FRI-MON / 11-2
				for( var v=rangeStart; v<=arguments.maxValue; v+=step ) { allowed[ v ] = true; }
				for( var v=arguments.minValue; v<=rangeEnd; v+=step ) { allowed[ v ] = true; }
			} else {
				for( var v=rangeStart; v<=rangeEnd; v+=step ) { allowed[ v ] = true; }
			}
		}

		var result = [];
		for( var key in allowed ) {
			ArrayAppend( result, Val( key ) );
		}
		ArraySort( result, "numeric" );

		return result;
	}

	private numeric function _fieldValueToNumber(
		  required string  token
		, required struct  names
		, required string  fieldName
		, required numeric minValue
		, required numeric maxValue
	) {
		var value = Trim( arguments.token );
		var num   = 0;

		if ( StructKeyExists( arguments.names, value ) ) {
			num = arguments.names[ value ];
		} else if ( IsNumeric( value ) ) {
			num = Val( value );

			// Quartz numbers days of the week 1(SUN)-7(SAT); tolerate the standard-cron 0 for Sunday
			if ( arguments.fieldName == "day-of-week" && num == 0 ) {
				num = 1;
			}
		} else {
			throw( type="preside.cron.invalid", message="Invalid #arguments.fieldName# value [#value#]. Expected a number#StructCount( arguments.names ) ? " or name" : ""# between #arguments.minValue# and #arguments.maxValue#." );
		}

		if ( num < arguments.minValue || num > arguments.maxValue ) {
			throw( type="preside.cron.invalid", message="Invalid #arguments.fieldName# value [#value#]. Must be between #arguments.minValue# and #arguments.maxValue#." );
		}

		return num;
	}


// PRIVATE HELPERS: NEXT RUN CALCULATION
	private any function _calculateNextRun( required struct parsed, required date fromDate ) {
		var p     = arguments.parsed;
		var dt    = DateAdd( "s", 1, _truncateToSecond( arguments.fromDate ) );
		var limit = DateAdd( "yyyy", 8, dt );

		while( DateCompare( dt, limit ) < 0 ) {
			if ( ArrayLen( p.years ) && !_arrayHasValue( p.years, Year( dt ) ) ) {
				var nextYear = _nextAllowedValue( p.years, Year( dt ) );
				if ( nextYear < 0 ) {
					return "";
				}
				dt = CreateDateTime( nextYear, 1, 1, 0, 0, 0 );
				continue;
			}

			if ( !_arrayHasValue( p.months, Month( dt ) ) ) {
				dt = _startOfNextMonth( dt );
				continue;
			}

			if ( !_dayMatches( p, dt ) ) {
				dt = _startOfNextDay( dt );
				continue;
			}

			if ( !_arrayHasValue( p.hours, Hour( dt ) ) ) {
				var nextHour = _nextAllowedValue( p.hours, Hour( dt ) );
				if ( nextHour < 0 ) {
					dt = _startOfNextDay( dt );
				} else {
					dt = CreateDateTime( Year( dt ), Month( dt ), Day( dt ), nextHour, 0, 0 );
				}
				continue;
			}

			if ( !_arrayHasValue( p.minutes, Minute( dt ) ) ) {
				var nextMinute = _nextAllowedValue( p.minutes, Minute( dt ) );
				if ( nextMinute < 0 ) {
					dt = _startOfNextHour( dt );
				} else {
					dt = CreateDateTime( Year( dt ), Month( dt ), Day( dt ), Hour( dt ), nextMinute, 0 );
				}
				continue;
			}

			if ( !_arrayHasValue( p.seconds, Second( dt ) ) ) {
				var nextSecond = _nextAllowedValue( p.seconds, Second( dt ) );
				if ( nextSecond < 0 ) {
					dt = _startOfNextMinute( dt );
				} else {
					dt = CreateDateTime( Year( dt ), Month( dt ), Day( dt ), Hour( dt ), Minute( dt ), nextSecond );
				}
				continue;
			}

			return dt;
		}

		return "";
	}

	private boolean function _dayMatches( required struct parsed, required date dt ) {
		var p       = arguments.parsed;
		var dayNum  = Day( arguments.dt );
		var lastDay = DaysInMonth( arguments.dt );

		if ( p.useDayOfMonth ) {
			if ( _arrayHasValue( p.daysOfMonth, dayNum ) ) {
				return true;
			}
			if ( p.domLast && dayNum == ( lastDay - p.domLastOffset ) ) {
				return true;
			}
			if ( p.domLastWeekday && dayNum == _lastWeekdayOfMonth( arguments.dt ) ) {
				return true;
			}
			for( var target in p.domNearestWeekdays ) {
				if ( dayNum == _nearestWeekday( arguments.dt, target ) ) {
					return true;
				}
			}

			return false;
		}

		var dowNum = DayOfWeek( arguments.dt );

		if ( _arrayHasValue( p.daysOfWeek, dowNum ) ) {
			return true;
		}
		for( var lastDow in p.dowLast ) {
			if ( dowNum == lastDow && ( dayNum + 7 ) > lastDay ) {
				return true;
			}
		}
		for( var nth in p.dowNth ) {
			if ( dowNum == nth.dow && Ceiling( dayNum / 7 ) == nth.nth ) {
				return true;
			}
		}

		return false;
	}

	private numeric function _lastWeekdayOfMonth( required date dt ) {
		var day = DaysInMonth( arguments.dt );

		while( day > 1 ) {
			var dow = DayOfWeek( CreateDate( Year( arguments.dt ), Month( arguments.dt ), day ) );
			if ( dow != 1 && dow != 7 ) {
				break;
			}
			day--;
		}

		return day;
	}

	private numeric function _nearestWeekday( required date dt, required numeric target ) {
		var lastDay = DaysInMonth( arguments.dt );
		var day     = Min( arguments.target, lastDay );
		var dow     = DayOfWeek( CreateDate( Year( arguments.dt ), Month( arguments.dt ), day ) );

		if ( dow == 1 ) { // Sunday -> Monday, unless that leaves the month
			day = ( day + 1 ) <= lastDay ? day + 1 : day - 2;
		} else if ( dow == 7 ) { // Saturday -> Friday, unless that leaves the month
			day = ( day - 1 ) >= 1 ? day - 1 : day + 2;
		}

		return day;
	}


// PRIVATE HELPERS: DESCRIPTION
	private string function _describe( required struct parsed ) {
		var description = _describeTimePart( arguments.parsed )
		                & _describeDayPart( arguments.parsed )
		                & _describeMonthPart( arguments.parsed );

		return Trim( description );
	}

	private string function _describeTimePart( required struct parsed ) {
		var p = arguments.parsed;

		// the common, readable case: one specific time of day
		if ( ArrayLen( p.seconds ) == 1 && ArrayLen( p.minutes ) == 1 && ArrayLen( p.hours ) == 1 ) {
			var time = "At " & _twoDigit( p.hours[ 1 ] ) & ":" & _twoDigit( p.minutes[ 1 ] );
			return p.seconds[ 1 ] ? time & ":" & _twoDigit( p.seconds[ 1 ] ) : time;
		}

		var bits = [];
		var add  = function( required string bit ) {
			if ( Len( arguments.bit ) ) {
				ArrayAppend( bits, arguments.bit );
			}
		};

		add( _describeUnit( p.seconds, p.raw.second, 60, "second" ) );
		add( _describeUnit( p.minutes, p.raw.minute, 60, "minute" ) );
		add( _describeUnit( p.hours  , p.raw.hour  , 24, "hour"   ) );

		if ( !ArrayLen( bits ) ) {
			return "Every second";
		}

		return _ucFirst( ArrayToList( bits, ", " ) );
	}

	private string function _describeUnit(
		  required array   values
		, required string  raw
		, required numeric total
		, required string  noun
	) {
		if ( ArrayLen( arguments.values ) == arguments.total ) {
			return "every " & arguments.noun;
		}
		if ( ReFind( "^\*/[0-9]+$", arguments.raw ) ) {
			return "every " & ListLast( arguments.raw, "/" ) & " " & arguments.noun & "s";
		}
		if ( ArrayLen( arguments.values ) == 1 ) {
			return "at " & arguments.noun & " " & arguments.values[ 1 ];
		}

		return "at " & arguments.noun & "s " & ArrayToList( arguments.values, ", " );
	}

	private string function _describeDayPart( required struct parsed ) {
		var p = arguments.parsed;

		if ( p.useDayOfMonth ) {
			if ( p.domLastWeekday ) {
				return ", on the last weekday of the month";
			}
			if ( p.domLast ) {
				return p.domLastOffset ? ", #p.domLastOffset# day(s) before the end of the month" : ", on the last day of the month";
			}
			if ( ArrayLen( p.domNearestWeekdays ) ) {
				return ", on the weekday nearest day " & ArrayToList( p.domNearestWeekdays, ", " );
			}
			if ( ArrayLen( p.daysOfMonth ) && ArrayLen( p.daysOfMonth ) < 31 ) {
				return ", on day " & ArrayToList( p.daysOfMonth, ", " ) & " of the month";
			}

			return "";
		}

		if ( ArrayLen( p.dowLast ) ) {
			return ", on the last " & _dayLabelList( p.dowLast ) & " of the month";
		}
		if ( ArrayLen( p.dowNth ) ) {
			var nths = [];
			for( var nth in p.dowNth ) {
				ArrayAppend( nths, "##" & nth.nth & " " & variables._dayLabels[ nth.dow ] );
			}
			return ", on the " & ArrayToList( nths, ", " ) & " of the month";
		}
		if ( ArrayLen( p.daysOfWeek ) && ArrayLen( p.daysOfWeek ) < 7 ) {
			return ", on " & _dayLabelList( p.daysOfWeek );
		}

		return "";
	}

	private string function _describeMonthPart( required struct parsed ) {
		var months = arguments.parsed.months;

		if ( !ArrayLen( months ) || ArrayLen( months ) == 12 ) {
			return "";
		}

		var labels = [];
		for( var m in months ) {
			ArrayAppend( labels, variables._monthLabels[ m ] );
		}

		return ", in " & ArrayToList( labels, ", " );
	}

	private string function _dayLabelList( required array days ) {
		var labels = [];

		for( var d in arguments.days ) {
			ArrayAppend( labels, variables._dayLabels[ d ] );
		}

		return ArrayToList( labels, ", " );
	}


// PRIVATE HELPERS: SMALL UTILITIES
	private boolean function _arrayHasValue( required array values, required numeric value ) {
		return ArrayFind( arguments.values, arguments.value ) > 0;
	}

	/**
	 * Smallest allowed value >= `from`, or -1 when there is none. Only called when the
	 * current value is NOT allowed, so a valid answer is always strictly greater.
	 */
	private numeric function _nextAllowedValue( required array values, required numeric from ) {
		for( var v in arguments.values ) {
			if ( v >= arguments.from ) {
				return v;
			}
		}

		return -1;
	}

	private date function _truncateToSecond( required date dt ) {
		return CreateDateTime( Year( arguments.dt ), Month( arguments.dt ), Day( arguments.dt ), Hour( arguments.dt ), Minute( arguments.dt ), Second( arguments.dt ) );
	}

	private date function _startOfNextMinute( required date dt ) {
		return DateAdd( "n", 1, CreateDateTime( Year( arguments.dt ), Month( arguments.dt ), Day( arguments.dt ), Hour( arguments.dt ), Minute( arguments.dt ), 0 ) );
	}

	private date function _startOfNextHour( required date dt ) {
		return DateAdd( "h", 1, CreateDateTime( Year( arguments.dt ), Month( arguments.dt ), Day( arguments.dt ), Hour( arguments.dt ), 0, 0 ) );
	}

	private date function _startOfNextDay( required date dt ) {
		return DateAdd( "d", 1, CreateDateTime( Year( arguments.dt ), Month( arguments.dt ), Day( arguments.dt ), 0, 0, 0 ) );
	}

	private date function _startOfNextMonth( required date dt ) {
		return DateAdd( "m", 1, CreateDateTime( Year( arguments.dt ), Month( arguments.dt ), 1, 0, 0, 0 ) );
	}

	private string function _twoDigit( required numeric value ) {
		return NumberFormat( arguments.value, "00" );
	}

	private string function _ucFirst( required string text ) {
		return Len( arguments.text ) ? UCase( Left( arguments.text, 1 ) ) & Right( arguments.text, Len( arguments.text )-1 ) : "";
	}

}
