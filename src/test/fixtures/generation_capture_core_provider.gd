extends CoreProvider
## Capture the real Core payload boundary without a backend connection.
var payload: Dictionary = {}

func generate_content(prompt: Array[Variant], params: Dictionary = {}):
	var prepared := build_chat_payload(prompt, params)
	var response := BotResponse.new()
	response.provider = self
	if prepared.success:
		payload = prepared.payload
		response.text = "captured"
	else:
		response.error = prepared.error_message
	return response
