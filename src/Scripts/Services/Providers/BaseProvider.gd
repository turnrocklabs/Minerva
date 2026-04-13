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
var display_name: String:
	get:
		return display_name if not display_name.is_empty() else model_name
	set(value):
		display_name = value

## Model short name to be displayed in the chat message bubble
var short_name = "NA"

## Cost per million input tokens in $
var input_token_cost: float = 0.0

## Cost per million output tokens in $
var output_token_cost: float = 0.0

## Legacy: average cost per token (for backwards compat)
var token_cost: float:
	get: return (input_token_cost + output_token_cost) / 2.0 / 1_000_000.0

## Chat ID for budget enforcement (set by ChatPane before generate_content)
var chat_id: String = ""

## Model capability flags - override in subclasses as needed
var supports_temperature: bool = true
var supports_top_p: bool = true
var supports_system_prompt: bool = true
var supports_frequency_penalty: bool = false
var supports_presence_penalty: bool = false
var is_reasoning_model: bool = false

## Cache hint style for this model. Providers/models override as needed.
## Values: "anthropic_ephemeral", "auto", "none"
var cache_hint_style: String = "none"

## If true, inject a default system prompt when none is provided.
## This is needed for models like Mistral/Devstral that have a built-in
## "Le Chat" system prompt with date injection that we want to override.
var requires_default_system_prompt: bool = false
var default_system_prompt: String = "You are a helpful AI assistant."

## Default request timeout in seconds. Override in subclasses.
var default_timeout: float = 120.0

## Current timeout for requests (0 = use default_timeout)
var request_timeout: float = 0.0

## Whether this provider supports configuring context window size
var supports_num_ctx: bool = false

## Whether this provider supports configuring GPU layer count (for Ollama)
var supports_num_gpu: bool = false

## Get effective timeout - checks per-model override first, then falls back to default
func get_effective_timeout() -> float:
	# Check per-model timeout override (keyed by model_name)
	var model_timeout: float = SingletonObject.get_model_timeout(model_name)
	if model_timeout > 0:
		return model_timeout
	# Use per-instance override if set
	if request_timeout > 0:
		return request_timeout
	# Fall back to default
	return default_timeout

## Default context window size (override in subclasses that support it)
var default_context: int = 0

## Get effective context window - checks per-model override first, then falls back to default
func get_effective_context() -> int:
	# Check per-model context override (keyed by model_name)
	var model_context: int = SingletonObject.get_model_context(model_name)
	if model_context > 0:
		return model_context
	# Fall back to default
	return default_context

## Default GPU layers (-1 = use Ollama default, 0 = CPU only)
var default_num_gpu: int = -1

## Get effective num_gpu - checks per-model override first, then falls back to default
func get_effective_num_gpu() -> int:
	# Check per-model num_gpu override (keyed by model_name)
	var model_num_gpu: int = SingletonObject.get_model_num_gpu(model_name)
	if model_num_gpu >= 0:
		return model_num_gpu
	# Fall back to default
	return default_num_gpu

## Sanitize a tool call ID to be safe across all providers.
## OpenAI: max 40 chars. Anthropic: must match ^[a-zA-Z0-9_-]+$
static var _tool_id_regex: RegEx = _init_tool_id_regex()
static func _init_tool_id_regex() -> RegEx:
	var r := RegEx.new()
	r.compile("[^a-zA-Z0-9_-]")
	return r

static func sanitize_tool_id(id: String) -> String:
	var clean := _tool_id_regex.sub(id, "_", true).left(40)
	if clean.is_empty():
		clean = "tool_0"
	return clean

## Temperature constraints
var temperature_min: float = 0.0
var temperature_max: float = 2.0
var temperature_warning: String = ""  # e.g., "Keep at 1.0 for best results"

var active_request: HTTPRequest
# var active_bot: BotResponse
var active_requests: Array[HTTPRequest]

## The HistoryId of the ChatHistory that owns this provider (set by ServiceHistory._init)
var owner_history_id: String = ""

#region METHODS TO REIMPLEMENT

# moved chat_response signal to SingletonObject

## This function will generate the model response for given `prompt`
## `additional_params` will be added to the request payload
func generate_content(_prompt: Array[Variant], _additional_params: Dictionary={}) -> BotResponse:
	await get_tree().process_frame # This line is just to suppress the 'not a coroutine' warning
	push_error("generate_content method of %s not implemented" % get_script().resource_path.get_file())
	return null

func wrap_memory(_item: Note) -> Variant:
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
func estimate_tokens_from_prompt(_input: Array[Variant]) -> float:
	return 0

func continue_partial_response(_partial_chi: ChatHistoryItem):
	push_error("continue_partial_response method of %s not implemented" % get_script().resource_path.get_file())
	return null

## Apply provider/model-specific cache annotations to formatted messages.
## Called by ToolMemoryManager after project() orders history cache-friendly.
## Default: no-op. Override in providers/models with cache support.
func apply_cache_hints(_system_prompt: Variant, _messages: Array) -> void:
	pass

#endregion

func _ready():
	active_request = HTTPRequest.new()
	add_child(active_request)
	# Connect to global stop signal
	SingletonObject.stop_all_requests.connect(_on_stop_all_requests)


## Handle stop signal - only cancel if history_id matches or is empty (stop all)
func _on_stop_all_requests(history_id: String) -> void:
	if history_id.is_empty() or history_id == owner_history_id:
		cancel_active_resquests()


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
	static func from_request_response(request_data_: Array = [], http_request_: HTTPRequest = null, url_: String = "", metadata_: Dictionary = {}):
		var obj = RequestResults.new()
		
		# Handle case where request_data_ is null or empty
		if request_data_ == null || request_data_.size() < 4:
			obj.http_request_result = HTTPRequest.RESULT_REQUEST_FAILED
			obj.response_code = 0
			obj.headers = PackedStringArray()
			obj.body = PackedByteArray()
		else:
			obj.http_request_result = request_data_[0]
			obj.response_code = request_data_[1]
			obj.headers = request_data_[2]
			obj.body = request_data_[3]

		# Handle null or empty http_request
		obj.http_request = http_request_
		if obj.http_request != null:
			obj.http_request.use_threads = true
		
		# Handle null or empty url and metadata
		obj.url = url_ if url_ != null else ""
		obj.metadata = metadata_ if metadata_ != null else {}
		
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
var timed_out: bool = false
## Per-request generation counter to invalidate stale timeout timers.
## SceneTreeTimers can't be cancelled, so old timers from previous requests
## may fire during a new request. By checking the counter, we ensure only
## the timer belonging to the current request can trigger a timeout.
var _request_generation: int = 0
func make_request(url: String, method: int, body: Variant = "", headers: Array[String]= []) -> RequestResults:
	# Reset timeout state and bump generation for each new request
	timed_out = false
	_request_generation += 1
	var my_generation: int = _request_generation

	# Budget enforcement: check before making the API call
	if not chat_id.is_empty() and SingletonObject.cost_tracker:
		var budget_status: Dictionary = SingletonObject.cost_tracker.check_budget(chat_id)
		if budget_status.get("has_budget", false) and not budget_status.get("ok", true):
			var spent: float = budget_status.get("spent", 0.0)
			var budget: float = budget_status.get("budget", 0.0)
			return RequestResults.from_error(
				"Budget exceeded ($%.2f / $%.2f). Use minerva_extend_budget to add more funds." % [spent, budget]
			)

	# setup request object for the delta endpoint and append API key
	var http_request: = HTTPRequest.new()
	http_request.use_threads = true
	call_deferred("add_child", http_request)
	await http_request.ready
	active_requests.append(http_request)
	# LOCAL provider doesn't need an API key (Ollama runs locally)
	if len(API_KEY) == 0 and PROVIDER != SingletonObject.API_PROVIDER.LOCAL:
		SingletonObject.ErrorDisplay("No API Access", "API Key is missing or rejected")
		push_error("Invalid API key")
		active_requests.erase(http_request)
		http_request.queue_free()
		return RequestResults.from_error("API Key is missing or rejected")

	if http_request.is_inside_tree():
		print("HTTPRequest is part of the scene tree.")
	else:
		print("HTTPRequest is not part of the scene tree.")

	var error = FAILED

	if body is PackedByteArray:
		error = http_request.request_raw(url, headers, method, body)
	else:
		error = http_request.request(url, headers, method, str(body))


	if error != OK:
		SingletonObject.call_deferred("ErrorDisplay", "Error", "An error occurred during the HTTP request: %s" % error)#ErrorDisplay("Error", "An error occurred during the HTTP request: %s" % error)
		#push_error("An error occurred during the HTTP request: %s" % error)
		active_requests.erase(http_request)
		http_request.queue_free()
		return RequestResults.from_error("Unexpected error occurred")

	# Setup timeout timer
	var timeout_seconds: float = get_effective_timeout()

	var timeout_timer: SceneTreeTimer = null

	if timeout_seconds > 0 and is_inside_tree():
		timeout_timer = get_tree().create_timer(timeout_seconds)
		# Use WeakRefs to avoid "Lambda capture was freed" errors.
		# SceneTreeTimers can't be cancelled, so stale timers will fire
		# after the provider or http_request has been queue_free'd.
		var provider_ref: WeakRef = weakref(self)
		var request_ref: WeakRef = weakref(http_request)
		timeout_timer.timeout.connect(func():
			var provider = provider_ref.get_ref()
			if provider == null:
				return
			# Only timeout if this timer belongs to the current request.
			if my_generation == provider._request_generation:
				provider.timed_out = true
				var req = request_ref.get_ref()
				if req != null:
					req.cancel_request()
		)

	# data returned from awaited signal is array of arguments that would
	# be received by callback for that same signal

	var request_results: Array = await http_request.request_completed

	# Check if we timed out
	if timed_out:
		active_requests.erase(http_request)
		http_request.queue_free()
		return RequestResults.from_error("Request timed out after %d seconds" % int(timeout_seconds))

	var results = RequestResults.from_request_response(request_results, http_request, url)

	# Clean up the HTTPRequest node now that we have the response data
	active_requests.erase(http_request)
	http_request.queue_free()

	return results


## Parse the Retry-After value (seconds) from a PackedStringArray of response headers.
## Returns -1.0 if the header is absent or unparseable.
static func parse_retry_after(headers: PackedStringArray) -> float:
	for header in headers:
		var lower: String = header.to_lower()
		if lower.begins_with("retry-after:"):
			var value: String = header.substr(header.find(":") + 1).strip_edges()
			if value.is_valid_float():
				return value.to_float()
			if value.is_valid_int():
				return float(value.to_int())
	return -1.0


func cancel_active_resquests() -> void:
	for i: HTTPRequest in active_requests:
		if i.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
			i.cancel_request()
			#i.request_completed.emit(HTTPRequest.RESULT_REQUEST_FAILED, 0, PackedStringArray(), PackedByteArray())
			active_requests.erase(i)
			i.queue_free()
