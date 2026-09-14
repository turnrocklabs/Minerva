class_name VoiceOperation
extends RefCounted
## Cancellation belongs to one caller, even when the voice adapter is shared.

var cancelled := false
const CoreRequestBase = preload("res://Scripts/Services/Providers/Core/CoreRequest.gd")
var _request: CoreRequestBase
## Content-free correlation key used only by voice timing logs.
var diagnostic_id := ""
## Provider ownership follows the active request. A Core failure deliberately
## transfers ownership before an OpenAI fallback begins.
var voice_owner := ""

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
	var prepared := prepare(request)
	if not prepared.success:
		return prepared
	return await receive_prepared(request)


func prepare(request: CoreRequestBase) -> Dictionary:
	if cancelled:
		request.cancel()
		return {"success": false, "error_code": "cancelled", "error_message": "Voice operation is already cancelled."}
	if _request != null:
		request.cancel()
		return {"success": false, "error_code": "operation_busy", "error_message": "Voice operation already has an active request."}
	_request = request
	return {"success": true}


func receive_prepared(request: CoreRequestBase) -> Dictionary:
	var result := await request.receive_result()
	if _request == request:
		_request = null
	return result
