extends SceneTree

const Client = preload("res://Scripts/Services/MCP/JSONSchemaValidatorClient.gd")

var passed := 0
var failed := 0

class FakeProcess extends Node:
	signal output_ready
	signal process_exited(code: int)
	signal io_overflow
	var running := false
	var output: Array[String] = []
	var writes: Array[Dictionary] = []
	var answer_requests := true
	var reject_writes := false
	var next_handle := 20
	var stop_record := {"called": false}

	func start(_path: String, _args: PackedStringArray) -> bool:
		running = true
		return true
	func stop() -> void:
		running = false
		stop_record.called = true
	func is_running() -> bool:
		return running
	func has_output() -> bool:
		return not output.is_empty()
	func read_line() -> String:
		return output.pop_front()
	func write_data(line: String) -> bool:
		if reject_writes:
			return false
		var request: Dictionary = JSON.parse_string(line)
		writes.append(request)
		if answer_requests:
			var reply := {"id": request.id, "ok": true}
			if request.op == "compile":
				reply["handle"] = next_handle
				next_handle += 1
			elif request.op == "validate":
				reply["valid"] = true
				reply["godot_numeric_safe"] = true
			output.append(JSON.stringify(reply))
			output_ready.emit()
		return true
	func lose() -> void:
		running = false
		process_exited.emit(9)


func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool, details: String = "") -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label, " — ", details)

func collect(operation: Callable, destination: Dictionary, key: String) -> void:
	destination[key] = await operation.call()

func collect_then_retry(client, operation: Callable, schema_raw: String,
		destination: Dictionary) -> void:
	destination["failed"] = await operation.call()
	destination["retry"] = await client.compile(schema_raw)

func _run() -> void:
	var missing_client := Client.new()
	root.add_child(missing_client)
	missing_client.helper_path = "user://nonexistent-schema-helper-for-startup-regression"
	var missing: Dictionary = await missing_client.compare_application_numbers("1", 1)
	var missing_message := str(missing.get("error", {}).get("message", ""))
	check("missing native helper reports its path and setup command before process creation",
		missing.get("error", {}).get("code") == "validator_unavailable"
		and missing_message.contains(missing_client.helper_path)
		and missing_message.contains("build-extensions")
		and missing_client._process == null, missing_message)
	missing_client.queue_free()
	check("packaged helper targets reject unsupported architectures explicitly",
		Client._runtime_target("Linux", "x86_64") == "linux-x86_64"
		and Client._runtime_target("Windows", "x86_64") == "windows-x86_64"
		and Client._runtime_target("macOS", "arm64") == "macos-arm64"
		and Client._runtime_target("macOS", "x86_64") == "macos-amd64"
		and Client._runtime_target("Linux", "arm64").is_empty())
	var processes: Array[FakeProcess] = []
	var client := Client.new()
	root.add_child(client)
	client._process_factory = func():
		var process := FakeProcess.new()
		processes.append(process)
		return process
	var compiled: Dictionary = await client.compile("{\"type\":\"object\"}")
	check("compile starts helper and returns a generation-bound raw schema handle",
		compiled.get("ok", false) and compiled.handle.schema_raw == "{\"type\":\"object\"}"
		and processes.size() == 1)
	var validated: Dictionary = await client.validate_for_application(compiled.handle, "{\"n\":1}", {"n": 1})
	check("application validation sends raw instance before numeric adaptation check",
		validated.get("valid", false) and processes[0].writes[-2].instance_raw == "{\"n\":1}"
		and processes[0].writes[-1].op == "compare_numbers")
	var aggregate_limit: Dictionary = await client.compile("{}", {
		"urn:a": " ".repeat(2 * 1024 * 1024), "urn:b": " ".repeat(2 * 1024 * 1024)})
	check("schema registry bytes are bounded before Godot serializes a helper request",
		aggregate_limit.get("error", {}).get("code") == "schema_too_large")

	processes[0].lose()
	check("helper process failure retains the exit status",
		client.last_failure_reason.contains("exited with code 9"), client.last_failure_reason)
	var stale: Dictionary = await client.validate_raw(compiled.handle, "{}")
	check("process loss invalidates every old handle", stale.get("error", {}).get("code") == "invalid_handle")
	var restarted: Dictionary = await client.compile(compiled.handle.schema_raw)
	check("retained raw schema can be explicitly recompiled in a new generation",
		restarted.get("ok", false) and processes.size() == 2
		and restarted.handle.generation != compiled.handle.generation)

	processes[1].answer_requests = false
	var pending_results := {}
	var reentrant := {}
	collect_then_retry(client, client._request.bind({"op": "validate",
		"handle": restarted.handle.native_id, "instance_raw": "0"}),
		restarted.handle.schema_raw, reentrant)
	for index in range(1, Client.MAX_PENDING):
		collect(client._request.bind({"op": "validate", "handle": restarted.handle.native_id,
			"instance_raw": str(index)}), pending_results, str(index))
	var overflow: Dictionary = await client._request({"op": "validate", "handle": restarted.handle.native_id,
		"instance_raw": "32"})
	check("supervisor rejects work beyond its finite pending-request bound",
		overflow.get("error", {}).get("code") == "queue_full" and client._pending.size() == Client.MAX_PENDING)
	processes[1].io_overflow.emit()
	await process_frame
	check("a failed waiter retries inside overflow delivery against only the new process",
		pending_results.size() == Client.MAX_PENDING - 1 and client._pending.is_empty()
		and reentrant.get("failed", {}).get("error", {}).get("code") == "process_lost"
		and reentrant.get("retry", {}).get("ok", false)
		and processes.size() == 3 and processes[2].running)

	var deadline_process := FakeProcess.new()
	var deadline_stop_record: Dictionary = deadline_process.stop_record
	client.stop()
	client._process_factory = func(): return deadline_process
	var ready: Error = await client.start()
	deadline_process.answer_requests = false
	var original_time_scale := Engine.time_scale
	Engine.time_scale = 0.5
	var began := Time.get_ticks_msec()
	var deadline_result: Dictionary = await client._request(
		{"op": "validate", "handle": 1, "instance_raw": "null"})
	var elapsed := Time.get_ticks_msec() - began
	Engine.time_scale = original_time_scale
	var deadline_code := str(deadline_result.get("error", {}).get("code", ""))
	var deadline_detached := client._process == null
	check("monotonic deadline ignores slow engine time and immediately detaches its helper",
		ready == OK and deadline_code == "deadline_exceeded"
		and elapsed >= 1900 and elapsed < 3000 and deadline_detached
		and client._pending.is_empty(),
		"ready=%s code=%s elapsed_ms=%d detached=%s pending=%d" % [
			ready, deadline_code, elapsed, deadline_detached, client._pending.size()])
	await process_frame
	check("deadline retirement stops the detached process on the deferred boundary",
		deadline_stop_record.called)

	var exit_process := FakeProcess.new()
	var exit_stop_record: Dictionary = exit_process.stop_record
	var exit_client := Client.new()
	root.add_child(exit_client)
	exit_client._process_factory = func(): return exit_process
	await exit_client.start()
	exit_process.answer_requests = false
	var exit_retry := {}
	collect_then_retry(exit_client, exit_client._request.bind(
		{"op": "validate", "handle": 1, "instance_raw": "null"}), "{}", exit_retry)
	root.remove_child(exit_client)
	await process_frame
	check("tree exit rejects replacement startup from a synchronously failed waiter",
		exit_retry.get("failed", {}).get("error", {}).get("code") == "process_lost"
		and exit_retry.get("retry", {}).get("error", {}).get("code") == "validator_unavailable"
		and exit_client._process == null and exit_stop_record.called)
	exit_client.queue_free()

	client.stop()
	client.queue_free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
