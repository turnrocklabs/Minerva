extends SceneTree
## Real loopback coverage for dual-era public dispatch, SSE and admission.
## Requires the source-built JSON Schema helper and isolated user data.

const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const HeaderRules = preload("res://Scripts/Services/MCP/MCPHttpHeaders.gd")

var passed := 0
var failed := 0
var server
var fixture
var port := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label, " ", detail)


func _modern_meta(capabilities: Dictionary = {}) -> Dictionary:
	return Protocol.modern_meta(Protocol.MODERN_VERSION, capabilities)


func _message(method: String, id: Variant, params: Dictionary = {}, modern := true) -> Dictionary:
	var request := {"jsonrpc": "2.0", "id": id, "method": method,
		"params": params.duplicate(true)}
	if modern:
		request.params["_meta"] = _modern_meta()
	return request


func _collect(operation: Callable, output: Array) -> void:
	output.append(await operation.call())


func _wait_until(predicate: Callable, timeout_ms := 5000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()


func _http(request: Dictionary, extra_headers: PackedStringArray = PackedStringArray()) -> Dictionary:
	return await _raw_http(JSON.stringify(request).to_utf8_buffer(), extra_headers)


func _raw_http(body: PackedByteArray,
		extra_headers: PackedStringArray = PackedStringArray(),
		mirror_headers := true, request_line := "POST /mcp HTTP/1.1") -> Dictionary:
	var peer = await _open_http(body, extra_headers, mirror_headers, request_line)
	if peer == null:
		return _failed_response("connect timeout")
	var response := PackedByteArray()
	var finished := await _wait_until(func() -> bool:
		peer.poll()
		var peer_status: int = peer.get_status()
		if peer_status == StreamPeerTCP.STATUS_CONNECTED:
			var available: int = peer.get_available_bytes()
			if available > 0:
				var read = peer.get_data(available)
				if read[0] == OK:
					response.append_array(read[1])
		return peer_status in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR], 10000)
	if not finished:
		peer.disconnect_from_host()
		return _failed_response("response timeout")
	return _parse_response(response)


func _failed_response(reason: String, raw: String = "") -> Dictionary:
	return {"status": 0, "headers": {}, "body": "", "json": {},
		"error": reason, "raw": raw}


func _open_http(body: PackedByteArray,
		extra_headers: PackedStringArray = PackedStringArray(), mirror_headers := true,
		request_line := "POST /mcp HTTP/1.1"):
	var peer := StreamPeerTCP.new()
	var status := peer.connect_to_host("127.0.0.1", port)
	if status != OK:
		return null
	var connected := await _wait_until(func() -> bool:
		peer.poll()
		return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	if not connected:
		return null
	var headers := PackedStringArray([
		request_line, "Host: 127.0.0.1", "Content-Type: application/json",
		"Accept: application/json, text/event-stream",
		"Content-Length: %d" % body.size(), "Connection: close"])
	headers.append_array(extra_headers)
	if mirror_headers and _has_header(headers, "mcp-protocol-version"):
		var request: Variant = JSON.parse_string(body.get_string_from_utf8())
		if request is Dictionary and request.get("method") is String:
			if not _has_header(headers, "mcp-method"):
				headers.append("Mcp-Method: " + request.method)
			if request.method in ["tools/call", "resources/read", "prompts/get"] \
					and not _has_header(headers, "mcp-name"):
				var request_params: Dictionary = request.get("params", {})
				headers.append("Mcp-Name: " + str(request_params.get(
					"name", request_params.get("uri", ""))))
	peer.put_data(("\r\n".join(headers) + "\r\n\r\n").to_utf8_buffer())
	peer.put_data(body)
	return peer


func _has_header(headers: PackedStringArray, wanted: String) -> bool:
	for header: String in headers:
		if header.get_slice(":", 0).to_lower() == wanted:
			return true
	return false


func _parse_response(bytes: PackedByteArray) -> Dictionary:
	var text := bytes.get_string_from_utf8()
	var boundary := text.find("\r\n\r\n")
	if boundary < 0:
		return _failed_response("invalid HTTP response", text)
	var head := text.substr(0, boundary)
	var lines := head.split("\r\n")
	var parts := lines[0].split(" ")
	var headers := {}
	for line in lines.slice(1):
		var colon := line.find(":")
		if colon > 0:
			headers[line.substr(0, colon).to_lower()] = line.substr(colon + 1).strip_edges()
	var body := text.substr(boundary + 4)
	var parsed: Variant = null
	if headers.get("content-type", "").begins_with("application/json"):
		var parser := JSON.new()
		if parser.parse(body) == OK:
			parsed = parser.data
	return {"status": int(parts[1]), "headers": headers, "body": body, "json": parsed}


func _listed_tool(tools: Array, name: String) -> Dictionary:
	for tool: Variant in tools:
		if tool is Dictionary and tool.get("name") == name:
			return tool
	return {}


func _run() -> void:
	server = load("res://Scripts/Services/MCP/MinervaMCPHttpServer.gd").new()
	root.add_child(server)
	fixture = load("res://test/helpers/mcp_public_server_fixture.gd").new()
	server._mcp_manager = fixture
	check("loopback public server starts on an isolated port", server.start_server(0) == OK)
	port = server.get_port()
	check("isolated port is published", port > 0, str(port))
	if port <= 0:
		_finish()
		return
	var idle_peers: Array[StreamPeerTCP] = []
	for index in range(64):
		var idle_peer := StreamPeerTCP.new()
		idle_peer.connect_to_host("127.0.0.1", port)
		await process_frame
		idle_peer.poll()
		idle_peers.append(idle_peer)
	var reached_ceiling := await _wait_until(func() -> bool:
		return server._connections.size() == 64)
	var rejected_peer := StreamPeerTCP.new()
	rejected_peer.connect_to_host("127.0.0.1", port)
	var rejected_65th := await _wait_until(func() -> bool:
		rejected_peer.poll()
		return rejected_peer.get_status() in [
			StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR])
	check("accepted idle connections reach their cap and reject the sixty-fifth",
		reached_ceiling and rejected_65th and server._connections.size() == 64,
		str(server._connections.size()))
	rejected_peer.disconnect_from_host()
	for idle_peer: StreamPeerTCP in idle_peers:
		idle_peer.disconnect_from_host()
	check("idle connection ownership retires after peers close",
		await _wait_until(func() -> bool: return server._connections.is_empty()))
	var output_peer := StreamPeerTCP.new()
	output_peer.connect_to_host("127.0.0.1", port)
	check("output-boundary fixture is accepted", await _wait_until(func() -> bool:
		output_peer.poll()
		return output_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED \
			and server._connections.size() == 1))
	var output_connection = server._connections[0] if not server._connections.is_empty() else null
	if output_connection != null:
		output_connection.send_response(200, {}, "x".repeat(
			output_connection.MAX_OUTPUT_BYTES + 1))
	check("connection output boundary replaces oversized queues with a bounded error",
		output_connection != null and output_connection._output_buffer.size() < 1024
		and output_connection._output_buffer.get_string_from_utf8().contains(
			"MCP response exceeds the byte budget"))
	output_peer.disconnect_from_host()
	check("output-boundary fixture retires", await _wait_until(func() -> bool:
		return server._connections.is_empty()))

	var discovery := await _http(_message("server/discover", "discover", {}, true),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var discovery_result: Dictionary = discovery.get("json", {}).get("result", {})
	check("modern discovery is complete, private and sessionless",
		discovery.status == 200 and discovery_result.resultType == "complete"
		and discovery_result.ttlMs == 0 and discovery_result.cacheScope == "private"
		and discovery_result.capabilities.tools.listChanged == false
		and not discovery.headers.has("mcp-session-id"), str(discovery))
	var max_id := 9007199254740991
	var max_id_discovery := await _http(_message("server/discover", max_id),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("maximum safe integer request ID round-trips exactly",
		max_id_discovery.json.id == max_id)
	var missing_method_body := JSON.stringify(_message("server/discover", 1)).to_utf8_buffer()
	var missing_method := await _raw_http(missing_method_body, PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]), false)
	check("modern method mirror is required before dispatch",
		missing_method.status == 400 and missing_method.json.error.code == -32020)
	var invalid_ids_ok := true
	for invalid_id: Variant in [true, 1.25, {"nested": "id"}]:
		var invalid_id_response := await _http(_message("server/discover", invalid_id),
			PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
		invalid_ids_ok = invalid_ids_ok and invalid_id_response.status == 400 \
			and invalid_id_response.json.error.code == -32600 \
			and invalid_id_response.json.id == null
	check("invalid Boolean, fractional and object IDs respond with null IDs", invalid_ids_ok)

	var missing_meta := await _http(_message("server/discover", 2, {}, false),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var wrong_version_request := _message("server/discover", 3)
	wrong_version_request.params._meta["io.modelcontextprotocol/protocolVersion"] = "2099-01-01"
	var wrong_version := await _http(wrong_version_request,
		PackedStringArray(["MCP-Protocol-Version: 2099-01-01"]))
	var mismatched_header := await _http(_message("tools/list", 4),
		PackedStringArray(["MCP-Protocol-Version: 2025-06-18"]))
	check("modern metadata errors retain their assigned protocol codes and data",
		missing_meta.json.error.code == -32602 and wrong_version.json.error.code == -32022
		and wrong_version.json.error.data.requested == "2099-01-01"
		and mismatched_header.json.error.code == -32020)

	var subscription := await _http(_message("subscriptions/listen", "sub-1", {
		"notifications": {"toolsListChanged": true}}),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION,
			"Accept: application/json, text/event-stream"]))
	var events: PackedStringArray = subscription.body.split("\n\n", false)
	var first_event: Variant = JSON.parse_string(events[0].trim_prefix("data: ")) if events.size() > 0 else null
	var second_event: Variant = JSON.parse_string(events[1].trim_prefix("data: ")) if events.size() > 1 else null
	check("subscription acknowledges empty selection then completes with typed ID",
		subscription.headers.get("content-type") == "text/event-stream" and events.size() == 2
		and first_event.params.notifications.is_empty()
		and first_event.params._meta["io.modelcontextprotocol/subscriptionId"] == "sub-1"
		and second_event.id == "sub-1" and second_event.result.resultType == "complete")

	var initialized := await _http(_message("initialize", 5, {
		"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {}}, false))
	var session: String = initialized.headers.get("mcp-session-id", "")
	var legacy_list := await _http(_message("tools/list", 6, {}, false),
		PackedStringArray(["MCP-Session-Id: " + session,
			"MCP-Protocol-Version: 2025-06-18"]))
	check("legacy initialize retains session-era catalog shape", not session.is_empty()
		and legacy_list.json.result.has("tools") and not legacy_list.json.result.has("resultType"))
	var modern_list := await _http(_message("tools/list", "catalog"), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION,
		"MCP-Session-Id: " + session]))
	var listed_tools: Array = modern_list.json.result.tools
	var listed_names: Array = listed_tools.map(func(tool): return tool.name)
	var plugin_wire: Dictionary = _listed_tool(listed_tools, "plugin_widget")
	check("public catalog is stable, host-owned and preserves plugin wire fields",
		listed_names == ["minerva_echo", "minerva_hold", "native_dot", "plugin_rich", "plugin_widget"]
		and plugin_wire.get("futureField", {}).get("kept", false)
		and plugin_wire.get("annotations", {}).get("readOnlyHint", false)
		and modern_list.json.result.ttlMs == 0
		and modern_list.json.result.cacheScope == "private")
	check("modern metadata remains authoritative when a legacy session is supplied",
		modern_list.json.result.resultType == "complete")
	var rich_modern := await _http(_message("tools/call", "rich-modern", {
		"name": "plugin_rich", "arguments": {}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var rich_legacy := await _http(_message("tools/call", "rich-legacy", {
		"name": "plugin_rich", "arguments": {"front": "legacy"}}, false))
	check("front-era stamping preserves the accepted rich backend result independently",
		rich_modern.json.result.resultType == "complete"
		and rich_modern.json.result.futureResultField.preserved
		and rich_modern.json.result.structuredContent.nullable == null
		and not rich_legacy.json.result.has("resultType")
		and rich_legacy.json.result._meta.kept)
	var native_result := {}
	native_result.native_dot_field = StringName("native-value")
	var native_adapted: Dictionary = load(
		"res://Scripts/Services/MCP/MCPNativeWireAdapter.gd").adapt(native_result)
	var unsafe_native_integer: Dictionary = load(
		"res://Scripts/Services/MCP/MCPNativeWireAdapter.gd").adapt(-9223372036854775808)
	check("native application results deliberately normalize StringName keys and values",
		native_adapted.get("ok", false)
		and native_adapted.value.get("native_dot_field") == "native-value"
		and not unsafe_native_integer.get("ok", false))
	var native_http := await _http(_message("tools/call", "native-dot", {
		"name": "native_dot", "arguments": {}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var native_http_payload: Variant = JSON.parse_string(
		native_http.get("json", {}).get("result", {}).get("content", [{}])[0].get("text", ""))
	check("real native call normalizes dot-added fields at the application wire boundary",
		native_http_payload is Dictionary
		and native_http_payload.get("native_dot_field") == "native-value")
	fixture.tool_registry["plugin_widget"].original_definition["futureField"]["revision"] = 2
	server.invalidate_tools_catalog("schema replacement")
	var changed_list := await _http(_message("tools/list", "catalog-changed"),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var changed_plugin := _listed_tool(changed_list.get("json", {}).get(
		"result", {}).get("tools", []), "plugin_widget")
	check("explicit schema invalidation atomically replaces serialized definitions",
		changed_plugin.get("futureField", {}).get("revision") == 2, str(changed_list))
	fixture.tool_registry["plugin_widget"].original_definition["name"] = "mismatched_wire_name"
	server.invalidate_tools_catalog("invalid replacement")
	var rejected_catalog := await _http(_message("tools/list", "catalog-invalid"),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	fixture.tool_registry["plugin_widget"].original_definition["name"] = "plugin_widget"
	var recovered_catalog := await _http(_message("tools/list", "catalog-recovered"),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var rejected_json: Dictionary = rejected_catalog.get("json", {})
	var recovered_json: Dictionary = recovered_catalog.get("json", {})
	var recovered_tools: Array = recovered_json.get("result", {}).get("tools", [])
	check("failed catalog rebuild is atomic and remains dirty for recovery",
		rejected_json.get("error", {}).get("code") == -32603
		and _listed_tool(recovered_tools,
			"plugin_widget").get("futureField", {}).get("revision") == 2,
		str({"rejected": rejected_catalog, "recovered": recovered_catalog}))
	fixture.minerva_server._enabled_tool_sets = ["other"]
	server.invalidate_tools_catalog("visibility")
	var filtered_list := await _http(_message("tools/list", "catalog-filtered"),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("host visibility configuration invalidates the external snapshot",
		filtered_list.json.result.tools.is_empty())
	fixture.minerva_server._enabled_tool_sets = []
	server.invalidate_tools_catalog("visibility reset")
	var encoded_widget := HeaderRules.encode(" alpha ")
	check("encoded header values reject invalid UTF-8 before decoding",
		not HeaderRules.decode("=?base64?/w==?=").get("ok", false)
		and not HeaderRules.decode("=?base64?AA==?=").get("ok", false))
	var plugin_call := await _http(_message("tools/call", "plugin-call", {
		"name": "plugin_widget", "arguments": {"token": " alpha "}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION,
		"Mcp-Param-Widget: " + encoded_widget]))
	check("eligible registered plugin name does not require a minerva prefix",
		plugin_call.status == 200 and plugin_call.json.result.resultType == "complete"
		and encoded_widget.begins_with("=?base64?"))
	var calls_before_header_reject: int = fixture.minerva_server.calls
	var mismatched_parameter := await _http(_message("tools/call", "bad-header", {
		"name": "plugin_widget", "arguments": {"token": "alpha"}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION,
		"Mcp-Param-Widget: beta"]))
	check("annotated argument mirror mismatch is rejected before mutation",
		mismatched_parameter.status == 400
		and mismatched_parameter.json.error.code == -32020
		and fixture.minerva_server.calls == calls_before_header_reject)
	var missing_empty_parameter := await _http(_message("tools/call", "missing-empty-header", {
		"name": "plugin_widget", "arguments": {"token": ""}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("an empty annotated value still requires an explicitly present header",
		missing_empty_parameter.status == 400
		and missing_empty_parameter.json.error.code == -32020
		and fixture.minerva_server.calls == calls_before_header_reject)
	var duplicate_method_body := JSON.stringify(_message("server/discover", "duplicate")).to_utf8_buffer()
	var duplicate_method := await _raw_http(duplicate_method_body, PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION,
		"Mcp-Method: server/discover", "Mcp-Method: tools/list"]), false)
	check("duplicate mirrored headers are rejected as ambiguous authority",
		duplicate_method.status == 400 and duplicate_method.json.error.code == -32020)
	var unknown_method := await _http(_message("unknown/method", "unknown"),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("unknown modern methods use the assigned HTTP and JSON-RPC errors",
		unknown_method.status == 404 and unknown_method.json.error.code == -32601)
	var calls_before_origin: int = fixture.minerva_server.calls
	var foreign_origin := await _raw_http(JSON.stringify(_message(
		"tools/call", "foreign-origin", {"name": "minerva_echo", "arguments": {
			"value": 7}})).to_utf8_buffer(), PackedStringArray([
			"Origin: https://foreign.example",
			"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var null_origin := await _raw_http(JSON.stringify(_message(
		"server/discover", "null-origin")).to_utf8_buffer(), PackedStringArray([
			"Origin: null", "MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var preflight_origin := await _raw_http(PackedByteArray(), PackedStringArray([
		"Origin: https://foreign.example"]), true, "OPTIONS /mcp HTTP/1.1")
	check("every present browser Origin is rejected before routing without CORS",
		foreign_origin.status == 403 and null_origin.status == 403
		and preflight_origin.status == 403
		and not foreign_origin.headers.has("access-control-allow-origin")
		and fixture.minerva_server.calls == calls_before_origin)

	var invalid_input := await _http(_message("tools/call", 7, {
		"name": "minerva_echo", "arguments": {"value": "not-an-integer"}}),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var calls_before_valid: int = fixture.minerva_server.calls
	var valid_call := await _http(_message("tools/call", 8, {
		"name": "minerva_echo", "arguments": {"value": 7}}),
		PackedStringArray(["MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("public input validates before mutation and valid call retains modern stamp",
		invalid_input.json.error.code == -32602 and fixture.minerva_server.calls == calls_before_valid + 1
		and valid_call.json.result.resultType == "complete")
	var external_call := await _http(_message("tools/call", 9, {
		"name": "minerva_external", "arguments": {}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("registered external dependency is not publicly callable",
		external_call.json.error.code == -32602
		and fixture.minerva_server.calls == calls_before_valid + 1)

	var held_responses: Array = []
	for index in range(16):
		_collect(_http.bind(_message("tools/call", 100 + index, {
			"name": "minerva_hold", "arguments": {}}), PackedStringArray([
			"MCP-Protocol-Version: " + Protocol.MODERN_VERSION])), held_responses)
	check("sixteen public calls enter the bounded execution set",
		await _wait_until(func() -> bool: return fixture.minerva_server.holds_started == 16),
		str(fixture.minerva_server.holds_started))
	var overloaded := await _http(_message("tools/call", 200, {
		"name": "minerva_hold", "arguments": {}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("seventeenth call is rejected before mutation with retry metadata",
		overloaded.status == 429 and overloaded.headers.has("retry-after")
		and fixture.minerva_server.holds_started == 16)
	fixture.minerva_server.release_holds = true
	check("all admitted calls settle and release their leases",
		await _wait_until(func() -> bool: return held_responses.size() == 16)
		and server._tool_admission.in_flight() == 0)
	var recovered := await _http(_message("tools/call", 201, {
		"name": "minerva_echo", "arguments": {"value": 9}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("admission recovers after terminal completion", recovered.status == 200
		and recovered.json.result.resultType == "complete")

	fixture.minerva_server.release_holds = false
	var cancelled_result: Array = []
	var expected_holds: int = fixture.minerva_server.holds_started + 1
	_collect(_http.bind(_message("tools/call", "cancel-me", {
		"name": "minerva_hold", "arguments": {}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION])), cancelled_result)
	check("cancellable call begins", await _wait_until(func() -> bool:
		return fixture.minerva_server.holds_started == expected_holds))
	# Modern HTTP cancellation belongs to the request stream. Closing this test
	# client is covered by the server's connection monitor; a separate guessed-ID
	# notification must never cancel another client's request.
	var unrelated_cancel := {"jsonrpc": "2.0", "method": "notifications/cancelled",
		"params": {"requestId": "cancel-me", "_meta": _modern_meta()}}
	var cancel_response := await _http(unrelated_cancel, PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("an unrelated HTTP cancellation notification cannot cancel another stream",
		cancel_response.status == 202 and cancelled_result.is_empty()
		and server._tool_admission.in_flight() == 1)
	fixture.minerva_server.release_holds = true
	check("owned stream completes and releases admission exactly once",
		await _wait_until(func() -> bool: return cancelled_result.size() == 1)
		and server._tool_admission.in_flight() == 0
		and server._active_request_contexts.is_empty())
	fixture.minerva_server.release_holds = false
	var deadline_expected_holds: int = fixture.minerva_server.holds_started + 1
	var deadline_body := JSON.stringify(_message("tools/call", "deadline", {
		"name": "minerva_hold", "arguments": {}})).to_utf8_buffer()
	var deadline_peer = await _open_http(deadline_body, PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("deadline fixture reaches active execution", deadline_peer != null
		and await _wait_until(func() -> bool:
			return fixture.minerva_server.holds_started == deadline_expected_holds)
		and server._active_request_contexts.size() == 1)
	var deadline_connection = server._active_request_contexts.keys()[0] \
		if not server._active_request_contexts.is_empty() else null
	if deadline_connection != null:
		deadline_connection._deadline_ms = Time.get_ticks_msec() - 1
	check("absolute deadline retires an active stream without waiting wall time",
		deadline_connection != null and await _wait_until(func() -> bool:
			return server._active_request_contexts.is_empty() \
			and server._tool_admission.in_flight() == 0 \
			and not server._connections.has(deadline_connection)))
	fixture.minerva_server.release_holds = false
	var close_expected_holds: int = fixture.minerva_server.holds_started + 2
	var closing_body := JSON.stringify(_message("tools/call", "same-id-across-streams", {
		"name": "minerva_hold", "arguments": {}})).to_utf8_buffer()
	var closing_peer_a = await _open_http(closing_body, PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	var closing_peer_b = await _open_http(closing_body, PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("same typed request ID is scoped to each HTTP stream",
		closing_peer_a != null and closing_peer_b != null
		and await _wait_until(func() -> bool:
			return fixture.minerva_server.holds_started == close_expected_holds)
		and server._tool_admission.in_flight() == 2)
	closing_peer_a.disconnect_from_host()
	closing_peer_b.disconnect_from_host()
	check("closing owned HTTP streams cancels and releases each exactly once",
		await _wait_until(func() -> bool:
			return server._tool_admission.in_flight() == 0 \
			and server._active_request_contexts.is_empty()))

	var calls_before_malformed: int = fixture.minerva_server.calls
	var duplicate_length := JSON.stringify(_message("server/discover", 300)).to_utf8_buffer()
	var malformed := await _raw_http(duplicate_length, PackedStringArray([
		"Content-Length: %d" % duplicate_length.size(),
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("ambiguous Content-Length is rejected before dispatch", malformed.status == 400)
	var malformed_utf8 := await _raw_http(PackedByteArray([0x7b, 0xff, 0x7d]))
	var nul_body := await _raw_http(PackedByteArray([0x7b, 0x00, 0x7d]))
	var oversized_header := await _raw_http(PackedByteArray(), PackedStringArray([
		"X-Oversized: " + "x".repeat(65 * 1024)]))
	check("malformed UTF-8 and oversized headers fail without tool execution",
		malformed_utf8.status == 400 and nul_body.status == 400
		and oversized_header.status == 413
		and fixture.minerva_server.calls == calls_before_malformed)

	var admission = load("res://Scripts/Services/MCP/MCPPublicToolAdmission.gd").new()
	var clock_ms := [1000]
	admission.clock = func() -> int: return clock_ms[0]
	var burst_ok := true
	for index in range(40):
		var acquired: Dictionary = admission.acquire()
		burst_ok = burst_ok and acquired.get("ok", false)
		if acquired.get("ok", false):
			acquired.lease.release()
	var rate_rejected: Dictionary = admission.acquire()
	clock_ms[0] += 50
	var rate_recovered: Dictionary = admission.acquire()
	if rate_recovered.get("ok", false):
		rate_recovered.lease.release()
	check("token bucket enforces burst and 20-per-second monotonic recovery",
		burst_ok and not rate_rejected.get("ok", false)
		and rate_rejected.get("reason") == "rate_limited"
		and rate_recovered.get("ok", false))

	var reentered := [false]
	var calls_before_reentry: int = fixture.minerva_server.calls
	var reentry_callback: Callable = func(_tool_name: String, _session_id: String) -> void:
		server.stop_server()
		reentered[0] = server.start_server(0) == OK
		port = server.get_port()
	server.tool_executed.connect(reentry_callback, CONNECT_ONE_SHOT)
	var reentry_response := await _http(_message("tools/call", "reenter-stop", {
		"name": "minerva_echo", "arguments": {"value": 11}}), PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("synchronous stop and restart cannot retain the retired connection",
		reentered[0] and server.is_running() and port > 0
		and server._connections.is_empty()
		and server._active_request_contexts.is_empty()
		and fixture.minerva_server.calls == calls_before_reentry
		and await _wait_until(func() -> bool:
			return server._tool_admission.in_flight() == 0), str(reentry_response))

	fixture.minerva_server.release_holds = false
	var stop_expected_holds: int = fixture.minerva_server.holds_started + 1
	var stopping_body := JSON.stringify(_message("tools/call", "stop-active-call", {
		"name": "minerva_hold", "arguments": {}})).to_utf8_buffer()
	var stopping_peer = await _open_http(stopping_body, PackedStringArray([
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION]))
	check("shutdown fixture reaches an admitted active call", stopping_peer != null
		and await _wait_until(func() -> bool:
			return fixture.minerva_server.holds_started == stop_expected_holds)
		and server._tool_admission.in_flight() == 1
		and server._active_request_contexts.size() == 1)
	server.stop_server()
	await process_frame
	check("server shutdown detaches and cancels active execution ownership",
		not server.is_running() and server._active_request_contexts.is_empty()
		and server._inflight_connections.is_empty()
		and await _wait_until(func() -> bool:
			return server._tool_admission.in_flight() == 0))

	_finish()


func _finish() -> void:
	if server != null:
		server.stop_server()
		server.queue_free()
	print("MCP public server: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
