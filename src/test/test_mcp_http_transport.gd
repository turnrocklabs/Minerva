extends SceneTree
## Real loopback HTTP and native numeric helper. Requires isolated user data;
## no external services, credentials, microphone or production plugin are used.
const HeaderRules = preload("res://Scripts/Services/MCP/MCPHttpHeaders.gd")
const Decoder = preload("res://Scripts/Services/MCP/MCPSseDecoder.gd")
var passed := 0
var failed := 0
var peer
var base := ""

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _collect(operation: Callable, results: Array) -> void:
	results.append(await operation.call())

func _wait(results: Array, count: int, milliseconds: int = 5000) -> bool:
	var until := Time.get_ticks_msec() + milliseconds
	while results.size() < count and Time.get_ticks_msec() < until:
		await process_frame
	return results.size() == count

func _run() -> void:
	var connection_script = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var context_script = load("res://Scripts/Services/MCP/MCPExecutionContext.gd")
	var profile_script = load("res://Scripts/Services/MCP/MCPProfile.gd")
	peer = ClassDB.instantiate("SubProcess")
	root.add_child(peer)
	var python := OS.get_environment("PYTHON")
	if python.is_empty():
		python = "python3"
	var started: bool = peer.start(python, PackedStringArray(["-u", ProjectSettings.globalize_path("res://test/fixtures/http_mcp_probe/server.py")]))
	check("loopback peer starts", started)
	var until := Time.get_ticks_msec() + 5000
	while base.is_empty() and Time.get_ticks_msec() < until:
		while peer.has_output():
			var line: String = peer.read_line()
			var value: Variant = JSON.parse_string(line)
			if value is Dictionary and value.has("port"):
				base = "http://127.0.0.1:%d" % int(value.port)
		await process_frame
	if base.is_empty():
		check("loopback endpoint published", false)
		_finish()
		return
	var modern = connection_script.new("modern-http", base)
	check("modern discovery negotiates without initialize", await modern.connect_to_server() == OK
		and modern.protocol_profile.era == profile_script.Era.MODERN_2026_07_28)
	check("invalid annotated tool excluded without losing valid tool", await modern.refresh_tools() == OK
		and modern.tools.size() == 1 and modern.tools[0].name == "echo")
	var echo: Dictionary = await modern.call_tool("echo", {"nested": {"value": " 世界 "}, "count": 42.0, "flag": true})
	var headers: Dictionary = echo.get("headers", {})
	check("modern headers mirror typed arguments and unsafe Unicode", headers.get("Mcp-Param-Value") == HeaderRules.encode(" 世界 ")
		and headers.get("Mcp-Param-Count") == "42" and headers.get("Mcp-Param-Flag") == "true"
		and headers.get("Mcp-Method") == "tools/call" and headers.get("Mcp-Name") == "echo"
		and headers.get("Accept") == "application/json, text/event-stream" and not headers.has("Mcp-Session-Id"))
	var precise: Dictionary = await modern.call_tool("echo", {"precise": 0.12345678901234566, "canonical": 0.1})
	check("native finite floats survive validated HTTP serialization exactly", precise.get("echo", {}).get("precise") == 0.12345678901234566
		and precise.get("echo", {}).get("canonical") == 0.1)
	var nan_result: Dictionary = await modern.call_tool("echo", {"nonfinite_marker": "nan", "value": NAN})
	var inf_result: Dictionary = await modern.call_tool("echo", {"nonfinite_marker": "inf", "value": INF})
	var numeric_records: Dictionary = await modern.call_tool("records", {})
	var nonfinite_sent := false
	for record: Dictionary in numeric_records.get("records", []):
		if record.request.get("params", {}).get("arguments", {}).has("nonfinite_marker"):
			nonfinite_sent = true
	check("NaN and infinity fail before sending a tool request", nan_result.has("error") and inf_result.has("error") and not nonfinite_sent)
	var omitted: Dictionary = await modern.call_tool("echo", {"nested": {"value": null}})
	check("null and absent annotated values omit headers", not omitted.get("headers", {}).has("Mcp-Param-Value")
		and not omitted.get("headers", {}).has("Mcp-Param-Count"))
	var envelopes: Array = []
	modern.tool_result_envelope_received.connect(func(_name: String, envelope): envelopes.append(envelope))
	var streamed: Dictionary = await modern.call_tool("sse", {})
	check("chunked multiline SSE preserves split UTF8 and complete raw envelope", not streamed.has("error")
		and envelopes.size() == 1 and envelopes[0].to_mcp_format().get("future", false)
		and envelopes[0].wire_value.raw_utf8.contains("世界"))
	var envelope_cancel_context = context_script.create("http-envelope-cancel")
	var application_emissions: Array = []
	modern.tool_result_received.connect(func(_name: String, _result: Dictionary) -> void:
		application_emissions.append(true))
	modern.tool_result_envelope_received.connect(
		func(_name: String, _envelope) -> void: envelope_cancel_context.cancel(), CONNECT_ONE_SHOT)
	var envelope_cancelled = await modern.call_tool_outcome_with_context(
		"sse", {}, envelope_cancel_context)
	check("synchronous HTTP envelope cancellation suppresses the stale application signal",
		envelope_cancelled.application.has("error") and application_emissions.is_empty())
	var progress: Array = []
	modern.http_notification_received.connect(func(message: Dictionary, request_id: Variant): progress.append([message, request_id]))
	var progressed: Dictionary = await modern._http_transport.request_method("tools/call", {"name": "sse-progress", "arguments": {}, "_meta": {"progressToken": "owned"}})
	check("SSE progress carries matching token and originating request ID", progressed.has("result")
		and progress.size() == 1 and progress[0][0].params.progressToken == "owned"
		and progress[0][1] == progressed.wire.parsed.id)
	var truncated: Dictionary = await modern.call_tool("truncated", {})
	check("valid JSON prefix cannot bypass incomplete Content-Length", truncated.has("error"))
	var eof_framed: Dictionary = await modern.call_tool("eof-framed", {})
	var truncated_chunked: Dictionary = await modern.call_tool("truncated-chunked", {})
	check("EOF framing is accepted only without explicit length or chunk framing", eof_framed.get("eof_result", false) and truncated_chunked.has("error"))
	var accepted_envelopes := envelopes.size()
	var unsafe: Dictionary = await modern.call_tool("unsafe", {})
	check("unsafe response numbers fail before application envelope", unsafe.has("error") and envelopes.size() == accepted_envelopes)
	var wrong: Dictionary = await modern.call_tool("wrong-id", {})
	check("response IDs remain request correlated", wrong.has("error"))
	var first: Array = []
	var sibling: Array = []
	var context = context_script.create("http-fixture", "", "", 5.0)
	_collect(modern.call_tool_with_context.bind("sleep", {"ms": 1500}, context), first)
	_collect(modern.call_tool.bind("sleep", {"ms": 100}), sibling)
	await create_timer(0.1).timeout
	context.cancel()
	check("context cancellation settles one request and leaves sibling live", await _wait(first, 1)
		and first[0].has("error") and await _wait(sibling, 1) and sibling[0].get("slept", false))
	var deadline_context = context_script.create("http-deadline", "", "", 0.05)
	var deadline_result: Dictionary = await modern.call_tool_with_context("sleep", {"ms": 1500}, deadline_context)
	check("owned deadline settles without waiting for peer", deadline_result.has("error"))
	var old: Array = []
	_collect(modern.call_tool.bind("sleep", {"ms": 1500}), old)
	await create_timer(0.1).timeout
	modern.disconnect_from_server()
	check("disconnect settles old waiter while replacement negotiates", await modern.connect_to_server() == OK
		and await _wait(old, 1) and old[0].has("error"))
	var lost: Dictionary = await modern.call_tool("lost", {})
	var records: Dictionary = await modern.call_tool("records", {})
	var mutations := 0
	for record: Dictionary in records.get("records", []):
		if record.request.get("params", {}).get("name") == "lost":
			mutations += 1
	check("lost mutation reply is not replayed", lost.has("error") and mutations == 1)
	var legacy = connection_script.new("legacy-http", base)
	legacy.mcp_endpoint = "/legacy"
	check("legacy initialize negotiates an isolated session", await legacy.connect_to_server() == OK
		and legacy.protocol_profile.era == profile_script.Era.INITIALIZED_LEGACY)
	var legacy_echo: Dictionary = await legacy.call_tool("echo", {})
	check("legacy calls retain session and omit modern method headers", legacy_echo.get("headers", {}).get("Mcp-Session-Id") == "legacy-session"
		and not legacy_echo.get("headers", {}).has("Mcp-Method"))
	var rejected = connection_script.new("modern-rejection", base)
	rejected.mcp_endpoint = "/modern-error"
	check("modern non2xx protocol error is not legacy success", await rejected.connect_to_server() != OK)
	var error_transport = load("res://Scripts/Services/MCP/MCPHttpTransport.gd").new()
	var explicit_error: Dictionary = await error_transport.connect_endpoint(base + "/modern-error")
	check("non2xx modern errors preserve status code data and original wire", explicit_error.get("status") == 400
		and explicit_error.get("rpc_error", {}).get("code") == -32022
		and explicit_error.get("rpc_error", {}).get("data", {}).get("supported") == ["future"]
		and explicit_error.get("wire") != null)
	error_transport.disconnect_transport()
	var invalid = connection_script.new("invalid-initialize", base)
	invalid.mcp_endpoint = "/invalid-init"
	check("empty initialize plus session is not accepted", await invalid.connect_to_server() != OK)
	var after_rejections: Dictionary = await modern.call_tool("records", {})
	var forbidden_initialize := false
	var missing_meta := false
	for record: Dictionary in after_rejections.get("records", []):
		if record.path == "/modern-error" and record.request.method == "initialize":
			forbidden_initialize = true
		if record.path == "/mcp":
			var meta: Dictionary = record.request.get("params", {}).get("_meta", {})
			if meta.get("io.modelcontextprotocol/protocolVersion") != "2026-07-28" or not meta.has("io.modelcontextprotocol/clientCapabilities"):
				missing_meta = true
	check("modern rejection never initializes and every modern POST carries metadata", not forbidden_initialize and not missing_meta)
	var default_schema := {"type": "object", "default": {"x-mcp-header": "literal"}, "properties": {"x-mcp-header": {"type": "string"}}}
	check("schema traversal does not reinterpret annotation data or property names", HeaderRules.annotations(default_schema).error.is_empty()
		and HeaderRules.encode("=?base64?literal?=") != "=?base64?literal?=")
	var decoder = Decoder.new()
	decoder.total = decoder.MAX_TOTAL_BYTES
	decoder.feed(PackedByteArray([1]))
	check("SSE aggregate limit rejects before appending excess bytes", not decoder.error.is_empty() and decoder.buffer.is_empty())
	modern.disconnect_from_server()
	legacy.disconnect_from_server()
	rejected.disconnect_from_server()
	invalid.disconnect_from_server()
	_finish()

func _finish() -> void:
	if peer != null:
		peer.stop()
		peer.queue_free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
