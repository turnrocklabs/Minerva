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

## Cost of one token in $
var token_cost: float = 0

var active_request: HTTPRequest
# var active_bot: BotResponse


#region METHODS TO REIMPLEMENT

# moved chat_response signal to SingletonObject

## This function will generate the model response for given `prompt`
## `additional_params` will be added to the request payload
func generate_content(_prompt: Array[Variant], _additional_params: Dictionary={}) -> BotResponse:
	await get_tree().process_frame # This line is just to suppress the 'not a coroutine' warning
	push_error("generate_content method of %s not implemented" % get_script().resource_path.get_file())
	return null

func wrap_memory(_item: MemoryItem) -> Variant:
	push_error("wrap_memory method of %s not implemented" % get_script().resource_path.get_file())
	return ""

func Format(_chat: ChatHistoryItem) -> Variant:
	push_error("Format method of %s not implemented" % get_script().resource_path.get_file())
	return null

func _on_request_completed(_result, _response_code, _headers, _body, _http_request, _url):
	pass

## Estimates token amount for the given string.
func estimate_tokens(_input: String) -> int:
	push_error("estimate_tokens method of %s not implemented" % get_script().resource_path.get_file())
	return 0

## Estimates token amount for the given input.
## `input` parameter is as the parameter for the `generate_content` function.
func estimate_tokens_from_prompt(_input: Array[Variant]) -> int:
	return 0

func continue_partial_response(_partial_chi: ChatHistoryItem):
	push_error("continue_partial_response method of %s not implemented" % get_script().resource_path.get_file())
	return null


#endregion

func _ready():
	active_request = HTTPRequest.new()
	add_child(active_request)


## This class represents results of the HTTP request
class RequestResults extends RefCounted:
	
	var http_request_result: int
	var response_code: int
	var headers: PackedStringArray
	var body: PackedByteArray
	var http_request: HTTPRequest
	var url: String
	var metadata: Dictionary
	var message: String
	var success: bool = true

	## This function will take results of the `HTTPRequest.request_completed` signal and additional data to construct
	## RequestResults object
	static func from_request_response(request_data_: Array, http_request_: HTTPRequest, url_: String, metadata_: Dictionary = {}):
		var obj = RequestResults.new()
		obj.http_request_result = request_data_[0]
		obj.response_code = request_data_[1]
		obj.headers = request_data_[2]
		obj.body = request_data_[3]

		obj.url = url_
		obj.metadata = metadata_
		obj.http_request = http_request_
		obj.http_request.use_threads = true
		return obj
	
	static func from_error(msg: String):
		var obj = RequestResults.new()
		obj.success = false
		obj.message = msg
		return obj
	
	func _to_string():
		return "%s (%s) - (%s)" % [url, response_code, metadata]

# Helper function to make HTTP requests
## This function will return array of 
func make_request(url: String, method: int, body: Variant = "", headers: Array[String]= []) -> RequestResults:
	# setup request object for the delta endpoint and append API key
	var http_request = active_request
	http_request.use_threads = true

	if len(API_KEY) != 0:
		#add_child(http_request)
		# if not http_request.request_completed.is_connected(_on_request_completed.bind(http_request, url)):
		# 	http_request.request_completed.connect(_on_request_completed.bind(http_request, url))
		pass
	else:
		SingletonObject.ErrorDisplay("No API Access", "API Key is missing or rejected")
		push_error("Invalid API key")
		return RequestResults.from_error("API Key is missing or rejected")

	if http_request.is_inside_tree():
		print("HTTPRequest is part of the scene tree.")
	else:
		print("HTTPRequest is not part of the scene tree.")

	var error: int

	if body is PackedByteArray:
		error = http_request.request_raw(url, headers, method, body)
	else:
		error = http_request.request(url, headers, method, str(body))

	
	if error != OK:
		SingletonObject.ErrorDisplay("Error", "An error occurred during the HTTP request: %s" % error)
		push_error("An error occurred during the HTTP request: %s" % error)
		return RequestResults.from_error("Unexpected error occurred")
	

	# data returned from awaited signal is array of arguments that would
	# be received by callback for that same signal
	var request_results: Array = await http_request.request_completed

	var results = RequestResults.from_request_response(request_results, http_request, url)

	return results
