extends SceneTree
## Real loopback coverage for modern HTTP tools-list subscriptions.
## Requires the source-built JSON Schema helper and isolated user data.

const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")

var passed := 0
var failed := 0
var server
var fixture
var port := 0
var peers: Array[StreamPeerTCP] = []


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label, " ", detail)


func _modern_request(method: String, request_id: Variant,
		params: Dictionary) -> Dictionary:
	var body := {"jsonrpc": "2.0", "id": request_id, "method": method,
		"params": params.duplicate(true)}
	body.params["_meta"] = Protocol.modern_meta(Protocol.MODERN_VERSION, {})
	return body


func _open_stream(request_id: Variant, notifications: Dictionary) -> Dictionary:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", port) != OK:
		return {}
	var connected := await _wait_until(func() -> bool:
		peer.poll()
		return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	if not connected:
		return {}
	var body := JSON.stringify(_modern_request("subscriptions/listen", request_id,
		{"notifications": notifications})).to_utf8_buffer()
	var headers := PackedStringArray([
		"POST /mcp HTTP/1.1", "Host: 127.0.0.1",
		"Content-Type: application/json",
		"Accept: application/json, text/event-stream",
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION,
		"Mcp-Method: subscriptions/listen",
		"Content-Length: %d" % body.size(), "Connection: close"])
	peer.put_data(("\r\n".join(headers) + "\r\n\r\n").to_utf8_buffer())
	peer.put_data(body)
	peers.append(peer)
	return {"peer": peer, "buffer": "", "headers": "", "events": [],
		"comments": 0, "closed": false}


func _tools_list(request_id: Variant) -> Dictionary:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", port) != OK:
		return {}
	if not await _wait_until(func() -> bool:
		peer.poll()
		return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED):
		peer.disconnect_from_host()
		return {}
	var body := JSON.stringify(_modern_request("tools/list", request_id, {})) \
		.to_utf8_buffer()
	var headers := PackedStringArray([
		"POST /mcp HTTP/1.1", "Host: 127.0.0.1",
		"Content-Type: application/json",
		"Accept: application/json, text/event-stream",
		"MCP-Protocol-Version: " + Protocol.MODERN_VERSION,
		"Mcp-Method: tools/list", "Content-Length: %d" % body.size(),
		"Connection: close"])
	peer.put_data(("\r\n".join(headers) + "\r\n\r\n").to_utf8_buffer())
	peer.put_data(body)
	var response := PackedByteArray()
	var finished := await _wait_until(func() -> bool:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			var available := peer.get_available_bytes()
			if available > 0:
				var read = peer.get_data(available)
				if read[0] == OK:
					response.append_array(read[1])
		return status in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR])
	peer.disconnect_from_host()
	if not finished:
		return {}
	var raw := response.get_string_from_utf8()
	var boundary := raw.find("\r\n\r\n")
	if boundary < 0 or not raw.begins_with("HTTP/1.1 200 "):
		return {}
	var parser := JSON.new()
	if parser.parse(raw.substr(boundary + 4)) != OK or not parser.data is Dictionary:
		return {}
	return parser.data


func _list_has_tool(response: Dictionary, tool_name: String) -> bool:
	for definition: Dictionary in response.get("result", {}).get("tools", []):
		if definition.get("name") == tool_name:
			return true
	return false


func _pump_stream(stream: Dictionary) -> void:
	var peer: StreamPeerTCP = stream.peer
	peer.poll()
	var status := peer.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		stream.closed = status in [StreamPeerTCP.STATUS_NONE,
			StreamPeerTCP.STATUS_ERROR]
		return
	var available := peer.get_available_bytes()
	if available > 0:
		var read = peer.get_data(available)
		if read[0] == OK:
			stream.buffer += read[1].get_string_from_utf8()
	if stream.headers.is_empty():
		var boundary: int = stream.buffer.find("\r\n\r\n")
		if boundary >= 0:
			stream.headers = stream.buffer.substr(0, boundary)
			stream.buffer = stream.buffer.substr(boundary + 4)
	while true:
		var event_end: int = stream.buffer.find("\n\n")
		if event_end < 0:
			break
		var block: String = stream.buffer.substr(0, event_end)
		stream.buffer = stream.buffer.substr(event_end + 2)
		if block.begins_with(":"):
			stream.comments = int(stream.comments) + 1
			continue
		if block.begins_with("data: "):
			var parser := JSON.new()
			if parser.parse(block.trim_prefix("data: ")) == OK \
					and parser.data is Dictionary:
				stream.events.append(parser.data)
	status = peer.get_status()
	stream.closed = status in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR]


func _wait_events(stream: Dictionary, count: int, timeout_ms := 5000) -> bool:
	return await _wait_until(func() -> bool:
		_pump_stream(stream)
		return stream.events.size() >= count, timeout_ms)


func _wait_until(predicate: Callable, timeout_ms := 5000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()


func _wait_quiet(stream: Dictionary, duration_ms := 250) -> void:
	var deadline := Time.get_ticks_msec() + duration_ms
	while Time.get_ticks_msec() < deadline:
		_pump_stream(stream)
		await process_frame


func _connection_for(request_id: Variant):
	var wanted_key := Protocol.request_id_key(request_id)
	for conn in server._subscriptions:
		if Protocol.request_id_key(server._subscriptions[conn].id) == wanted_key:
			return conn
	return null


func _event_subscription_id(event: Dictionary) -> Variant:
	if event.has("params"):
		return event.params.get("_meta", {}).get(
			"io.modelcontextprotocol/subscriptionId")
	return event.get("result", {}).get("_meta", {}).get(
		"io.modelcontextprotocol/subscriptionId")


func _run() -> void:
	server = load("res://Scripts/Services/MCP/MinervaMCPHttpServer.gd").new()
	root.add_child(server)
	fixture = load("res://test/helpers/mcp_public_server_fixture.gd").new()
	server._mcp_manager = fixture
	check("subscription server starts", server.start_server(0) == OK)
	port = server.get_port()
	if port <= 0:
		_finish()
		return

	var alpha := await _open_stream("alpha", {"toolsListChanged": true})
	var beta := await _open_stream(7, {
		"toolsListChanged": true, "promptsListChanged": true})
	check("two subscriptions receive acknowledgments",
		not alpha.is_empty() and not beta.is_empty()
		and await _wait_events(alpha, 1) and await _wait_events(beta, 1))
	var alpha_ack: Dictionary = alpha.events[0] if alpha.events.size() else {}
	var beta_ack: Dictionary = beta.events[0] if beta.events.size() else {}
	var beta_subscription_id: Variant = _event_subscription_id(beta_ack)
	check("acknowledgment is first and retains each typed request ID",
		alpha_ack.get("method") == "notifications/subscriptions/acknowledged"
		and alpha_ack.params.notifications == {"toolsListChanged": true}
		and _event_subscription_id(alpha_ack) == "alpha"
		and beta_ack.get("method") == "notifications/subscriptions/acknowledged"
		and beta_ack.params.notifications == {"toolsListChanged": true}
		and typeof(beta_subscription_id) in [TYPE_INT, TYPE_FLOAT]
		and float(beta_subscription_id) == 7.0)
	var headers: String = alpha.headers.to_lower()
	check("persistent SSE is close-delimited and proxy-safe",
		"content-type: text/event-stream" in headers
		and "cache-control: no-cache" in headers
		and "x-accel-buffering: no" in headers
		and "content-length:" not in headers)

	# A subscriber reconciles the current catalog as its baseline; invalidating
	# without a definition change must not create a notification.
	server.invalidate_tools_catalog("no-op")
	await _wait_quiet(alpha)
	check("no-op rebuild emits no list-changed notification",
		alpha.events.size() == 1 and beta.events.size() == 1)

	fixture._add_tool("refresh_added", {"type": "object", "properties": {}})
	server.invalidate_tools_catalog("tool added")
	# Hold the notification coalescer while the ordinary request rebuilds the
	# shared catalog, then release it to prove the rebuild did not consume it.
	for state: Dictionary in server._subscriptions.values():
		state["refresh_at"] = Time.get_ticks_msec() + 5000
	var rebuilt_before_event := await _tools_list("list-before-event")
	check("ordinary tools/list rebuilds the authoritative catalog before the event",
		_list_has_tool(rebuilt_before_event, "refresh_added")
		and alpha.events.size() == 1 and beta.events.size() == 1)
	for state: Dictionary in server._subscriptions.values():
		state["refresh_at"] = Time.get_ticks_msec()
	check("both subscribers receive one correlated change",
		await _wait_events(alpha, 2) and await _wait_events(beta, 2)
		and alpha.events[1].method == "notifications/tools/list_changed"
		and _event_subscription_id(alpha.events[1]) == "alpha"
		and _event_subscription_id(beta.events[1]) == 7)
	var rebuilt_after_event := await _tools_list("list-after-event")
	check("post-notification tools/list agrees with the published catalog",
		_list_has_tool(rebuilt_after_event, "refresh_added"))

	for index in range(3):
		fixture._add_tool("coalesced_%d" % index,
			{"type": "object", "properties": {}})
		server.invalidate_tools_catalog("coalesced mutation")
	check("rapid mutations coalesce to one event per subscriber",
		await _wait_events(alpha, 3) and await _wait_events(beta, 3))
	await _wait_quiet(alpha)
	check("coalescing does not emit duplicate events",
		alpha.events.size() == 3 and beta.events.size() == 3)

	fixture.tool_registry.refresh_added.description = "changed definition"
	server.invalidate_tools_catalog("definition changed")
	check("definition changes advance the catalog revision",
		await _wait_events(alpha, 4) and await _wait_events(beta, 4))
	fixture.minerva_server._enabled_tool_sets = ["meta"]
	server.invalidate_tools_catalog("visibility changed")
	check("visibility changes notify both subscribers",
		await _wait_events(alpha, 5) and await _wait_events(beta, 5))
	fixture.minerva_server._enabled_tool_sets = []
	fixture.tool_registry.erase("refresh_added")
	server.invalidate_tools_catalog("tool removed and visibility restored")
	check("removal and restored visibility coalesce to one revision",
		await _wait_events(alpha, 6) and await _wait_events(beta, 6))

	# A malformed rebuild stays dirty and cannot publish a stale-success event.
	fixture.tool_registry[42] = fixture.tool_registry.minerva_echo
	server.invalidate_tools_catalog("invalid catalog")
	await _wait_quiet(beta)
	check("failed catalog rebuild emits no stale success", beta.events.size() == 6)
	fixture.tool_registry.erase(42)
	fixture._add_tool("recovered", {"type": "object", "properties": {}})
	server.invalidate_tools_catalog("catalog recovered")
	check("a later valid rebuild resumes notifications", await _wait_events(beta, 7))

	alpha.peer.disconnect_from_host()
	check("closing one HTTP stream cancels only its owned subscription",
		await _wait_until(func() -> bool: return server._subscriptions.size() == 1)
		and server._subscriptions.values()[0].id == 7)
	fixture._add_tool("after_disconnect", {"type": "object", "properties": {}})
	server.invalidate_tools_catalog("post-disconnect")
	check("healthy sibling continues after another stream disconnects",
		await _wait_events(beta, 8) and _event_subscription_id(beta.events[7]) == 7)

	var beta_connection = _connection_for(7)
	if beta_connection != null:
		beta_connection._deadline_ms = 0
		server._subscriptions[beta_connection].heartbeat_at = 0
	await process_frame
	_pump_stream(beta)
	check("healthy idle subscription outlives the ordinary request deadline",
		beta_connection != null and server._subscriptions.has(beta_connection))

	var admitted: Array[Dictionary] = []
	for index in range(15):
		var stream := await _open_stream("cap-%d" % index, {"toolsListChanged": true})
		if not stream.is_empty() and await _wait_events(stream, 1):
			admitted.append(stream)
	var rejected := await _open_stream("cap-rejected", {"toolsListChanged": true})
	check("subscription admission is capped within the connection ceiling",
		admitted.size() == 15 and await _wait_until(func() -> bool:
			_pump_stream(rejected)
			return rejected.closed)
		and " 429 " in rejected.headers)

	var slow_stream: Dictionary = admitted.pop_back() if not admitted.is_empty() else {}
	var slow_connection = _connection_for("cap-14")
	var overflow_rejected := false
	if slow_connection != null:
		var large_comment := "x".repeat(4096)
		while slow_connection.append_sse_comment(large_comment):
			pass
		overflow_rejected = slow_connection._output_buffer.size() \
			<= slow_connection.MAX_STREAM_OUTPUT_BYTES
		slow_connection._stream_last_progress_ms = Time.get_ticks_msec() \
			- slow_connection.STREAM_STALL_MS
		server._process_subscription(slow_connection)
	check("slow output is capped and retired on its monotonic stall deadline",
		overflow_rejected and slow_connection != null
		and not server._subscriptions.has(slow_connection))
	if not slow_stream.is_empty():
		slow_stream.peer.disconnect_from_host()

	for stream: Dictionary in admitted:
		stream.peer.disconnect_from_host()
	check("closing admitted peers returns to one healthy subscription",
		await _wait_until(func() -> bool: return server._subscriptions.size() == 1))

	server.stop_server()
	check("server stop queues typed graceful completion and permits restart",
		server.start_server(0) == OK and await _wait_events(beta, 9)
		and beta.events[8].get("id") == 7
		and beta.events[8].result.resultType == "complete"
		and _event_subscription_id(beta.events[8]) == 7)
	port = server.get_port()
	var restarted := await _open_stream("restarted", {"toolsListChanged": true})
	check("a restarted listener owns new subscriptions while old streams drain",
		not restarted.is_empty() and await _wait_events(restarted, 1)
		and _event_subscription_id(restarted.events[0]) == "restarted")

	_finish()


func _finish() -> void:
	for peer: StreamPeerTCP in peers:
		peer.disconnect_from_host()
	if server != null:
		server.stop_server()
		server.queue_free()
	print("MCP public subscriptions: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
