/**
 * Provides logic for extracting XMP metadata from an image file
 *
 * XMP parsing needs the bundled `xmpcore.jar`, which requires a JVM. Where no JVM is
 * available (RustCFML), building that factory throws — and because this is a singleton
 * built during application startup, that used to abort the whole boot rather than just
 * disable metadata extraction. XMP metadata is an enrichment on asset upload, not
 * something the application should refuse to start without.
 *
 * So an unavailable factory now degrades to "no metadata": readMeta() returns an empty
 * struct, exactly as it already does for a file with no XMP embedded. The condition is
 * announced once at startup rather than passed over quietly — a reader that silently
 * returns nothing forever is far harder to diagnose than one that says so.
 *
 * @autodoc
 * @singleton
 */
component {

	public function init() {
		_setupMetaFactory();

		return this;
	}

	/**
	 * Whether XMP metadata extraction is actually available in this environment.
	 * False when the underlying XMP library could not be loaded, in which case
	 * readMeta() always returns an empty struct.
	 *
	 * @autodoc
	 */
	public boolean function isAvailable() {
		return variables._available ?: false;
	}

	/**
	 * Returns a structure of found XMP metadata
	 * from the provided file binary. Returns an
	 * empty structure if no data found.
	 *
	 * @autodoc
	 * @filecontent.help The binary of the file to read meta from
	 *
	 */
	public struct function readMeta( required binary fileContent ) {
		if ( !isAvailable() ) {
			return {};
		}

		var source    = ToString( fileContent );
		var regex     = "^.*(<x:xmpmeta.*<\/x:xmpmeta>).*$";
		var xmp       = ReReplace( source, regex, "\1" );
		var extracted = {};

		if ( xmp.len() < source.len() && IsXml( xmp ) ) {
			var meta     = _getMetaFactory().parseFromString( Trim( xmp ) );
			var iterator = meta.iterator();

			while( iterator.hasNext() ) {
				var prop  = iterator.next();
				var path  = prop.getPath();
				var value = prop.getValue();

				if ( Len( Trim( path ?: "" ) ) && Len( Trim( value ?: "" ) ) ) {
					path = ListRest( path, ":" );
					path = ReReplace( path, "\[[0-9]+\]", "", "all" );

					extracted[ path ] = value;
				}
			}
		}

		return extracted;
	}

// PRIVATE HELPERS
	private void function _setupMetaFactory() {
		var lib = [ GetDirectoryFromPath( GetCurrentTemplatePath() ) & "/xmpcore.jar" ];

		try {
			_setMetaFactory( CreateObject( "java", "com.adobe.xmp.XMPMetaFactory", lib ) );
			variables._available = true;
		} catch ( any e ) {
			// No JVM / no xmpcore: disable extraction rather than abort application startup.
			variables._available = false;

			SystemOutput(
				"Preside System Output: XMP metadata extraction is DISABLED - the XMP library "
				& "could not be loaded ([#( e.message ?: '' )#]). Asset uploads will still work, "
				& "but no XMP metadata will be read from them." & Chr( 13 ) & Chr( 10 )
			);
		}
	}

// GETTERS AND SETTERS
	private any function _getMetaFactory() {
		return _factory;
	}
	private void function _setMetaFactory( required any factory ) {
		_factory = arguments.factory;
	}
}