class_name MCPStdioProcessDiagnostics
extends RefCounted
## Host-side lifetime of one native process's diagnostic evidence. Native owns
## causes, queues and reap; this adapter owns generation matching and EOF settle.

const EOF_SETTLE_MS := 250
var process: Object
var native_generation: int = -1
var eof_deadline_ms: int = 0
var finalizing: bool = false


func _init(native_process: Object) -> void:
	process = native_process
	var current := snapshot()
	if current.get("generation") is int:
		native_generation = current.generation


func snapshot(include_stderr: bool = false) -> Dictionary:
	if not is_instance_valid(process) or not process.has_method("get_io_diagnostics"):
		return {}
	var value: Variant = process.call("get_io_diagnostics", include_stderr)
	return value if value is Dictionary else {}


func matches(candidate: Object, expected_native_generation: int = -1) -> bool:
	if candidate != process or not is_instance_valid(process):
		return false
	if expected_native_generation >= 0 and expected_native_generation != native_generation:
		return false
	return native_generation < 0 or snapshot().get("generation", -1) == native_generation


## stdout EOF can precede an ordinary exit. Keep admitted calls for one bounded
## settle window on the existing backstop; refuse new writes during this window.
func terminal_ready(current: Dictionary, alive: bool, now_ms: int) -> bool:
	var cause := str(current.get("cause", ""))
	if cause == "stdout_eof" and alive:
		if eof_deadline_ms == 0:
			eof_deadline_ms = now_ms + EOF_SETTLE_MS
		return now_ms >= eof_deadline_ms
	return not cause.is_empty() or not alive


func closing() -> bool:
	return finalizing or eof_deadline_ms > 0


## Terminal signals are provisional. Finalize before formatting or waking any
## waiter; stale generations never stop or disclose a replacement process.
func finalize(include_stderr: bool) -> Dictionary:
	if not matches(process):
		return {"evidence_state": "stale_generation"}
	if finalizing:
		return {"evidence_state": "provisional"}
	finalizing = true
	if native_generation >= 0 and process.has_method("finalize_io"):
		var value: Variant = process.call("finalize_io", native_generation, include_stderr)
		if value is Dictionary and value.has("evidence_state"):
			if value.get("evidence_state") == "stale_generation" or value.get("generation", -1) != native_generation:
				finalizing = false
				return {"evidence_state": "stale_generation"}
			return value
	# Older extensions/fakes have no final-evidence contract. Reuse their stop
	# when available, and mark capability loss instead of inventing native facts.
	if process.has_method("stop"):
		process.call("stop")
	var unavailable := snapshot(include_stderr)
	unavailable["evidence_state"] = "unavailable"
	unavailable["diagnostics_unavailable"] = "native_finalization_unavailable"
	return unavailable
