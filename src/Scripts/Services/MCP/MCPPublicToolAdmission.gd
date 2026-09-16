class_name MCPPublicToolAdmission
extends RefCounted
## Global public tools/call admission. There is no hidden execution queue.

const MAX_IN_FLIGHT := 16
const STARTS_PER_SECOND := 20.0
const BURST := 40.0

class Lease extends RefCounted:
	var _owner
	var _released := false

	func _init(owner) -> void:
		_owner = owner

	func release() -> void:
		if _released:
			return
		_released = true
		if _owner != null:
			_owner._release()
		_owner = null

var _in_flight := 0
var _tokens := BURST
var _last_refill_ms := Time.get_ticks_msec()
var clock: Callable = func() -> int: return Time.get_ticks_msec()


func acquire() -> Dictionary:
	_refill()
	if _in_flight >= MAX_IN_FLIGHT:
		return {"ok": false, "reason": "too_many_in_flight", "retry_after": 1}
	if _tokens < 1.0:
		var wait_seconds := (1.0 - _tokens) / STARTS_PER_SECOND
		return {"ok": false, "reason": "rate_limited",
			"retry_after": maxi(1, ceili(wait_seconds))}
	_tokens -= 1.0
	_in_flight += 1
	return {"ok": true, "lease": Lease.new(self)}


func _refill() -> void:
	var now: int = int(clock.call())
	var elapsed_seconds := maxf(0.0, float(now - _last_refill_ms) / 1000.0)
	_last_refill_ms = now
	_tokens = minf(BURST, _tokens + elapsed_seconds * STARTS_PER_SECOND)


func _release() -> void:
	_in_flight = maxi(0, _in_flight - 1)


func in_flight() -> int:
	return _in_flight
