extends RefCounted
## Capture only the transport boundary; production generation builds the body.

class OpenAI extends OpenAIProvider:
	var captured: Dictionary = {}

	func make_request(_url: String, _method: int, body: Variant = "", _headers: Array[String] = []) -> RequestResults:
		captured = JSON.parse_string(str(body))
		var response := RequestResults.new()
		response.success = false
		response.message = "Test transport completed"
		return response


class ChatGPT extends ChatGPTProvider:
	var captured: Dictionary = {}

	func make_request(_url: String, _method: int, body: Variant = "", _headers: Array[String] = []) -> RequestResults:
		captured = JSON.parse_string(str(body))
		var response := RequestResults.new()
		response.success = false
		response.message = "Test transport completed"
		return response
