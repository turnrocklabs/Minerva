extends SceneTree
## Real HTTP and STDIO catalog-watch coverage with isolated local peers.

const FIXTURE := "res://test/fixtures/mcp_catalog_watch_peer.py"
const Decoder = preload("res://Scripts/Services/MCP/MCPSseDecoder.gd")
const Watch = preload("res://Scripts/Services/MCP/MCPToolCatalogWatch.gd")
const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const Wire = preload("res://Scripts/Services/MCP/MCPWireValue.gd")
const Profile = preload("res://Scripts/Services/MCP/MCPProfile.gd")
const HttpTransport = preload("res://Scripts/Services/MCP/MCPHttpTransport.gd")

var passed := 0
var failed := 0
var processes: Array = []


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label, " ", detail)


func _wait_until(predicate: Callable, timeout_ms := 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()


func _has_generation(connection, generation: int) -> bool:
	if connection.tools.size() != 4:
		return false
	var watched := 0
	for tool in connection.tools:
		if str(tool.name).begins_with("watch_%d_" % generation):
			watched += 1
	return watched == 3


func _tool_schema_generation(connection, tool_name: String) -> Variant:
	for tool in connection.tools:
		if tool.name == tool_name:
			return tool.to_mcp_format().get("inputSchema", {}).get(
				"properties", {}).get("generation", {}).get("enum", [])
	return null


func _has_schema_generation(connection, tool_name: String,
		expected_generation: int) -> bool:
	var values: Variant = _tool_schema_generation(connection, tool_name)
	if not values is Array or values.size() != 1:
		return false
	var value: Variant = values[0]
	return (value is int or value is float) \
		and is_finite(float(value)) and float(value) == float(expected_generation)


func _run() -> void:
	await _test_watch_state()
	_test_capability_gate()
	await _test_http_watch()
	await _test_stdio_watch()
	_test_long_lived_decoder()
	for process in processes:
		if process != null:
			process.stop()
	print("MCP catalog watch: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_watch_state() -> void:
	var watch = Watch.new()
	var refreshes: Array[int] = []
	watch.refresh_requested.connect(func(owner: int) -> void: refreshes.append(owner))
	watch.begin(4, 7)
	watch.accepts({"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
		"params": {"_meta": {"io.modelcontextprotocol/subscriptionId": 7}}}, 4)
	watch.accepts({"jsonrpc": "2.0",
		"method": "notifications/subscriptions/acknowledged",
		"params": {"_meta": {"io.modelcontextprotocol/subscriptionId": "7"},
			"notifications": {"toolsListChanged": true}}}, 4)
	check("pre-ack event and wrong typed acknowledgment are ignored",
		watch.waiting_ack and refreshes.is_empty())
	watch.accepts({"jsonrpc": "2.0",
		"method": "notifications/subscriptions/acknowledged",
		"params": {"_meta": {"io.modelcontextprotocol/subscriptionId": 7},
			"notifications": {"toolsListChanged": true,
				"promptsListChanged": false}}}, 4)
	check("mixed acknowledgment is declined", not watch.active
		and refreshes.is_empty())
	watch.begin(5, 7)
	watch.accepts({"jsonrpc": "2.0",
		"method": "notifications/subscriptions/acknowledged",
		"params": {"_meta": {"io.modelcontextprotocol/subscriptionId": 7},
			"notifications": {"toolsListChanged": true}}}, 5)
	check("exact typed acknowledgment activates and requests catch-up",
		watch.active and refreshes == [5])
	watch.begin(5, "declined")
	watch.accepts({"jsonrpc": "2.0",
		"method": "notifications/subscriptions/acknowledged",
		"params": {"_meta": {
			"io.modelcontextprotocol/subscriptionId": "declined"},
			"notifications": {}}}, 5)
	check("declined filter stops the watch generation", not watch.active
		and not watch.waiting_ack)
	watch.begin(6, "shape")
	check("malformed metadata and id-bearing notifications cannot acknowledge",
		not watch.accepts({"jsonrpc": "2.0",
			"method": "notifications/subscriptions/acknowledged",
			"params": {"_meta": "bad", "notifications": {
				"toolsListChanged": true}}}, 6)
		and not watch.accepts({"jsonrpc": "2.0", "id": "shape",
			"method": "notifications/subscriptions/acknowledged",
			"params": {"_meta": {
				"io.modelcontextprotocol/subscriptionId": "shape"},
				"notifications": {"toolsListChanged": true}}}, 6)
		and watch.waiting_ack)
	watch.ack_deadline_ms = 1
	check("acknowledgment deadline is monotonic and bounded", watch.ack_expired(2))
	for index in range(4):
		watch.begin(6, "retry-%d" % index)
		watch.stop(true)
	check("same-owner retries exhaust their capped backoff",
		watch.retry_delay_ms() < 0)
	watch.reset(7)
	watch.begin(7, "fresh-owner")
	check("new owner resets retry history", watch.retry_delay_ms() > 0)
	watch.begin(7, "new-attempt")
	check("old-attempt continuation cannot stop the new typed request",
		not watch.accepts({"jsonrpc": "2.0", "id": "fresh-owner",
			"result": {"resultType": "complete"}}, 7)
		and watch.waiting_ack)
	check("completion requires complete result and exact typed subscription metadata",
		not Watch.is_valid_completion({"jsonrpc": "2.0", "id": 7,
			"result": {"resultType": "complete"}}, 7)
		and not Watch.is_valid_completion({"jsonrpc": "2.0", "id": 7,
			"result": {"resultType": "complete", "_meta": {
				"io.modelcontextprotocol/subscriptionId": "7"}}}, 7)
		and Watch.is_valid_completion({"jsonrpc": "2.0", "id": 7,
			"result": {"resultType": "complete", "_meta": {
				"io.modelcontextprotocol/subscriptionId": 7}}}, 7))
	var Connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var connection = Connection.new("watch-classifier", "")
	connection._catalog_watch.request_id = 7
	var complete_raw := '{"jsonrpc":"2.0","id":7,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":7}}}'
	check("HTTP refusal cannot retry through a complete-looking body",
		not connection._http_catalog_watch_should_retry({"error": "HTTP error: 503",
			"status": 503, "wire": Wire.create(complete_raw, JSON.parse_string(complete_raw))})
		and connection._http_catalog_watch_should_retry({"error": "stream closed",
			"subscription_retryable": true}))


func _test_capability_gate() -> void:
	var transport = HttpTransport.new()
	transport.profile = Profile.modern({"tools": {}}, 1)
	check("modern peer without listChanged capability starts no watch",
		not transport.start_tools_watch("missing-cap"))
	transport.profile = Profile.legacy("2025-06-18",
		{"tools": {"listChanged": true}}, 1)
	check("legacy peer never starts modern catalog watch",
		not transport.start_tools_watch("legacy"))


func _python() -> String:
	var python := OS.get_environment("PYTHON")
	return python if not python.is_empty() else "python3"


func _start_http_peer() -> String:
	var process = ClassDB.instantiate("SubProcess")
	root.add_child(process)
	processes.append(process)
	if not process.start(_python(), PackedStringArray([
		"-u", ProjectSettings.globalize_path(FIXTURE), "--transport", "http"])):
		return ""
	var endpoint := {"base": ""}
	await _wait_until(func() -> bool:
		while process.has_output():
			var value: Variant = JSON.parse_string(process.read_line())
			if value is Dictionary and value.has("port"):
				endpoint.base = "http://127.0.0.1:%d" % int(value.port)
		return not str(endpoint.base).is_empty())
	return str(endpoint.base)


func _test_http_watch() -> void:
	var base := await _start_http_peer()
	check("HTTP catalog peer starts", not base.is_empty())
	if base.is_empty():
		return
	var Connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var connection = Connection.new("watch-http", base)
	check("HTTP modern connection negotiates", await connection.connect_to_server() == OK)
	check("HTTP initial paginated catalog commits atomically",
		await connection.refresh_tools() == OK and _has_generation(connection, 0)
		and _has_schema_generation(connection, "large_numeric", 0))
	var commits := {"count": 0}
	connection.catalog_committed.connect(func() -> void: commits.count += 1)
	connection.start_tool_catalog_watch()
	var first_watch = connection._http_transport._watch_request
	check("HTTP acknowledgment catch-up and burst publish latest catalog",
		await _wait_until(func() -> bool: return _has_generation(connection, 2))
		and commits.count <= 2, str(commits))
	check("transient HTTP stream closure resubscribes and catches up",
		await _wait_until(func() -> bool: return _has_generation(connection, 4), 7000)
		and connection._http_transport._watch_request != first_watch
		and connection._catalog_watch.active
		and _has_schema_generation(connection, "large_numeric", 4))
	var fresh: Dictionary = await connection.call_tool("watch_4_0", {})
	check("HTTP refreshed catalog invokes the newly advertised tool",
		fresh.get("generation") == 4 and fresh.get("tool") == "watch_4_0")
	var watch_request = connection._http_transport._watch_request
	connection.cancel_active_requests()
	check("ordinary HTTP cancellation leaves dedicated watch owned",
		connection._http_transport._watch_request == watch_request
		and connection._catalog_watch.active)
	var large: Dictionary = await connection.call_tool("large_numeric", {})
	check("HTTP watch coexists with a valid large numerically exact result",
		large.get("padding", []).size() == 20000
		and large.get("precise") == 0.12345678901234566)
	connection.disconnect_from_server()
	check("HTTP disconnect retires catalog watch", not connection._catalog_watch.active)


func _test_stdio_watch() -> void:
	var Connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var connection = Connection.new("watch-stdio", "", Connection.TransportType.STDIO)
	connection.configure_stdio(_python(), PackedStringArray([
		"-u", ProjectSettings.globalize_path(FIXTURE), "--transport", "stdio"]))
	check("STDIO modern connection negotiates", await connection.connect_to_server() == OK)
	check("STDIO initial paginated catalog commits atomically",
		await connection.refresh_tools() == OK and _has_generation(connection, 0)
		and _has_schema_generation(connection, "large_numeric", 0))
	var commits := {"count": 0}
	var committed_generations: Array[int] = []
	connection.catalog_committed.connect(func() -> void:
		commits.count += 1
		for generation in range(5):
			if _has_generation(connection, generation):
				committed_generations.append(generation)
				break)
	connection.start_tool_catalog_watch()
	var first_watch_id: Variant = connection._catalog_watch.request_id
	check("STDIO validated watch queue coalesces burst to latest catalog",
		await _wait_until(func() -> bool: return 2 in committed_generations)
		and not connection._pending.has(Protocol.request_id_key(first_watch_id))
		and not connection._pending.has(Protocol.request_id_key(
			connection._catalog_watch.request_id))
		and committed_generations.slice(0, 2) == [1, 2],
		str({"count": commits.count, "generations": committed_generations}))
	var large: Dictionary = await connection.call_tool("large_numeric", {})
	check("STDIO watch coexists with a valid large numerically exact result",
		large.get("padding", []).size() == 20000
		and large.get("precise") == 0.12345678901234566)
	var resubscribed := func() -> bool:
		return Protocol.request_id_key(connection._catalog_watch.request_id) \
			!= Protocol.request_id_key(first_watch_id) \
			and _has_generation(connection, 4)
	check("clean STDIO completion resubscribes with a new typed ID and catch-up",
		await _wait_until(resubscribed, 7000)
		and _has_schema_generation(connection, "large_numeric", 4))
	var fresh: Dictionary = await connection.call_tool("watch_4_0", {})
	check("STDIO refreshed catalog invokes the newly advertised tool",
		fresh.get("generation") == 4 and fresh.get("tool") == "watch_4_0")
	var watch_id: Variant = connection._catalog_watch.request_id
	connection.disconnect_from_server()
	check("STDIO disconnect cancels exact watch outside request waiters",
		not connection._catalog_watch.active
		and not connection._pending.has(Protocol.request_id_key(watch_id)))


func _test_long_lived_decoder() -> void:
	var event := "data: {\"ok\":true}\n\n".to_utf8_buffer()
	var decoder = Decoder.new(true)
	var count := 0
	for _index in range(4100):
		count += decoder.feed(event).size()
	check("long-lived SSE decoder has per-event rather than lifetime bounds",
		decoder.error.is_empty() and count == 4100)
	var finite = Decoder.new()
	for _index in range(4097):
		finite.feed(event)
	check("finite response decoder retains existing lifetime event bound",
		not finite.error.is_empty())
