class_name VoiceOperation
extends RefCounted
## Cancellation belongs to one caller, even when the voice adapter is shared.

var cancelled := false
const CoreRequestBase = preload("res://Scripts/Services/Providers/Core/CoreRequest.gd")
var _request: CoreRequestBase
## Content-free correlation key used only by voice timing logs.
var diagnostic_id := ""

func can_start() -> bool:
	return not cancelled

func is_busy() -> bool:
	return _request != null

func cancel() -> void:
	if cancelled:
		return
	cancelled = true
	var pending := _request
	_request = null
	if pending != null:
		pending.cancel()

func receive(request: CoreRequestBase) -> Dictionary:
	if cancelled:
		request.cancel()
	if _request != null:
		request.cancel()
		return {"success": false, "error_code": "operation_busy", "error_message": "Voice operation already has an active request."}
	_request = request
	var result := await request.receive_result()
	if _request == request:
		_request = null
	return result
