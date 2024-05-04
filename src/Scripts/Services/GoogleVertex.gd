class_name GoogleVertex
extends Node

var active_request: HTTPRequest
var active_bot: BotResponse

class ContentPart:
	var text: String
	
	func _init(text_value: String):
		text = text_value

class ContentResponse:
	var parts: Array[ContentPart]
	var role: String
	
	func _init(parts_array: Array, role_value: String):
		parts = []
		for part_text in parts_array:
			parts.append(ContentPart.new(part_text))
		role = role_value

# Signals
signal chat_completed(response: BotResponse)
signal stream_generate_content_response(response)
signal embed_content_response(response)
signal batch_embed_contents_response(response)
signal get_model_info_response(response)
signal list_models_response(response)
signal count_tokens_response(response)

# Constants
var API_KEY:String = SingletonObject.API_KEY[SingletonObject.API_PROVIDER.GOOGLE]
const BASE_URL := "https://generativelanguage.googleapis.com/v1beta"

# Helper function to make HTTP requests
func make_request(url: String, method: int, body: String=""):
	breakpoint
	# setup request object for the delta endpoint and append API key
	var http_request = active_request
	var complete_uri: String = url + "?key=" + API_KEY
	var headers := ["Content-Type: application/json"]
	if len(API_KEY) != 0:
		#add_child(http_request)
		http_request.request_completed.connect(_on_request_completed.bind(http_request, complete_uri))
	else:
		push_error("Invalid API key")
		return {}

	if http_request.is_inside_tree():
		print("HTTPRequest is part of the scene tree.")
	else:
		print("HTTPRequest is not part of the scene tree.")

	var error = http_request.request(complete_uri, headers, method, body)
	if error != OK:
		push_error("An error occurred during the HTTP request: %s" % error)
		return {}

	await http_request.request_completed
	return

func _on_request_completed(result, response_code, headers, body, http_request, url):
	var response_variant: Variant
	var response: BotResponse = BotResponse.new()
	if result == 0:
		response_variant = JSON.parse_string(body.get_string_from_utf8())
		response.FromVertex(response_variant)
	else:
		push_error("Invalid result.  Response: %s", response_code)
	if url.find("generateContent") != - 1:
		chat_completed.emit(response)
	elif url.find("streamGenerateContent") != - 1:
		stream_generate_content_response.emit(response)
	elif url.find("embedContent") != - 1:
		embed_content_response.emit(response)
	elif url.find("batchEmbedContents") != - 1:
		batch_embed_contents_response.emit(response)
	elif url.find("models/") != - 1 and url.find(":") == - 1:
		get_model_info_response.emit(response)
	elif url.find("models") != - 1 and url.find(":") == - 1:
		list_models_response.emit(response)
	elif url.find("countTokens") != - 1:
		count_tokens_response.emit(response)

# Generate Content
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):
	var request_body = {
		"contents": prompt
	}
	for key in additional_params:
		request_body[key] = additional_params[key]
	var body_stringified: String = JSON.stringify(request_body)
	
	print(body_stringified)
	#body_stringified = '{"contents": [{"role":"user", "parts":[{"text":"what is a cat?"}]}]}'
	var response = await make_request("%s/models/gemini-1.0-pro:generateContent" % BASE_URL, HTTPClient.METHOD_POST, body_stringified)
	return response

# Stream Generate Content
func stream_generate_content(prompt: Array[Variant], additional_params: Dictionary={}):
	var request_body = {
		"contents": prompt
	}
	for key in additional_params:
		request_body[key] = additional_params[key]
	var response = await make_request("%s/models/gemini-pro:streamGenerateContent" % BASE_URL, HTTPClient.METHOD_POST, JSON.stringify(request_body))
	return response

# Embed Content
func embed_content(content: String, model: String="models/embedding-001"):
	var request_body = {
		"model": model,
		"content": {"parts": [{"text": content}]}
	}
	var response = await make_request("%s/%s:embedContent" % [BASE_URL, model], HTTPClient.METHOD_POST, JSON.stringify(request_body))
	return response

# Batch Embed Contents
func batch_embed_contents(contents: Array, model: String="models/embedding-001"):
	var requests = []
	for content in contents:
		requests.append({
			"model": model,
			"content": {"parts": [{"text": content}]}
		})
	var request_body = {"requests": requests}
	var response = await make_request("%s/%s:batchEmbedContents" % [BASE_URL, model], HTTPClient.METHOD_POST, JSON.stringify(request_body))
	return response

# Get Model Info
func get_model_info(model: String):
	var response = await make_request("%s/%s" % [BASE_URL, model], HTTPClient.METHOD_GET)
	return response

# List Models
func list_models():
	var response = await make_request("%s/models" % BASE_URL, HTTPClient.METHOD_GET)
	return response

# Count Tokens
func count_tokens(content: String):
	var request_body = {
		"contents": [{"parts": [{"text": content}]}]
	}
	var response = await make_request("%s/models/gemini-pro:countTokens" % BASE_URL, HTTPClient.METHOD_POST, JSON.stringify(request_body))
	return response

func _ready():
	active_request = HTTPRequest.new()
	add_child(active_request)


## These functions are the Provider interface duck implimentation.

# Format handles formatting a single message in the content array to Google's Vertex format.
# google's single message in a history looks like this:
# {"role" : "user|model", "parts" : [{"text": "some text"}, {"inline_data": {"mime_type" :"image/jpeg", "data" : "base64 data"}] }"
func Format(chat:ChatHistoryItem) -> Variant:
	var role: String
	var parts: Array = []
	# If we have injected a note prepend it, otherwise jsut take the message
	var text: String = chat.InjectedNote + chat.Message if chat.InjectedNote else chat.Message


	if chat.Role == ChatHistoryItem.ChatRole.USER:
		role = "user"
	else:
		role = "model"
	
	parts.append({"text":text})
	if len(chat.Base64Data) > 0:
		var mime_type: String
		var data: String
		## figure out the mimetype
		if chat.Type == ChatHistoryItem.PartType.JPEG:
			mime_type = "image/jpeg"
			data = chat.Base64Data
			var inline_data = {"mime_type":mime_type, "data": data}
			parts.append(inline_data)
	
	## Serialize the message.
	var message_object = {"role": role, "parts": parts}
	return message_object
	
## Function:
# wrap_memory takes the output of formatting and sets up the text so that the LLM understands this is background information
func wrap_memory(list_memories:String) -> String:
	var output:String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += list_memories
	output += "### End Reference Information ###\n\n"
	output += "Respond to the user's message: \n\n"
	return output
		

