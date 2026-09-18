extends SceneTree
## Real-child dual-era STDIO coverage. One dispatcher negotiates each process;
## no transport mock stands in for probe timing, late frames, or cancellation.
## The Manager removal case writes MCP config; use isolated user data.

const CONNECTION_PATH := "res://Scripts/Services/MCP/MCPServerConnection.gd"
const CONTEXT_PATH := "res://Scripts/Services/MCP/MCPExecutionContext.gd"
const PROFILE_PATH := "res://Scripts/Services/MCP/MCPProfile.gd"
const WIRE_ADAPTER_PATH := "res://Scripts/Services/MCP/MCPWireAdapter.gd"
const WIRE_VALUE_PATH := "res://Scripts/Services/MCP/MCPWireValue.gd"
const FIXTURE_REL := "res://test/fixtures/stdio_timing_probe/stdio_timing_probe.py"
const LOG_CAPTURE_PATH := "res://test/helpers/log_capture.gd"
const MANAGER_PATH := "res://Scripts/Services/MCP/MCPManager.gd"
const CONFIG_PATH := "res://Scripts/Services/MCP/MCPConfig.gd"

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.execute("python3", ["--version"], [], true) != OK:
		print("SKIP: python3 unavailable")
		quit(0)
		return
	var connection_script = load(CONNECTION_PATH)
	var context_script = load(CONTEXT_PATH)
	var profile_script = load(PROFILE_PATH)
	var wire_adapter = load(WIRE_ADAPTER_PATH)
	var wire_value = load(WIRE_VALUE_PATH)
	var fixture := ProjectSettings.globalize_path(FIXTURE_REL)
	var capture = load(LOG_CAPTURE_PATH).new()
	OS.add_logger(capture)
	var singleton = root.get_node("SingletonObject")
	var saved_verbose: bool = singleton.verbose_logging
	singleton.verbose_logging = false

	var modern = connection_script.new("modern-fixture")
	modern.configure_stdio("python3", PackedStringArray([fixture, "--profile", "modern"]))
	check("modern child negotiates without initialize",
		await modern.connect_to_server() == OK
		and modern.protocol_profile.era == profile_script.Era.MODERN_2026_07_28)
	var envelopes: Array = []
	modern.tool_result_envelope_received.connect(func(_name: String, value) -> void:
		envelopes.append(value))
	var echo: Dictionary = await modern.call_tool("echo", {"marker": "modern-native"}, 5.0)
	check("modern request carries metadata and preserves native plus full wire result",
		echo.get("echo", {}).get("marker") == "modern-native" and envelopes.size() == 1
		and envelopes[0].wire_value != null
		and envelopes[0].to_mcp_format().get("futureField", {}).get("kept", false)
		and envelopes[0].wire_value.raw_utf8.contains("structuredContent"))
	var quiet_log: String = capture.combined()
	singleton.verbose_logging = true
	var log_start: int = capture.size()
	var secret_marker := "SECRET_TRANSPORT_ARGUMENT"
	var logged_echo: Dictionary = await modern.call_tool("echo", {"marker": secret_marker}, 5.0)
	var verbose_log: String = capture.since(log_start)
	check("transport logging is quiet by default and metadata-only when verbose",
		logged_echo.get("echo", {}).get("marker") == secret_marker
		and "Sending method=tools/call" not in quiet_log
		and "Sending method=tools/call" in verbose_log and "Received kind=" in verbose_log
		and secret_marker not in verbose_log)
	var precise: Dictionary = await modern.call_tool("echo", {"precise": 0.12345678901234566, "canonical": 0.1}, 5.0)
	check("STDIO shared serialization preserves finite native float precision",
		precise.get("echo", {}).get("precise") == 0.12345678901234566
		and precise.get("echo", {}).get("canonical") == 0.1)
	var nonfinite: Dictionary = await modern.call_tool("echo", {"value": NAN}, 5.0)
	var infinite: Dictionary = await modern.call_tool("echo", {"value": INF}, 5.0)
	check("STDIO rejects nonfinite values before admission without leaking pending calls",
		nonfinite.has("error") and infinite.has("error") and modern.pending_request_count() == 0)
	var envelope_count := envelopes.size()
	var changed_number: Dictionary = await modern.call_tool("precision_loss", {}, 5.0)
	check("raw numeric incompatibility fails before parsed result emission",
		changed_number.has("error") and envelopes.size() == envelope_count)
	var changed_error_data: Dictionary = await modern.call_tool("error_precision_loss", {}, 5.0)
	check("raw numeric guard covers RPC error data before application exposure",
		changed_error_data.has("error") and changed_error_data.error != "fixture error"
		and envelopes.size() == envelope_count)
	var nested_number: Dictionary = await modern.call_tool("nested_precision_loss", {}, 5.0)
	check("JSON embedded in legacy text is numerically validated before exposure",
		nested_number.get("error_code") == "unsupported_number"
		and nested_number.get("error_message") == "Unsafe numeric representation in MCP text result"
		and nested_number.get("error_details", {}).get("pointer") == "/n"
		and nested_number.get("error_details", {}).get("original") \
			== "0.10000000000000001"
		and envelopes.size() == envelope_count + 1)
	var scalar_number: Dictionary = await modern.call_tool("scalar_precision_loss", {}, 5.0)
	check("a scalar JSON text result cannot bypass the nested numeric boundary",
		scalar_number.get("error_code") == "unsupported_number"
		and envelopes.size() == envelope_count + 2)
	var interaction = await modern.call_tool_outcome("input_required", {}, 5.0)
	check("input_required is classified before content adaptation and preserves request state",
		interaction.envelope.result_type == "input_required"
		and interaction.application.get("error_code") == "input_required"
		and interaction.application.get("requestState", {}).get("opaque")
		and not interaction.application.has("text"))

	var context = context_script.create("profile-test", "", "", 10.0)
	var cancelled_results: Array = []
	var sibling_results: Array = []
	_collect(modern.call_tool_with_context.bind("never_reply", {}, context), cancelled_results)
	_collect(modern.call_tool.bind("sleep", {"ms": 250}, 5.0), sibling_results)
	await process_frame
	context.cancel()
	check("owned modern cancellation resolves its waiter once", await _wait_size(cancelled_results, 1, 3000)
		and cancelled_results[0].get("error_code") == "cancelled")
	var cancellations: Dictionary = await modern.call_tool("cancellations", {}, 5.0)
	check("modern cancellation notification names only the cancelled request",
		cancellations.get("cancelled_ids", []).size() == 1)
	check("owned cancellation does not disturb an already in-flight sibling",
		await _wait_size(sibling_results, 1, 3000)
		and sibling_results[0].get("slept_ms") == 250)
	var after_cancel: Dictionary = await modern.call_tool("echo", {"marker": "still-live"}, 5.0)
	check("cancelling one modern request does not affect a sibling call",
		after_cancel.get("echo", {}).get("marker") == "still-live")
	# All calls enter the adapter in this Godot turn, before the real helper can
	# complete one. This isolates the adapter's 32-admission bound from the
	# native stdout queue and child scheduling.
	var flood_results: Array = []
	for index in range(40):
		var raw := '{"index":%d}' % index
		_collect(wire_adapter.validate_for_application.bind(
			wire_value.create(raw, {"index": index}), 5.0), flood_results)
	var flood_settled := await _wait_size(flood_results, 40, 7000)
	var bounded_rejections := 0
	for flood_result: Variant in flood_results:
		if flood_result is Dictionary and str(flood_result.get("error", "")).contains("queue is full"):
			bounded_rejections += 1
	check("raw validation admission is bounded before helper work and every caller settles",
		flood_settled and bounded_rejections == 8 and modern.pending_request_count() == 0,
		"settled=%s rejected=%d" % [flood_settled, bounded_rejections])

	# Restart the shared real helper, then replace the MCP process while a large
	# result is awaiting numeric validation. The old generation must settle its
	# caller without publishing an application envelope into the replacement.
	var shared_validator = wire_adapter._shared_validator()
	shared_validator.stop()
	envelope_count = envelopes.size()
	var validation_results: Array = []
	_collect(modern.call_tool.bind("large_numeric", {}, 5.0), validation_results)
	var validation_observed := await _wait_for_validation(wire_adapter, 3000)
	modern.disconnect_from_server()
	modern.configure_stdio("python3", PackedStringArray([fixture, "--profile", "modern"]))
	var validation_reconnect: Error = await modern.connect_to_server()
	var validation_settled := await _wait_size(validation_results, 1, 5000)
	check("process replacement during awaited raw validation emits no late result envelope",
		validation_observed and validation_reconnect == OK and validation_settled
		and validation_results[0].has("error") and envelopes.size() == envelope_count,
		"observed=%s reconnect=%d settled=%s envelopes=%d" % [
			validation_observed, validation_reconnect, validation_settled, envelopes.size()])
	var validation_echo: Dictionary = await modern.call_tool("echo", {"marker": "validation-owner"}, 5.0)
	check("replacement after validation cancellation remains usable",
		validation_echo.get("echo", {}).get("marker") == "validation-owner")
	var stderr_calls_ok := true
	# The native subprocess queue holds 32 stderr lines. More than one queue's
	# worth of paced, valid requests proves diagnostics are consumed throughout
	# the session rather than only at startup or teardown. Keep this negative
	# control last so an unfixed overflow cannot obscure earlier modern checks.
	for index in range(40):
		var stderr_result: Dictionary = await modern.call_tool(
			"stderr_line", {"index": index}, 5.0)
		if stderr_result.get("index") != index:
			stderr_calls_ok = false
			break
	var after_stderr: Dictionary = await modern.call_tool(
		"echo", {"marker": "stderr-drained"}, 5.0)
	check("paced worker diagnostics beyond the native queue remain bounded",
		stderr_calls_ok and modern.server_connected
		and after_stderr.get("echo", {}).get("marker") == "stderr-drained")
	modern.disconnect_from_server()

	var reentrant = connection_script.new("reentrant-fixture")
	reentrant.configure_stdio("python3", PackedStringArray([fixture, "--profile", "modern"]))
	check("reentrant fixture initially connects", await reentrant.connect_to_server() == OK)
	var reconnect_results: Array = []
	_call_then_reconnect(reentrant, fixture, reconnect_results)
	await process_frame
	reentrant.disconnect_from_server()
	check("failed waiter can immediately reconnect after transport detaches",
		await _wait_size(reconnect_results, 1, 5000) and reconnect_results[0] == OK)
	var reconnect_echo: Dictionary = await reentrant.call_tool("echo", {"marker": "replacement"}, 5.0)
	check("retiring process cannot stop the replacement connection",
		reconnect_echo.get("echo", {}).get("marker") == "replacement")
	reentrant.disconnect_from_server()

	var startup_race = connection_script.new("startup-race-fixture")
	startup_race.configure_stdio("python3", PackedStringArray([fixture, "--profile", "modern"]))
	var startup_results: Array = []
	_collect(startup_race.connect_to_server.bind(), startup_results)
	await process_frame
	startup_race.disconnect_from_server()
	_collect(startup_race.connect_to_server.bind(), startup_results)
	var startup_settled := await _wait_size(startup_results, 2, 5000)
	var failed_startups := 0
	for status: Variant in startup_results:
		if status != OK:
			failed_startups += 1
	check("disconnect during startup cannot attach old readers or null the replacement",
		startup_settled and startup_results.has(OK) and failed_startups == 1)
	var startup_echo: Dictionary = await startup_race.call_tool("echo", {"marker": "startup-owner"}, 5.0)
	check("replacement after startup cancellation owns a usable dispatcher",
		startup_echo.get("echo", {}).get("marker") == "startup-owner")
	startup_race.disconnect_from_server()

	var late = connection_script.new("late-probe-fixture")
	late.working_directory = "/tmp/profile-working-directory"
	late.configure_stdio("python3", PackedStringArray([fixture, "--profile", "late_probe"]))
	check("probe timeout falls back to validated initialized legacy profile",
		await late.connect_to_server() == OK
		and late.protocol_profile.era == profile_script.Era.INITIALIZED_LEGACY)
	await create_timer(0.7).timeout
	var late_echo: Dictionary = await late.call_tool("echo", {"marker": "late-safe"}, 5.0)
	check("late discovery reply is isolated and legacy connection remains usable",
		late_echo.get("echo", {}).get("marker") == "late-safe" and late.pending_request_count() == 0)
	var session: Dictionary = await late.call_tool("session", {}, 5.0)
	check("legacy initialization preserves configured working directory",
		session.get("working_directory") == "/tmp/profile-working-directory")
	late.disconnect_from_server()

	var timed_out = connection_script.new("startup-budget-fixture")
	timed_out.stdio_discovery_budget_sec = 0.2
	timed_out.stdio_startup_budget_sec = 0.7
	timed_out.configure_stdio("python3", PackedStringArray([fixture, "--profile", "all_timeout"]))
	var startup_ms := Time.get_ticks_msec()
	var prior_time_scale := Engine.time_scale
	Engine.time_scale = 0.5
	var timeout_status: Error = await timed_out.connect_to_server()
	var startup_elapsed := Time.get_ticks_msec() - startup_ms
	Engine.time_scale = prior_time_scale
	check("probe fallback and initialize share one finite startup budget",
		timeout_status != OK and startup_elapsed >= 550 and startup_elapsed < 2000,
		"status=%d elapsed_ms=%d" % [timeout_status, startup_elapsed])
	timed_out.disconnect_from_server()

	var modern_error = connection_script.new("modern-error-fixture")
	modern_error.configure_stdio("python3", PackedStringArray([fixture, "--profile", "modern_error"]))
	check("recognized modern error never falls back to legacy initialize",
		await modern_error.connect_to_server() != OK
		and modern_error.protocol_profile.era == profile_script.Era.MODERN_2026_07_28)
	modern_error.disconnect_from_server()
	var error_log: String = capture.combined()
	check("peer error logging exposes a code and never its response payload",
		"peer error code" in error_log and "SECRET_PEER_RESPONSE" not in error_log)

	var invalid = connection_script.new("invalid-modern-fixture")
	invalid.configure_stdio("python3", PackedStringArray([fixture, "--profile", "invalid_modern"]))
	check("modern discovery with no supported version fails without downgrade",
		await invalid.connect_to_server() != OK)
	invalid.disconnect_from_server()

	var paginated = connection_script.new("paginated-fixture")
	paginated.configure_stdio("python3", PackedStringArray([fixture, "--profile", "paginated"]))
	check("bounded tools/list pagination atomically collects every page",
		await paginated.connect_to_server() == OK and await paginated.refresh_tools() == OK
		and paginated.tools.size() == 21
		and paginated.has_tool("valid_array_output")
		and not paginated.has_tool("invalid_input_root")
		and not paginated.has_tool("invalid_output_root"))
	paginated.disconnect_from_server()

	var repeated = connection_script.new("repeated-cursor-fixture")
	repeated.configure_stdio("python3", PackedStringArray([fixture, "--profile", "repeat_cursor"]))
	check("repeated pagination cursor fails without replacing the prior catalog",
		await repeated.connect_to_server() == OK and await _seed_then_fail_refresh(repeated) \
		and repeated.tools.size() == 1 and repeated.tools[0].name == "kept")
	repeated.disconnect_from_server()

	var partial = connection_script.new("partial-page-fixture")
	partial.configure_stdio("python3", PackedStringArray([fixture, "--profile", "second_page_error"]))
	check("later-page failure cannot publish a partial catalog",
		await partial.connect_to_server() == OK and await _seed_then_fail_refresh(partial) \
		and partial.tools.size() == 1 and partial.tools[0].name == "kept")
	partial.disconnect_from_server()

	var duplicate = connection_script.new("duplicate-tool-fixture")
	duplicate.configure_stdio("python3", PackedStringArray([fixture, "--profile", "duplicate_tools"]))
	check("duplicate names cannot silently retarget an atomically published catalog",
		await duplicate.connect_to_server() == OK and await _seed_then_fail_refresh(duplicate) \
		and duplicate.tools.size() == 1 and duplicate.tools[0].name == "kept")
	duplicate.disconnect_from_server()

	var manager = load(MANAGER_PATH).new()
	var config_script = load(CONFIG_PATH)
	manager.config = config_script.new()
	manager.config.servers.clear()
	var managed = config_script.ServerConfig.create_stdio("managed", "python3",
		PackedStringArray([fixture, "--profile", "modern"]))
	managed.origin = "user"
	managed.persistent = false
	manager.config.set_server(managed)
	check("manager publishes negotiated diagnostics from a real child",
		await manager.connect_server("managed") == OK
		and manager.get_server_diagnostic("managed").era == "modern")
	manager.disconnect_server("managed")
	managed.args = PackedStringArray([fixture, "--profile", "modern_error"])
	check("manager records an actionable real peer rejection without remaining connecting",
		await manager.connect_server("managed") != OK
		and manager.get_server_diagnostic("managed").state == "failed"
		and "peer error code -32021" in manager.get_server_diagnostic("managed").failure)
	manager.remove_server_at_runtime("managed")
	check("manager removal clears the real attempt diagnostic",
		not manager._connection_diagnostics.has("managed"))
	manager.free()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	singleton.verbose_logging = saved_verbose
	OS.remove_logger(capture)
	quit(1 if failed else 0)


func _collect(operation: Callable, results: Array) -> void:
	results.append(await operation.call())


func _call_then_reconnect(connection, fixture: String, results: Array) -> void:
	await connection.call_tool("never_reply", {}, 0.0)
	connection.configure_stdio("python3", PackedStringArray([fixture, "--profile", "modern"]))
	results.append(await connection.connect_to_server())


func _wait_size(values: Array, expected: int, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while values.size() < expected and Time.get_ticks_msec() < deadline:
		await process_frame
	return values.size() == expected


func _wait_for_validation(wire_adapter, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while wire_adapter._active_validations == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	return wire_adapter._active_validations > 0


func _seed_then_fail_refresh(connection) -> bool:
	var definition = load("res://Scripts/Services/MCP/MCPToolDefinition.gd").from_dict(
		{"name": "kept", "inputSchema": {"type": "object"}}, "fixture")
	connection.tools = [definition]
	return await connection.refresh_tools() != OK


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if not detail.is_empty() else ""])
