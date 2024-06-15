class_name BaseProvider
extends Node

# Thing that provider needs to define are:
# model name
# short name
# api endpoint

var PROVIDER: SingletonObject.API_PROVIDER

var API_KEY: String:
	get: return SingletonObject.preferences_popup.get_api_key(PROVIDER)

var BASE_URL: String

var provider_name:= "Unknown"
var model_name:= "Unknown"

## Model short name to be displayed in the chat message bubble
var short_name = "NA"

var active_request: HTTPRequest
var active_bot: BotResponse

# region METHODS TO REIMPLEMENT

signal chat_completed(response: BotResponse)

func generate_content(_prompt: Array[Variant], _additional_params: Dictionary={}):
	push_error("generate_content method of %s not implemented" % get_script().resource_path.get_file())
	return null

func wrap_memory(_list_memories: String) -> String:
	push_error("wrap_memory method of %s not implemented" % get_script().resource_path.get_file())
	return ""

func Format(_chat: ChatHistoryItem) -> Variant:
	push_error("Format method of %s not implemented" % get_script().resource_path.get_file())
	return null

func _on_request_completed(result, response_code, _headers, body, _http_request, _url):
	pass

# endregion

func _ready():
	active_request = HTTPRequest.new()
	add_child(active_request)

# Helper function to make HTTP requests
func make_request(url: String, method: int, body: String="", headers: Array[String]= []):
	# setup request object for the delta endpoint and append API key
	var http_request = active_request
	http_request.use_threads = true
	headers.append("Content-Type: application/json")

	if len(API_KEY) != 0:
		#add_child(http_request)
		if not http_request.request_completed.is_connected(_on_request_completed.bind(http_request, url)):
			http_request.request_completed.connect(_on_request_completed.bind(http_request, url))
	else:
		SingletonObject.ErrorDisplay("No API Access", "API Key is missing or rejected")
		push_error("Invalid API key")
		return {}

	if http_request.is_inside_tree():
		print("HTTPRequest is part of the scene tree.")
	else:
		print("HTTPRequest is not part of the scene tree.")

	var error = http_request.request(url, headers, method, body)
	if error != OK:
		push_error("An error occurred during the HTTP request: %s" % error)
		return {}

	await http_request.request_completed
	return


