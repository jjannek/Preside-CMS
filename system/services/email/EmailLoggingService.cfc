/**
 * Service that provides logic for logging email sends and updates to email delivery status
 *
 * @autodoc        true
 * @singleton      true
 * @presideService true
 */
component {

// CONSTRUCTOR
	/**
	 * @recipientTypeService.inject emailRecipientTypeService
	 *
	 */
	public any function init( required any recipientTypeService ) {
		_setRecipientTypeService( arguments.recipientTypeService );

		return this;
	}

// PUBLIC API METHODS
	/**
	 * Creates an email log entry and returns its ID (useful for future
	 * status updates to email delivery)
	 *
	 * @autodoc            true
	 * @template.hint      ID of the email template that is being sent
	 * @recipientType.hint ID of the recipient type configured for the template
	 * @recipient.hint     email address of the recipient
	 * @sender.hint        email address of the sender
	 * @subject.hint       Subject line of the email
	 * @sendArgs.hint      Structure of args that were original sent to the email send() method
	 */
	public string function createEmailLog(
		  required string template
		, required string recipientType
		, required string recipientId
		, required string recipient
		, required string sender
		, required string subject
		,          struct sendArgs = {}
	) {
		var data = {
			  email_template = arguments.template
			, recipient      = arguments.recipient
			, sender         = arguments.sender
			, subject        = arguments.subject
		};

		if ( Len( Trim( arguments.recipientType ) ) ) {
			data.append( _getAdditionalDataForRecipientType( arguments.recipientType, arguments.recipientId, arguments.sendArgs ) );
		}

		return $getPresideObject( "email_template_send_log" ).insertData( data );
	}

	/**
	 * Marks the given email as sent
	 *
	 * @autodoc true
	 * @id.hint ID of the email to mark as sent
	 *
	 */
	public void function markAsSent( required string id ) {
		$getPresideObject( "email_template_send_log" ).updateData( id=arguments.id, data={
			  sent      = true
			, sent_date = _getNow()
		} );
	}


// PRIVATE HELPERS
	private struct function _getAdditionalDataForRecipientType( required string recipientType, required string recipientId, required struct sendArgs ) {
		if ( !recipientType.len() ) {
			return {};
		}

		var fkColumn = _getRecipientTypeService().getRecipientIdLogPropertyForRecipientType( recipientType );

		if ( !fkColumn.len() ){
			return {};
		}

		return { "#fkColumn#" = arguments.recipientId };
	}

	private date function _getNow() {
		return Now(); // abstracting this makes testing easier
	}

// GETTERS AND SETTERS
	private any function _getRecipientTypeService() {
		return _recipientTypeService;
	}
	private void function _setRecipientTypeService( required any recipientTypeService ) {
		_recipientTypeService = arguments.recipientTypeService;
	}

}