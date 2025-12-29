class_name CoBrowserMCPClient
extends RefCounted
## Client for the Co-Browser service.
## Uses HTTP transport to communicate with the Co-Browser service on port 8677.
## Enables browser automation through the Firefox extension.

signal command_completed(result: Dictionary)
signal connection_status_changed(connected: bool)

## Service configuration
const DEFAULT_HOST := "localhost"
const DEFAULT_PORT := 8677
const DEFAULT_TIMEOUT := 30.0

var _host: String = DEFAULT_HOST
var _port: int = DEFAULT_PORT
var _session_id: String = ""
var _http_client: HTTPClient


func _init(host: String = DEFAULT_HOST, port: int = DEFAULT_PORT) -> void:
	_host = host
	_port = port
	_http_client = HTTPClient.new()


## Get active sessions from the service
func get_active_sessions() -> Dictionary:
	var response = await _http_get("/v1/cobrowser/sessions/active")
	if response.get("error"):
		return response

	var sessions: Array = response.get("sessions", [])
	if sessions.size() > 0 and _session_id.is_empty():
		_session_id = sessions[0]

	return response


## Check if connected to a session
func has_active_session() -> bool:
	if _session_id.is_empty():
		return false
	var result = await get_active_sessions()
	var sessions: Array = result.get("sessions", [])
	return _session_id in sessions


## Set the active session ID
func set_session(session_id: String) -> void:
	_session_id = session_id


## Get current session ID
func get_session_id() -> String:
	return _session_id


# ============================================
# Browser Commands
# ============================================

## Navigate to a URL
func navigate(url: String, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.navigate", {"url": url}, timeout)


## Click an element
func click(selector: String = "", xpath: String = "", x: int = -1, y: int = -1, index: int = 0, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	var payload := {}
	if not selector.is_empty():
		payload["selector"] = selector
	if not xpath.is_empty():
		payload["xpath"] = xpath
	if x >= 0 and y >= 0:
		payload["x"] = x
		payload["y"] = y
	if index > 0:
		payload["index"] = index
	return await _send_command("command.click", payload, timeout)


## Double-click an element
func double_click(selector: String = "", xpath: String = "", timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	var payload := {}
	if not selector.is_empty():
		payload["selector"] = selector
	if not xpath.is_empty():
		payload["xpath"] = xpath
	return await _send_command("command.doubleclick", payload, timeout)


## Right-click an element
func right_click(selector: String = "", xpath: String = "", timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	var payload := {}
	if not selector.is_empty():
		payload["selector"] = selector
	if not xpath.is_empty():
		payload["xpath"] = xpath
	return await _send_command("command.rightclick", payload, timeout)


## Type text into an element
func type_text(selector: String, text: String, clear: bool = false, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.type", {
		"selector": selector,
		"text": text,
		"clear": clear
	}, timeout)


## Read text from an element
func read(selector: String, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.read", {"selector": selector}, timeout)


## Query multiple elements
func query_all(selector: String, limit: int = 20, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.queryAll", {
		"selector": selector,
		"limit": limit
	}, timeout)


## Scroll the page
func scroll(direction: String, amount: int = 0, selector: String = "", timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	var payload := {"direction": direction}
	if amount > 0:
		payload["amount"] = amount
	if not selector.is_empty():
		payload["selector"] = selector
	return await _send_command("command.scroll", payload, timeout)


## Get page state (metadata, DOM, security info)
func get_state(timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.getState", {}, timeout)


## Take a screenshot
func screenshot(timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.screenshot", {}, timeout)


## Request human intervention
func request_human(reason: String, message: String, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("handoff.request", {
		"reason": reason,
		"message": message
	}, timeout)


# ============================================
# Native Automation (requires permission in extension)
# ============================================

## Native mouse click using pyautogui
func native_click(selector: String = "", xpath: String = "", x: int = -1, y: int = -1, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	var payload := {}
	if not selector.is_empty():
		payload["selector"] = selector
	if not xpath.is_empty():
		payload["xpath"] = xpath
	if x >= 0 and y >= 0:
		payload["x"] = x
		payload["y"] = y
	return await _send_command("command.nativeClick", payload, timeout)


## Native keyboard typing using pyautogui
func native_type(text: String, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.nativeType", {"text": text}, timeout)


## Native hotkey combination using pyautogui
func native_hotkey(keys: Array, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.nativeHotkey", {"keys": keys}, timeout)


## Native scroll using pyautogui
func native_scroll(direction: String, amount: int = 3, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await _send_command("command.nativeScroll", {
		"direction": direction,
		"amount": amount
	}, timeout)


# ============================================
# Internal HTTP Methods
# ============================================

## Send a command to the Co-Browser service
func _send_command(command_type: String, payload: Dictionary, timeout: float) -> Dictionary:
	if _session_id.is_empty():
		var sessions_result = await get_active_sessions()
		if _session_id.is_empty():
			return {"success": false, "error": "No active session. Is Firefox extension connected?"}

	var endpoint := "/v1/cobrowser/command/%s/sync" % _session_id
	var body := {
		"type": command_type,
		"payload": payload,
		"timeout": timeout
	}

	return await _http_post(endpoint, body)


## Make an HTTP GET request
func _http_get(endpoint: String) -> Dictionary:
	var url := "http://%s:%d%s" % [_host, _port, endpoint]

	# Use a temporary HTTPRequest node for async operation
	var http_request := HTTPRequest.new()

	# We need to add it to the scene tree temporarily
	if Engine.get_main_loop() and Engine.get_main_loop().root:
		Engine.get_main_loop().root.add_child(http_request)
	else:
		return {"error": "Cannot create HTTP request - no scene tree"}

	var error := http_request.request(url, [], HTTPClient.METHOD_GET)
	if error != OK:
		http_request.queue_free()
		return {"error": "HTTP request failed: %s" % error_string(error)}

	var result = await http_request.request_completed
	http_request.queue_free()

	var response_code: int = result[1]
	var body: PackedByteArray = result[3]

	if response_code != 200:
		return {"error": "HTTP %d" % response_code}

	var json := JSON.new()
	var parse_error := json.parse(body.get_string_from_utf8())
	if parse_error != OK:
		return {"error": "JSON parse error: %s" % json.get_error_message()}

	return json.data


## Make an HTTP POST request
func _http_post(endpoint: String, body: Dictionary) -> Dictionary:
	var url := "http://%s:%d%s" % [_host, _port, endpoint]
	var json_body := JSON.stringify(body)
	var headers := ["Content-Type: application/json"]

	# Use a temporary HTTPRequest node for async operation
	var http_request := HTTPRequest.new()

	# We need to add it to the scene tree temporarily
	if Engine.get_main_loop() and Engine.get_main_loop().root:
		Engine.get_main_loop().root.add_child(http_request)
	else:
		return {"error": "Cannot create HTTP request - no scene tree"}

	var error := http_request.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if error != OK:
		http_request.queue_free()
		return {"error": "HTTP request failed: %s" % error_string(error)}

	var result = await http_request.request_completed
	http_request.queue_free()

	var response_code: int = result[1]
	var response_body: PackedByteArray = result[3]

	if response_code != 200:
		var error_text := response_body.get_string_from_utf8()
		return {"error": "HTTP %d: %s" % [response_code, error_text]}

	var json := JSON.new()
	var parse_error := json.parse(response_body.get_string_from_utf8())
	if parse_error != OK:
		return {"error": "JSON parse error: %s" % json.get_error_message()}

	return json.data


# ============================================
# Convenience Methods
# ============================================

## Get page title and URL
func get_page_info(timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	var state = await get_state(timeout)
	if state.get("error"):
		return state

	var result = state.get("result", {})
	var metadata = result.get("metadata", {})
	return {
		"success": true,
		"title": metadata.get("title", ""),
		"url": metadata.get("url", ""),
		"ready_state": metadata.get("readyState", "")
	}


## Wait for page to load
func wait_for_load(timeout: float = 10.0) -> Dictionary:
	var start_time := Time.get_ticks_msec()
	var timeout_ms := int(timeout * 1000)

	while Time.get_ticks_msec() - start_time < timeout_ms:
		var info = await get_page_info(5.0)
		if info.get("ready_state") == "complete":
			return {"success": true}
		await Engine.get_main_loop().create_timer(0.5).timeout

	return {"success": false, "error": "Timeout waiting for page load"}


## Fill a form field (clear and type)
func fill(selector: String, text: String, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	return await type_text(selector, text, true, timeout)


## Click and wait for navigation
func click_and_wait(selector: String, wait_time: float = 2.0, timeout: float = DEFAULT_TIMEOUT) -> Dictionary:
	var click_result = await click(selector, "", -1, -1, 0, timeout)
	if not click_result.get("success", false):
		return click_result

	await Engine.get_main_loop().create_timer(wait_time).timeout
	return await wait_for_load()
