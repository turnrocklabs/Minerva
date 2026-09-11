extends CoreClient
## Socket seam: exercise actual request builders and incoming dispatch synchronously.
var behavior := "hold"
var sent: Array[Dictionary] = []
var owner_present_at_send := false

func _ready() -> void:
	_connected = true
	set_process(false)

func send_text_message_to_core(message: Dictionary) -> Error:
	sent.append(message.duplicate(true))
	var request_id: String = message.get("params", {}).get("request_id", "")
	owner_present_at_send = _pending_requests.has(request_id)
	if behavior == "failure":
		return ERR_CONNECTION_ERROR
	if behavior == "json":
		reply(request_id, {"value": "immediate"})
	elif behavior == "subscribe":
		reply(request_id, {"status": "subscribed"})
	elif behavior == "registration":
		_handle_message({"cmd": "registration_confirmed", "entity_type": "core", "topic": "system", "params": {"request_id": request_id}})
	elif behavior == "auth_failure":
		_handle_message({"cmd": "error", "entity_type": "core", "topic": "system", "params": {"request_id": request_id, "error_code": "AUTH_FAILED_PROFILE_CMD_ERROR", "error": "token rejected"}})
	elif behavior == "discovery":
		reply(request_id, {"services": []})
	return OK

func reply(request_id: String, body: Variant, command: String = "response") -> void:
	_handle_message({"cmd": command, "entity_type": "service", "topic": "test", "params": {"request_id": request_id, "result": body}})
