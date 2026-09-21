class_name JSONSchemaValidatorClient
extends Node
const JsonSerialization = preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")
## Supervises the isolated jsoncons helper. Handles belong to one process
## generation; a deadline, overflow, or process loss invalidates them together.

signal helper_failed(reason: String)
signal startup_progress(stage: String, elapsed_msec: int)

const MonotonicDeadline = preload("res://Scripts/Services/MCP/MCPMonotonicDeadline.gd")

const MAX_PENDING := 32
const DEADLINE_SECONDS := 2.0

class SchemaHandle extends RefCounted:
	var native_id: int
	var generation: int
	var schema_raw: String
	var registry: Dictionary

class Pending extends RefCounted:
	signal finished
	var done := false
	var result: Dictionary = {}
	var deadline_error: Dictionary = {}
	var deadline
	var deadline_callback: Callable
	func finish(value: Dictionary) -> void:
		if done:
			return
		done = true
		result = value
		finished.emit()

var helper_path := ""
var last_failure_reason := ""
var startup_stage := "idle"
var startup_started_msec := 0
var _process = null
var _process_factory: Callable
var _generation := 0
var _next_id := 0
var _pending: Dictionary = {}
var _handles: Array[SchemaHandle] = []
var _starting: Pending
var _exiting := false


func _exit_tree() -> void:
	_exiting = true
	stop()


func start() -> Error:
	if _exiting:
		last_failure_reason = "JSON Schema validator is shutting down"
		return ERR_UNAVAILABLE
	if _starting != null:
		var existing := _starting
		await existing.finished
		return int(existing.result.get("status", ERR_CANT_CONNECT)) as Error
	if _process != null and _process.is_running():
		return OK
	startup_started_msec = Time.get_ticks_msec()
	_set_startup_stage("preflight")
	last_failure_reason = ""
	var resolved_path := _resolved_helper_path()
	# Injected test processes do not execute a file. Production startup must
	# catch a missing helper before fork/exec turns it into a generic exit 127.
	if not _process_factory.is_valid() and not FileAccess.file_exists(resolved_path):
		last_failure_reason = "MCP JSON Schema helper is missing at '%s'. %s" % [
			resolved_path, _setup_hint()]
		return ERR_FILE_NOT_FOUND
	_starting = Pending.new()
	var startup := _starting
	var process = _process_factory.call() if _process_factory.is_valid() else _make_process()
	if process == null:
		last_failure_reason = "MCP JSON Schema helper requires the SubProcess native extension. %s" % _setup_hint(true)
		_finish_start(startup, ERR_UNAVAILABLE)
		return ERR_UNAVAILABLE
	_process = process
	_set_startup_stage("native_start")
	_generation += 1
	var process_generation := _generation
	if process is Node and process.get_parent() == null:
		add_child(process)
	if not process.start(resolved_path, PackedStringArray()):
		last_failure_reason = "Cannot start MCP JSON Schema helper at '%s'. %s" % [resolved_path, _setup_hint()]
		if process is Node:
			process.queue_free()
		_process = null
		_finish_start(startup, ERR_CANT_CREATE)
		return ERR_CANT_CREATE
	_set_startup_stage("spawn_returned")
	if process.has_signal("output_ready"):
		process.output_ready.connect(_drain_output.bind(process, process_generation))
	if process.has_signal("process_exited"):
		process.process_exited.connect(_on_process_exited.bind(process, process_generation))
	if process.has_signal("io_overflow"):
		process.io_overflow.connect(_on_io_overflow.bind(process, process_generation))
	_set_startup_stage("ping_wait")
	var ping: Dictionary = await _request({"op": "ping"}, process, process_generation)
	_set_startup_stage("ready" if ping.get("ok", false) else "ping_failed")
	var status: Error = OK if ping.get("ok", false) else ERR_CANT_CONNECT
	if status != OK and last_failure_reason.is_empty():
		last_failure_reason = "MCP JSON Schema helper did not answer its startup check at '%s'. %s" % [
			resolved_path, _setup_hint()]
	if status != OK and _process == process and _generation == process_generation:
		_invalidate_process(process, process_generation, last_failure_reason)
	_finish_start(startup, status)
	return status


func startup_diagnostic() -> Dictionary:
	return {"stage": startup_stage,
		"elapsed_msec": maxi(0, Time.get_ticks_msec() - startup_started_msec),
		"process_running": _process != null and _process.is_running(),
		"pending_requests": _pending.size(), "failure": last_failure_reason}


func _set_startup_stage(stage: String) -> void:
	startup_stage = stage
	startup_progress.emit(stage, maxi(0, Time.get_ticks_msec() - startup_started_msec))


func stop() -> void:
	var process = _process
	var process_generation := _generation
	var retiring_startup := _starting
	_starting = null
	if process != null:
		_process = null
		_generation += 1
		_disconnect_process(process, process_generation)
		process.stop()
		if process is Node and is_instance_valid(process):
			process.call_deferred("queue_free")
	_fail_pending("validator_stopped")
	if retiring_startup != null:
		retiring_startup.finish({"status": ERR_CANT_CONNECT})


func compile(schema_raw: String, registry: Dictionary = {}) -> Dictionary:
	if schema_raw.to_utf8_buffer().size() > 4 * 1024 * 1024:
		return _failure("schema_too_large", "schema exceeds 4 MiB")
	var aggregate_bytes := schema_raw.to_utf8_buffer().size()
	for registered_raw in registry.values():
		if not registered_raw is String:
			return _failure("invalid_registry", "registry values must be raw schema strings")
		aggregate_bytes += registered_raw.to_utf8_buffer().size()
		if aggregate_bytes > 4 * 1024 * 1024:
			return _failure("schema_too_large", "schema registry exceeds 4 MiB")
	var startup_status: Error = await start()
	if startup_status != OK:
		return _failure("validator_unavailable", last_failure_reason)
	var result: Dictionary = await _request({"op": "compile", "schema_raw": schema_raw,
		"registry": registry})
	if not result.get("ok", false):
		return result
	var handle := SchemaHandle.new()
	handle.native_id = int(result.handle)
	handle.generation = _generation
	handle.schema_raw = schema_raw
	handle.registry = registry.duplicate(true)
	_handles.append(handle)
	return {"ok": true, "handle": handle}


func validate_raw(handle: SchemaHandle, instance_raw: String) -> Dictionary:
	if handle == null or handle.generation != _generation or _process == null:
		return _failure("invalid_handle", "schema must be recompiled after validator restart")
	if instance_raw.to_utf8_buffer().size() > 32 * 1024 * 1024:
		return _failure("instance_too_large", "instance exceeds 32 MiB")
	return await _request({"op": "validate", "handle": handle.native_id,
		"instance_raw": instance_raw})


func validate_for_application(handle: SchemaHandle, instance_raw: String,
		application_value: Variant) -> Dictionary:
	var result: Dictionary = await validate_raw(handle, instance_raw)
	if not result.get("ok", false):
		return result
	var serialized := JsonSerialization.encode(application_value)
	if not serialized.ok:
		return serialized
	var numeric: Dictionary = await _request({"op": "compare_numbers",
		"original_raw": instance_raw, "adapted_raw": serialized.raw})
	return result if numeric.get("ok", false) else numeric


func compare_application_numbers(original_raw: String, application_value: Variant) -> Dictionary:
	var serialized := JsonSerialization.encode(application_value)
	if not serialized.ok:
		return serialized
	var startup_status: Error = await start()
	if startup_status != OK:
		return _failure("validator_unavailable", last_failure_reason)
	return await _request({"op": "compare_numbers", "original_raw": original_raw,
		"adapted_raw": serialized.raw})


## Prepares a value produced directly by Godot's JSON decoder. The native
## helper returns a sparse overlay for binary64 leaves Godot rounded incorrectly.
func prepare_application_numbers(original_raw: String,
		application_value: Variant) -> Dictionary:
	var serialized := JsonSerialization.encode(application_value)
	if not serialized.ok:
		return serialized
	var startup_status: Error = await start()
	if startup_status != OK:
		return _failure("validator_unavailable", last_failure_reason)
	return await _request({"op": "prepare_numbers", "original_raw": original_raw,
		"adapted_raw": serialized.raw})


func release(handle: SchemaHandle) -> Dictionary:
	if handle != null and handle.generation == _generation and _process != null:
		var process = _process
		var process_generation := _generation
		var result: Dictionary = await _request(
			{"op": "release", "handle": handle.native_id}, process, process_generation)
		if result.get("ok", false):
			_handles.erase(handle)
		elif process == _process and process_generation == _generation:
			# A rejected release leaves an unreachable native handle. Retire only
			# its exact helper generation so repeated contention cannot exhaust it.
			_invalidate_process(process, process_generation, "validator handle release failed")
		return result
	_handles.erase(handle)
	return {"ok": true}


func _request(fields: Dictionary, expected_process = null, expected_generation: int = -1) -> Dictionary:
	var process = _process if expected_process == null else expected_process
	var process_generation := _generation if expected_generation < 0 else expected_generation
	if process == null or process != _process or process_generation != _generation or not process.is_running():
		return _failure("validator_unavailable", "JSON Schema validator is unavailable")
	if _pending.size() >= MAX_PENDING:
		return _failure("queue_full", "JSON Schema validator queue is full")
	_next_id += 1
	var id := str(_next_id)
	fields["id"] = id
	var encoded := JsonSerialization.encode(fields)
	if not encoded.get("ok", false):
		return encoded
	var pending := Pending.new()
	_pending[id] = pending
	if not process.write_data(str(encoded.raw) + "\n"):
		_pending.erase(id)
		return _failure("queue_full", "JSON Schema validator input queue is full")
	if DEADLINE_SECONDS > 0.0 and not pending.done:
		pending.deadline_error = _failure("deadline_exceeded",
			"JSON Schema validation exceeded 2 seconds")
		_arm_deadline(id, pending)
	if not pending.done:
		await pending.finished
	if pending.result.get("error", {}).get("code") == "deadline_exceeded":
		_invalidate_process(process, process_generation, "validator deadline exceeded")
	return pending.result


func _arm_deadline(id: String, pending: Pending) -> void:
	_cancel_deadline(pending)
	pending.deadline = MonotonicDeadline.new()
	pending.deadline_callback = _resolve.bind(id, pending.deadline_error)
	pending.deadline.expired.connect(pending.deadline_callback)
	if not pending.deadline.start(DEADLINE_SECONDS):
		_resolve(id, _failure("deadline_unavailable", "validator deadline is unavailable"))


func _cancel_deadline(pending: Pending) -> void:
	if pending.deadline != null:
		pending.deadline.cancel()
		if pending.deadline_callback.is_valid() \
				and pending.deadline.expired.is_connected(pending.deadline_callback):
			pending.deadline.expired.disconnect(pending.deadline_callback)
	pending.deadline = null
	pending.deadline_callback = Callable()


func _drain_output(process, process_generation: int) -> void:
	if process != _process or process_generation != _generation:
		return
	while process == _process and process_generation == _generation and process.has_output():
		var parsed: Variant = JSON.parse_string(process.read_line())
		if parsed is Dictionary:
			_resolve(str(parsed.get("id", "")), parsed)


func _resolve(id: String, result: Dictionary) -> void:
	if not _pending.has(id):
		return
	var pending: Pending = _pending[id]
	_pending.erase(id)
	_cancel_deadline(pending)
	pending.finish(result)


func _finish_start(startup: Pending, status: Error) -> void:
	if _starting == startup:
		_starting = null
	startup.finish({"status": status})


func _fail_pending(reason: String) -> void:
	_handles.clear()
	for id in _pending.keys():
		_resolve(id, _failure("process_lost", reason))


func _invalidate_process(process, process_generation: int, reason: String) -> void:
	if process != _process or process_generation != _generation:
		return
	last_failure_reason = reason
	_process = null
	_generation += 1
	var retiring_startup := _starting
	_starting = null
	_disconnect_process(process, process_generation)
	_fail_pending(reason)
	if retiring_startup != null:
		retiring_startup.finish({"status": ERR_CANT_CONNECT})
	# Retirement is deferred so a failed waiter can immediately start a fresh
	# generation without joining or stopping the old process on its call stack.
	process.call_deferred("stop")
	if process is Node:
		process.call_deferred("queue_free")
	helper_failed.emit(reason)


func _on_process_exited(code: int, process, process_generation: int) -> void:
	_invalidate_process(process, process_generation,
		"MCP JSON Schema helper at '%s' exited with code %d. %s" % [
			_resolved_helper_path(), code, _setup_hint()])


func _setup_hint(full_build: bool = false) -> String:
	if OS.has_feature("editor"):
		var command := "scripts/build-extensions.sh"
		var helper_option := " --helper-only"
		if OS.get_name() == "Windows":
			command = "powershell -ExecutionPolicy Bypass -File scripts\\build-extensions.ps1"
			helper_option = " -HelperOnly"
		if full_build:
			return "Close Minerva and its editor, then run %s from the repository root. See Docs/Building.md." % command
		command += helper_option
		return "From the repository root, run %s. See Docs/Building.md." % command
	return "Reinstall a complete Minerva release for this operating system and architecture."


func _on_io_overflow(process, process_generation: int) -> void:
	_invalidate_process(process, process_generation, "validator output queue overflowed")


func _make_process():
	if not ClassDB.class_exists("SubProcess"):
		return null
	return ClassDB.instantiate("SubProcess")


func _disconnect_process(process, process_generation: int) -> void:
	var output_callback := _drain_output.bind(process, process_generation)
	var exit_callback := _on_process_exited.bind(process, process_generation)
	var overflow_callback := _on_io_overflow.bind(process, process_generation)
	if process.has_signal("output_ready") and process.output_ready.is_connected(output_callback):
		process.output_ready.disconnect(output_callback)
	if process.has_signal("process_exited") and process.process_exited.is_connected(exit_callback):
		process.process_exited.disconnect(exit_callback)
	if process.has_signal("io_overflow") and process.io_overflow.is_connected(overflow_callback):
		process.io_overflow.disconnect(overflow_callback)


func _resolved_helper_path() -> String:
	if not helper_path.is_empty():
		return helper_path
	var suffix := ".exe" if OS.get_name() == "Windows" else ""
	var editor_path := ProjectSettings.globalize_path(
		"res://bin/minerva-json-schema-helper" + suffix)
	if OS.has_feature("editor"):
		return editor_path
	var target := _runtime_target(OS.get_name(), Engine.get_architecture_name())
	if target.is_empty():
		return ""
	var executable_dir := OS.get_executable_path().get_base_dir()
	if OS.get_name() == "macOS":
		return executable_dir.path_join("../Resources/mcp-runtime").path_join(target) \
			.path_join("minerva-json-schema-helper").simplify_path()
	return executable_dir.path_join("mcp-runtime").path_join(target) \
		.path_join("minerva-json-schema-helper" + suffix)


static func _runtime_target(os_name: String, architecture: String) -> String:
	match os_name:
		"Windows":
			return "windows-x86_64" if architecture in ["x86_64", "amd64"] else ""
		"macOS":
			if architecture in ["arm64", "aarch64"]:
				return "macos-arm64"
			return "macos-amd64" if architecture in ["x86_64", "amd64"] else ""
		"Linux":
			return "linux-x86_64" if architecture in ["x86_64", "amd64"] else ""
	return ""


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message}}
