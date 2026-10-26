class_name CoreChatJob
extends RefCounted
## One chat job. Transport, registration, clock waits and persistence are injected.

const TERMINAL: Array[String] = ["completed", "failed", "cancelled", "stalled", "abandoned", "interrupted"]
const MAX_SUBMIT_ATTEMPTS: int = 12
const CLASSIC: Array[String] = ["MODEL_NOT_PERMITTED", "ASYNC_UNAVAILABLE"]
var pending_item: ChatHistoryItem
var _ask: Callable
var _online: Callable
var _pause: Callable
var _uuid: Callable
var _persist: Callable
var _status: Callable
var _cancelled: bool = false
var _job_id: String = ""
var _after_seq: int = 0
var _phase: String = ""
var _last_poll_ms: int = -1

func _init(ask: Callable, online: Callable, pause: Callable, uuid: Callable,
		persist: Callable, status: Callable, item: ChatHistoryItem) -> void:
	pending_item = item
	_ask = ask
	_online = online
	_pause = pause
	_uuid = uuid
	_persist = persist
	_status = status

func cancel() -> void:
	_cancelled = true
	if not _job_id.is_empty() and _online.call():
		_ask.call("cancel", {"job_id": _job_id}) # Best effort; no new generation.

func _failure(code: String) -> Dictionary:
	return {"success": false, "error_code": code, "error_message": "Async chat: %s" % code}

func _wait(seconds: float) -> void:
	var until: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not _cancelled and Time.get_ticks_msec() < until:
		await _pause.call(clampf(float(until - Time.get_ticks_msec()) / 1000.0, 0.0, 0.25))

func _request(action: String, data: Dictionary) -> Dictionary:
	while not _cancelled and not _online.call():
		await _pause.call(0.25) # Registration, not socket-connect, resumes the same job.
	if _cancelled:
		return _failure("cancelled")
	if action == "events":
		_last_poll_ms = Time.get_ticks_msec()
	return await _ask.call(action, data)

func _save(item: ChatHistoryItem) -> void:
	if _persist.is_valid():
		await _persist.call(item)

func _lookup(submission_id: String) -> Dictionary:
	while not _cancelled:
		var reply: Dictionary = await _request("lookup", {"submission_id": submission_id})
		if reply.get("success", false):
			var value: Dictionary = reply.get("value", {})
			if value.get("found", false) and not str(value.get("job_id", "")).is_empty():
				return value
			if value.get("found") is bool and value["found"] == false:
				return value # A successful lookup can prove submit never arrived.
		elif reply.get("remote_error", false) and str(reply.get("error_code", "")) in ["SUBMISSION_EXPIRED", "RESULT_EXPIRED"]:
			return reply
		# Unknown acceptance is query-only, never another submit or classic call.
		await _wait(5.0)
	return _failure("cancelled")

func run(input: Dictionary, item: ChatHistoryItem, model: String) -> Dictionary:
	var resumed: bool = not item.PendingJob.is_empty()
	var submission_id: String = str(item.PendingJob.get("submission_id", "")) if resumed else str(_uuid.call())
	if not resumed:
		item.PendingJob = {"submission_id": submission_id, "model": model,
			"submitted_at": Time.get_unix_time_from_system()}
		await _save(item) # The pending model item is attached to history before this call.
		var body: Dictionary = {"schema_version": 1, "submission_id": submission_id,
			"kind": "chat/v1", "input": input.duplicate(true)}
		var attempts: int = 0
		while not _cancelled and attempts < MAX_SUBMIT_ATTEMPTS:
			attempts += 1
			var reply: Dictionary = await _request("submit", body)
			if reply.get("success", false):
				_job_id = str(reply.get("value", {}).get("job_id", ""))
				if not _job_id.is_empty():
					break
			var code: String = str(reply.get("error_code", ""))
			var refused: bool = reply.get("remote_error", false) and reply.get("not_started", false) == true and code not in ["RESULT_UNKNOWN", "SUBMISSION_IN_FLIGHT", "timeout", "TIMEOUT"]
			# These legacy codes are emitted before dispatch; an explicit unknown
			# acceptance flag still forbids classic fallback.
			var legacy_refusal: bool = reply.get("remote_error", false) and code in CLASSIC and not reply.get("not_started_provided", reply.has("not_started"))
			if (refused or legacy_refusal) and code in CLASSIC:
				item.PendingJob = {}
				await _save(item)
				return {"success": false, "classic_fallback": true}
			if refused and reply.get("retryable", false) == true:
				await _wait(5.0)
				continue # Same body and submission ID after a definitive refusal.
			if refused and code not in ["INVALID_JOB_REPLY", "core_error"]:
				item.PendingJob = {}
				await _save(item)
				return reply
			# Uncertain acceptance remains query-only until lookup proves absence.
			var found: Dictionary = await _lookup(submission_id)
			if found.get("found") is bool and found["found"] == false:
				await _wait(5.0)
				continue # Authoritative absence permits the same bounded, idempotent retry.
			_job_id = str(found.get("job_id", ""))
			if _job_id.is_empty():
				return found
			break
		if not _cancelled and _job_id.is_empty():
			# The loop only retries a certified refusal or authoritative absence.
			item.PendingJob = {}
			await _save(item)
			var exhausted: Dictionary = _failure("ADMISSION_RETRY_LIMIT")
			exhausted["error_message"] = "The backend did not accept the request after %d attempts; retry the turn." % MAX_SUBMIT_ATTEMPTS
			return exhausted
	if _cancelled:
		return _failure("cancelled")
	if _job_id.is_empty():
		var found: Dictionary = await _lookup(submission_id)
		if found.get("found") is bool and found["found"] == false:
			item.PendingJob = {}
			await _save(item)
			var missing: Dictionary = _failure("SUBMISSION_NOT_RECEIVED")
			missing["error_message"] = "The server never received this request; resend it."
			return missing # A resumed item has no original body to submit safely.
		_job_id = str(found.get("job_id", ""))
		if _job_id.is_empty():
			return found
	var catch_up: bool = false
	while not _cancelled:
		if not catch_up and _last_poll_ms >= 0:
			await _wait(maxf(0.0, 5.0 - float(Time.get_ticks_msec() - _last_poll_ms) / 1000.0))
		while not _cancelled and not _online.call():
			await _pause.call(0.25)
		if _cancelled:
			break
		var reply: Dictionary = await _request("events", {"job_id": _job_id, "after_seq": _after_seq, "wait": not catch_up})
		catch_up = false
		if not reply.get("success", false):
			if reply.get("remote_error", false) and str(reply.get("error_code", "")) in ["NOT_FOUND", "RESULT_EXPIRED"]:
				item.PendingJob = {}
				await _save(item)
				return reply
			continue
		var page: Dictionary = reply.get("value", {})
		_accept_page(page)
		var state: String = str(page.get("status", {}).get("state", ""))
		if state in TERMINAL:
			return await _result(item, state) # Held completion is handled immediately.
		catch_up = page.get("has_more", false) == true
	return _failure("cancelled")

func _result(item: ChatHistoryItem, state: String) -> Dictionary:
	while not _cancelled:
		var reply: Dictionary = await _request("result", {"job_id": _job_id})
		if reply.get("success", false):
			item.PendingJob = {}
			await _save(item)
			return {"success": state == "completed", "value": reply.get("value", {}).get("response", {}),
				"error_code": state, "error_message": "Async chat ended: %s" % state}
		if reply.get("remote_error", false) and str(reply.get("error_code", "")) in ["RESULT_EXPIRED", "RESULT_UNAVAILABLE", "NOT_FOUND"]:
			item.PendingJob = {}
			await _save(item)
			return reply if state == "completed" else _failure(state)
		await _wait(5.0)
	return _failure("cancelled")

func _number(value: Variant) -> int:
	if (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)):
		return int(value)
	return -1

func _accept_page(page: Dictionary) -> void:
	# Gaps and lost rings need no text reconstruction: only observed channel
	# metadata is shown, and the authoritative full text still comes from result.
	for raw: Variant in page.get("events", []):
		if raw is Dictionary and raw.get("channel") in ["answer", "reasoning"]:
			_phase = str(raw["channel"])
	var last: int = _number(page.get("last_seq"))
	if last >= _after_seq:
		_after_seq = last
	if _status.is_valid():
		_status.call(_phase, _after_seq)
