class_name WebViewEditor
extends PanelContainer
## Editor panel that hosts a Godot WRY WebView to render HTML content.

## Emitted when the HTML content changes (via set_html).
signal content_changed
signal bridge_probe_completed(success: bool)

## The current HTML source, stored for persistence.
var html_source: String = ""

## Snapshot of HTML at last save — used for dirty tracking.
var _last_saved_html: String = ""

## Unique ID for this editor instance.
var editor_id: String = ""

## Plugin panel name (set when opening a plugin panel). Empty = regular webview.
var plugin_panel_name: String = ""

## Plugin ID this panel belongs to (set when opening a plugin panel).
var plugin_id: String = ""

## Internal reference to the WebView node (null if addon missing).
var _webview: Control = null

## Fallback label shown when the WebView addon is not installed.
var _fallback_label: Label = null
var _document = null
var _document_generation := 0
var _document_plugin_id := ""
var _document_panel_name := ""
var _pending_ipc: Dictionary = {}


func _ready() -> void:
	editor_id = str(randi() % 1000000).pad_zeros(6)
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	clip_contents = true
	_apply_editor_style()
	_build_ui()
	SingletonObject.theme_changed.connect(func(_t): _apply_editor_style())
	# Refocus the native webview when this panel becomes visible (e.g. user
	# switches back to this tab). Without this, text inputs don't show a
	# cursor until the user clicks a second time.
	visibility_changed.connect(_refocus_webview_if_visible)


func _refocus_webview_if_visible() -> void:
	if is_visible_in_tree() and _webview != null and _webview.has_method("focus"):
		_webview.call_deferred("focus")


func _exit_tree() -> void:
	_revoke_document()


func _revoke_document() -> void:
	_document_generation += 1
	for entry: Dictionary in _pending_ipc.values():
		entry.context.cancel()
	_pending_ipc.clear()
	# Destroy the native WRY webview window when the editor tab is closed.
	# WRY only hides the OS window in response to Godot's visibility_changed
	# signal, which does NOT fire on tree removal — toggle visible first so
	# the native window un-draws immediately. The deferred cleanup owns both
	# retired objects independently of this editor, destroys the native view,
	# then removes the immutable backing file in that exact order.
	var retired_view: Control = _webview
	var retired_document = _document
	_webview = null
	_document = null
	if retired_view != null:
		retired_view.visible = false
		remove_child(retired_view)
	if retired_document != null:
		(func() -> void:
			retired_document.dispose_after_view_node(retired_view)
		).call_deferred()
	elif retired_view != null:
		retired_view.call_deferred("free")
	_document_plugin_id = ""
	_document_panel_name = ""


func _apply_editor_style() -> void:
	# Read the CodeEdit's actual themed normal style so we match exactly
	var ref := CodeEdit.new()
	var src: StyleBox = ref.get_theme_stylebox("normal")
	ref.free()
	if src is StyleBoxFlat:
		var style := src.duplicate()
		style.set_content_margin_all(2)
		add_theme_stylebox_override("panel", style)
	else:
		# Fallback if theme isn't StyleBoxFlat
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.1451, 0.1686, 0.2039, 1.0)
		style.border_color = Color(0.8, 0.8, 0.8, 1.0)
		style.set_border_width_all(1)
		style.set_corner_radius_all(5)
		style.set_content_margin_all(2)
		add_theme_stylebox_override("panel", style)


func _build_ui() -> void:
	if not ClassDB.class_exists("WebView"):
		_show_fallback("WebView addon not installed")
		return
	# WebView will be created on first set_html() call.


## Called after _ready; placeholder for initial configuration.
func setup() -> void:
	pass


## Sets the HTML content displayed in the WebView.
## WRY requires destroying and recreating the WebView to reliably switch content.
func set_html(source: String) -> void:
	html_source = source
	_revoke_document()

	if not ClassDB.class_exists("WebView"):
		return

	# Create fresh webview with html set BEFORE add_child
	var webview: Control = ClassDB.instantiate("WebView")
	if webview == null:
		return

	var Document = load("res://Scripts/UI/Controls/WebViewEditor/WebDocumentLifetime.gd")
	var bridge_source := _inject_bridge(source)
	_document = Document.create(bridge_source, _document_generation)
	if _document == null:
		push_error("[WebViewEditor] Could not materialize privileged document")
		webview.free()
		return
	_document_plugin_id = plugin_id
	_document_panel_name = plugin_panel_name
	webview.url = _document.file_url
	webview.full_window_size = false
	webview.html = ""
	if not webview.has_method("lock_initial_document"):
		push_error("[WebViewEditor] Native WebView lacks document navigation lock")
		_document.dispose()
		_document = null
		webview.free()
		return
	if not webview.lock_initial_document(_document.file_url):
		push_error("[WebViewEditor] Native document lock rejected configuration")
		_document.dispose()
		_document = null
		webview.free()
		return
	if webview.has_signal("ipc_message"):
		webview.ipc_message.connect(_on_ipc_message.bind(_document_generation))

	_webview = webview
	add_child(webview)
	webview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	webview.size_flags_horizontal = SIZE_EXPAND_FILL
	webview.size_flags_vertical = SIZE_EXPAND_FILL

	print("[WebViewEditor focus-probe] class=", webview.get_class(),
		" has_method(focus)=", webview.has_method("focus"),
		" methods=", webview.get_method_list().map(func(m): return m.name).filter(func(n): return "focus" in String(n).to_lower()))
	if webview.has_method("focus"):
		webview.call_deferred("focus")
	content_changed.emit()


## Returns the current HTML source.
func get_html() -> String:
	return html_source


## Returns true when the current HTML matches the last-saved snapshot.
func is_saved() -> bool:
	return html_source == _last_saved_html


## Updates the last-saved snapshot to the current HTML (call after writing to disc).
func mark_saved() -> void:
	_last_saved_html = html_source


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _show_fallback(message: String) -> void:
	_fallback_label = Label.new()
	_fallback_label.text = message
	_fallback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fallback_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fallback_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fallback_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_fallback_label.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_fallback_label)


func _inject_bridge(source: String) -> String:
	var bridge_js: String = MinervaBridge.BRIDGE_JS + _panel_context_js()
	# Preserve only the simple HTML doctype; quoted legacy doctypes can contain
	# `>` and must never move the authority bootstrap into page-authored text.
	return source.insert(15, bridge_js) \
		if source.left(15).to_lower() == "<!doctype html>" else bridge_js + source


## Inject `window.__MINERVA_PANEL` so a plugin html panel can learn its own
## context (plugin id, panel name, OS-absolute data_directory) at load time.
func _panel_context_js() -> String:
	if plugin_id.is_empty():
		return ""
	var data_dir: String = ""
	var sing = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if sing != null and sing.get("plugin_manager") != null:
		var def = sing.plugin_manager.get_db().get_by_id(plugin_id)
		if def != null:
			data_dir = ProjectSettings.globalize_path(def.data_directory)
	var ctx := {
		"plugin_id": plugin_id,
		"panel_name": plugin_panel_name,
		"data_directory": data_dir,
	}
	return "<script>window.__MINERVA_PANEL = %s;</script>" % _encode_json(ctx)


func _encode_json(value: Variant) -> String:
	var encoded: Dictionary = load(
		"res://Scripts/UI/Controls/WebViewEditor/WebDocumentLifetime.gd").encode_json(value)
	if not encoded.get("ok", false):
		push_warning("[WebViewEditor] Bridge value is not JSON-safe")
		return ""
	return encoded.raw


func _on_ipc_message(msg: String, generation: int) -> void:
	if _document == null or generation != _document_generation \
			or msg.to_utf8_buffer().size() > PluginPayloadLimits.CONTROL_BYTES:
		return
	_validate_and_dispatch_ipc(msg, generation)


func _validate_and_dispatch_ipc(msg: String, generation: int) -> void:
	var captured_document = _document

	var json := JSON.new()
	if json.parse(msg) != OK or not json.data is Dictionary:
		push_warning("[WebViewEditor:%s] Invalid IPC JSON" % editor_id)
		return
	var wire = load("res://Scripts/Services/MCP/MCPWireValue.gd").create(msg, json.data)
	var validation: Dictionary = await load(
		"res://Scripts/Services/MCP/MCPWireAdapter.gd").validate_for_application(wire)
	if not validation.get("ok", false) or captured_document != _document \
			or generation != _document_generation:
		return
	var data: Dictionary = wire.parsed
	if data.get("capability") != _document.capability:
		return
	var ipc_id = data.get("id", "")
	var message_value: Variant = data.get("type")
	var payload_value: Variant = data.get("payload", {})
	if not message_value is String or not payload_value is Dictionary:
		return
	var message_type: String = message_value
	var payload: Dictionary = payload_value
	if message_type == "bridge.probe.ack":
		bridge_probe_completed.emit(payload.get("success", false))
		return
	var route_error := PluginPayloadLimits.check({"id": ipc_id, "type": message_type}, plugin_id, PluginPayloadLimits.ROUTING_BYTES)
	if not route_error.is_empty():
		_send_ipc_reply(ipc_id, route_error)
		return


	# Check if this is a plugin panel
	if message_type == "minerva.call" or not _document_panel_name.is_empty():
		if _pending_ipc.has(ipc_id):
			return
		var context = _begin_ipc(ipc_id, generation)
		if context == null:
			_send_ipc_reply(ipc_id, {"success": false,
				"error_message": "Bridge request admission rejected"}, generation)
			return
		if message_type == "minerva.call":
			_handle_minerva_call(ipc_id, payload, generation, context)
		else:
			_handle_plugin_ipc(ipc_id, message_type, payload, generation, context)
	else:
		# Regular Minerva webview IPC — existing behavior (currently just logs)
		print("[WebViewEditor:%s] Non-plugin IPC type=%s" % [editor_id, message_type])


func _begin_ipc(ipc_id, generation: int):
	if not ipc_id is String or ipc_id.is_empty() or _pending_ipc.has(ipc_id) \
			or _pending_ipc.size() >= 128:
		return null
	var context = load("res://Scripts/Services/MCP/MCPExecutionContext.gd").create(
		"webview", "", "", 15.0)
	_pending_ipc[ipc_id] = {"generation": generation, "context": context}
	return context


func _handle_plugin_ipc(ipc_id, message_type: String, payload: Dictionary,
		generation: int, context) -> void:
	var broker = _get_webview_broker()
	if broker == null:
		_send_ipc_reply(ipc_id, {"success": false, "error_message": "Webview broker not available"})
		return

	var result: Dictionary = await broker.handle_ipc_message(
		_document_panel_name, message_type, payload, context, _document_plugin_id)

	# Relay result back to JS
	_send_ipc_reply(ipc_id, result, generation)


func _handle_minerva_call(ipc_id, payload: Dictionary, generation: int, context) -> void:
	var tool: Variant = payload.get("tool")
	var arguments: Variant = payload.get("arguments", {})
	if not tool is String or tool.is_empty() or not arguments is Dictionary:
		_send_ipc_reply(ipc_id, {"success": false, "error_message": "Invalid tool call"}, generation)
		return
	if not _document_panel_name.is_empty():
		_handle_plugin_ipc(ipc_id, "mcp.proxy:" + tool, arguments, generation, context)
		return
	var singleton = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if singleton == null or singleton.get_mcp_manager().minerva_server == null:
		_send_ipc_reply(ipc_id, {"success": false, "error_message": "MCP unavailable"}, generation)
		return
	var result: Dictionary = await singleton.get_mcp_manager().minerva_server.execute_tool(
		tool, arguments, "", context)
	var adapted: Dictionary = load(
		"res://Scripts/Services/MCP/MCPNativeWireAdapter.gd").adapt(result)
	if not adapted.get("ok", false):
		_send_ipc_reply(ipc_id, {"success": false,
			"error_message": adapted.get("error", "Tool result is not bridge-safe")}, generation)
		return
	result = adapted.value
	var succeeded: bool = result.get("success", result.get("allowed",
		not (result.has("error") or result.has("error_code")
		or not str(result.get("error_message", "")).is_empty()))) == true
	_send_ipc_reply(ipc_id, {"success": succeeded, "result": result,
		"error_message": result.get("error_message", result.get("error", ""))}, generation)


func _send_ipc_reply(ipc_id, result: Dictionary, generation: int = -1) -> void:
	if generation < 0:
		generation = _document_generation
	var pending: Dictionary = _pending_ipc.get(ipc_id, {})
	if pending.get("generation") == generation:
		_pending_ipc.erase(ipc_id)
	if _webview == null or _document == null or generation != _document_generation:
		return
	var adapted: Dictionary = load(
		"res://Scripts/Services/MCP/MCPNativeWireAdapter.gd").adapt(result)
	if not adapted.get("ok", false):
		adapted = {"ok": true, "value": {"success": false,
			"error_message": adapted.get("error", "Bridge result is not JSON-safe")}}
	var reply := PluginPayloadLimits.bound_reply(adapted.value, plugin_id).duplicate()
	# Correlation/framing has its own small budget, outside the result dictionary.
	var routing := {"id": ipc_id}
	var route_error := PluginPayloadLimits.check(routing, "", PluginPayloadLimits.ROUTING_BYTES)
	if not route_error.is_empty():
		_defer_eval("window.minerva._dispatchIPCError(%s)" % _encode_json(route_error), generation)
		return
	reply["id"] = ipc_id
	var reply_json := _encode_json(reply)
	if reply_json.is_empty():
		return
	# Defer: the IPC handler runs inside WebView's mutable borrow (emitted from
	# Rust); calling eval() synchronously would re-bind and panic. call_deferred
	# schedules the eval for idle, after the signal emission has released.
	_defer_eval("window.minerva._ipcReply(%s)" % reply_json, generation)


func _defer_eval(script: String, generation: int = -1) -> void:
	if generation < 0:
		generation = _document_generation
	var target = _webview
	(func() -> void:
		if target == _webview and is_instance_valid(target) \
				and _document != null and generation == _document_generation:
			target.eval(script)
	).call_deferred()


func _get_webview_broker():
	var singleton = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if singleton and singleton.get("plugin_webview_broker"):
		return singleton.plugin_webview_broker
	return null


## Push a plugin event to the webview JS.
func push_plugin_event(event_name: String, payload: Dictionary) -> void:
	var size_error := PluginPayloadLimits.check({"event_name": event_name}, plugin_id, PluginPayloadLimits.ROUTING_BYTES)
	if size_error.is_empty():
		size_error = PluginPayloadLimits.check(payload, plugin_id)
	if not size_error.is_empty():
		push_warning("[PluginWebview] %s" % size_error.error_message)
		if _webview != null:
			_defer_eval("window.minerva._dispatchIPCError(%s)" % _encode_json(size_error))
		return
	if _webview == null:
		return
	var js := "window.minerva._dispatchPluginEvent.apply(null,%s)" % \
		_encode_json([event_name, payload])
	_defer_eval(js)


## Push a plugin state update to the webview JS.
func push_plugin_state(state: Dictionary) -> void:
	var size_error := PluginPayloadLimits.check(state, plugin_id)
	if not size_error.is_empty():
		push_warning("[PluginWebview] %s" % size_error.error_message)
		if _webview != null:
			_defer_eval("window.minerva._dispatchIPCError(%s)" % _encode_json(size_error))
		return
	if _webview == null:
		return
	var js := "window.minerva._dispatchPluginState(%s)" % _encode_json(state)
	_defer_eval(js)
