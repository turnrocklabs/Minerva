extends SceneTree
## Host-side document capability, generation and immutable-file boundaries.

var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _wait(predicate: Callable, timeout_ms := 3000) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()

func _run() -> void:
	var Lifetime = load("res://Scripts/UI/Controls/WebViewEditor/WebDocumentLifetime.gd")
	var first = Lifetime.create("<p>__MINERVA_DOCUMENT_CAPABILITY__</p>", 1)
	var second = Lifetime.create("<p>__MINERVA_DOCUMENT_CAPABILITY__</p>", 2)
	check("each document has an isolated directory and 256-bit capability",
		first != null and second != null and first.directory != second.directory
		and first.capability.length() == 64 and first.capability != second.capability)
	var materialized: String = FileAccess.get_file_as_string(first.file_path)
	check("materialized document receives only its host capability",
		materialized.contains(first.capability)
		and not materialized.contains("__MINERVA_DOCUMENT_CAPABILITY__")
		and first.file_url.begins_with("file:///"))
	var encoded_url: String = Lifetime._absolute_file_url(
		"C:\\Users\\Name With Space\\hash#query?\\unicodé.html")
	check("file URL encoding preserves the drive and separators but encodes path data",
		encoded_url.begins_with("file:///C:/")
		and encoded_url.contains("Name%20With%20Space")
		and encoded_url.contains("hash%23query%3F")
		and encoded_url.contains("unicod%C3%A9.html"))
	var Editor = load("res://Scripts/UI/Controls/WebViewEditor/WebViewEditor.gd")
	var editor = Editor.new()
	editor._document = first
	editor._document_generation = 1
	var acknowledgements: Array[bool] = []
	editor.bridge_probe_completed.connect(
		func(value: bool) -> void: acknowledgements.append(value))
	var valid: String = JSON.stringify({"capability": first.capability, "id": "ok",
		"type": "bridge.probe.ack", "payload": {"success": true}})
	editor._on_ipc_message(valid, 0)
	editor._on_ipc_message(valid.replace(first.capability, second.capability), 1)
	editor._on_ipc_message(valid, 1)
	check("stale generation and foreign capability cannot reach the host",
		await _wait(func() -> bool: return acknowledgements == [true]))
	var admitted: bool = true
	for index in range(128):
		admitted = admitted and editor._begin_ipc("pending-%d" % index, 1) != null
	check("host bridge admission bounds pending native requests",
		admitted and editor._begin_ipc("overflow", 1) == null)
	var Broker = load("res://Scripts/Services/Plugins/PluginWebviewBroker.gd")
	var broker = Broker.new()
	broker.register_plugin_panel("replacement", "probe-panel")
	var replaced_owner: Dictionary = await broker.handle_ipc_message(
		"probe-panel", "mcp.proxy:minerva_probe_owned", {}, null, "original")
	check("a live document cannot inherit a replacement panel owner's authority",
		replaced_owner.get("success", true) == false
		and replaced_owner.get("error_code") == "permission_denied")
	var precise: Dictionary = Lifetime.encode_json({"value": 9007199254740991})
	check("host replies use the full-precision JSON encoder",
		precise.get("ok", false)
		and precise.get("raw", "").contains("9007199254740991"))
	for entry: Dictionary in editor._pending_ipc.values():
		entry.context.cancel()
	editor._pending_ipc.clear()
	var retired_path: String = first.file_path
	var retired_view := Node.new()
	var deferred_cleanup := func() -> void:
		first.dispose_after_view_node(retired_view)
	deferred_cleanup.call_deferred()
	# The deferred callable, rather than this test, must keep both objects alive.
	deferred_cleanup = Callable()
	first = null
	retired_view = null
	await process_frame
	check("retired document cleanup retains its objects and follows native teardown",
		not FileAccess.file_exists(retired_path))
	second.dispose()
	editor._document = null
	editor.free()
	print("Web document bridge: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
