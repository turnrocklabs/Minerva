class_name CefWebViewEditor
extends PanelContainer
## CEF-backed web document editor used by plugin panels and HTML views.

signal content_changed
signal bridge_probe_completed(success: bool)

var html_source: String = ""
var _last_saved_html: String = ""
var editor_id: String = ""
var plugin_panel_name: String = ""
var plugin_id: String = ""

var _cef: Control = null
var _svc: SubViewportContainer = null
var _sv: SubViewport = null
var _fallback_label: Label = null
var _tmp_html_path: String = ""
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
	# Reapply HiDPI oversampling whenever the pane is resized (also fires when
	# the UI scale changes, since that reflows control sizes).
	resized.connect(_apply_oversampling)


func _exit_tree() -> void:
	_revoke_document()


func _revoke_document() -> void:
	_document_generation += 1
	for entry: Dictionary in _pending_ipc.values():
		entry.context.cancel()
	_pending_ipc.clear()
	if _svc != null:
		remove_child(_svc)
		_svc.queue_free()
		_svc = null
		_sv = null
		_cef = null
	if _document != null:
		_document = null
		# The locked native CEF client owns exact-file cleanup through
		# OnBeforeClose (and its lock Drop path if browser creation failed).
	_document_plugin_id = ""
	_document_panel_name = ""


func _apply_editor_style() -> void:
	var ref := CodeEdit.new()
	var src: StyleBox = ref.get_theme_stylebox("normal")
	ref.free()
	if src is StyleBoxFlat:
		var style := src.duplicate()
		style.set_content_margin_all(2)
		add_theme_stylebox_override("panel", style)
	else:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.1451, 0.1686, 0.2039, 1.0)
		style.border_color = Color(0.8, 0.8, 0.8, 1.0)
		style.set_border_width_all(1)
		style.set_corner_radius_all(5)
		style.set_content_margin_all(2)
		add_theme_stylebox_override("panel", style)


func _build_ui() -> void:
	if not ClassDB.class_exists("CefTexture"):
		_show_fallback("Web content unavailable — CEF browser extension is missing")
		return


func setup() -> void:
	pass


## Sets the HTML content and reloads the CEF browser to show it.
func set_html(source: String) -> void:
	html_source = source
	_revoke_document()

	if not ClassDB.class_exists("CefTexture"):
		return

	# Write bridge-injected HTML to user:// temp file. CefTexture loads URLs,
	# not inline HTML, so we materialize to disk and hand it a file:// path.
	var Document = load("res://Scripts/UI/Controls/WebViewEditor/WebDocumentLifetime.gd")
	_document = Document.create(_inject_bridge(source), _document_generation)
	if _document == null:
		push_error("[CefWebViewEditor:%s] Failed to materialize document" % editor_id)
		return
	_document_plugin_id = plugin_id
	_document_panel_name = plugin_panel_name

	var cef: Control = ClassDB.instantiate("CefTexture")
	if cef == null:
		push_error("[CefWebViewEditor:%s] ClassDB.instantiate(CefTexture) returned null" % editor_id)
		_document.dispose()
		_document = null
		return
	if not cef.has_method("lock_initial_document"):
		push_error("[CefWebViewEditor] Native CEF lacks document navigation lock")
		_document.dispose()
		_document = null
		cef.free()
		return
	if not cef.lock_initial_document(_document.file_url,
			ProjectSettings.globalize_path(_document.file_path)):
		push_error("[CefWebViewEditor] Native document lock rejected configuration")
		_document.dispose()
		_document = null
		cef.free()
		return
	if cef.has_signal("ipc_message"):
		cef.ipc_message.connect(_on_ipc_message.bind(_document_generation))
	cef.set("url", _document.file_url)

	# Force software OSR: Vulkan DMA-BUF accelerated path is broken on our
	# NVIDIA/mutter stack (silent black). Software is slower but correct for
	# form-style plugin panels. Tracked under DCR 019dac8d.
	if cef.has_method("set_enable_accelerated_osr"):
		cef.set("enable_accelerated_osr", false)

	# Wrap CefTexture in a SubViewport so its Node-level _input hook is scoped
	# to that subviewport's event graph. Without this, CefTexture eats every
	# InputEvent in the main viewport — killing tabs, menus, buttons globally
	# (not just inside the panel). SubViewportContainer routes events into the
	# SubViewport only when the cursor is over the container.
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	svc.size_flags_horizontal = SIZE_EXPAND_FILL
	svc.size_flags_vertical = SIZE_EXPAND_FILL
	svc.custom_minimum_size = Vector2.ZERO
	svc.mouse_filter = Control.MOUSE_FILTER_STOP

	var sv := SubViewport.new()
	sv.handle_input_locally = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = true
	svc.add_child(sv)
	_sv = sv

	sv.add_child(cef)
	cef.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cef.size_flags_horizontal = SIZE_EXPAND_FILL
	cef.size_flags_vertical = SIZE_EXPAND_FILL
	cef.set("expand_mode", 1)  # TextureRect.EXPAND_IGNORE_SIZE if applicable
	cef.set("custom_minimum_size", Vector2.ZERO)

	_cef = cef
	_svc = svc
	add_child(svc)
	_apply_oversampling()
	content_changed.emit()


## Render the CEF panel at physical pixel density so it stays crisp at any UI
## zoom / display DPI instead of being bitmap-upscaled by the SubViewportContainer.
##
## The SubViewport's render target is otherwise sized in *logical* pixels, so the
## CEF page renders at logical size and gets stretched up by the host's UI scale
## (content_scale_factor) and the display's HiDPI backing — magnified + soft.
## Enabling oversampling at the full logical->physical ratio makes the target
## physical-res; the patched godot-cef binding reads this oversampling factor and
## renders the OSR buffer + reports CEF's device scale to match, so the page lays
## out at its logical size and is sampled 1:1. The apparent size is correct even
## if the factor is imperfect (it only governs sharpness, not layout).
func _apply_oversampling() -> void:
	if _sv == null:
		return
	var oversampling := _effective_scale()
	_sv.set_use_oversampling(true)
	_sv.set_oversampling_override(oversampling)


## Logical->physical pixel ratio for this surface: the host UI zoom
## (content_scale_factor) times the display's HiDPI scale. Mirrors the per-OS
## logic in godot-cef's utils::get_display_scale_factor (screen_get_scale is
## 1.0 on Windows, so derive from DPI there).
func _effective_scale() -> float:
	var ui_scale: float = get_tree().root.content_scale_factor
	var screen: int = DisplayServer.window_get_current_screen()
	var display_scale := 1.0
	if OS.get_name() == "Windows":
		var dpi: int = DisplayServer.screen_get_dpi(screen)
		display_scale = maxf(1.0, float(dpi) / 96.0) if dpi > 0 else 1.0
	else:
		display_scale = DisplayServer.screen_get_scale(screen)
	if display_scale <= 0.0:
		display_scale = 1.0
	return maxf(1.0, ui_scale * display_scale)


func get_html() -> String:
	return html_source


func is_saved() -> bool:
	return html_source == _last_saved_html


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
	var bridge_js: String = CefBridge.BRIDGE_JS + _panel_context_js()
	return source.insert(15, bridge_js) \
		if source.left(15).to_lower() == "<!doctype html>" else bridge_js + source


## Inject `window.__MINERVA_PANEL` so a plugin html panel can learn its own
## context (plugin id, panel name, OS-absolute data_directory) at load time,
## without a host→page handshake. The page derives its db/file paths from this.
func _panel_context_js() -> String:
	if plugin_id.is_empty():
		return ""
	var data_dir: String = ""
	var sing = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if sing != null and sing.get("plugin_manager") != null:
		var def = sing.plugin_manager.get_db().get_by_id(plugin_id)
		if def != null:
			# Globalize: side-load data_directory is OS-absolute already;
			# marketplace is "user://plugins/<id>" → resolve to an OS path the
			# worker subprocess can open.
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
		push_warning("[CefWebViewEditor] Bridge value is not JSON-safe")
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
		push_warning("[CefWebViewEditor:%s] Invalid IPC JSON" % editor_id)
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
		print("[CefWebViewEditor:%s] Non-plugin IPC type=%s" % [editor_id, message_type])


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
	if _cef == null or _document == null or generation != _document_generation:
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
	_defer_eval("window.minerva._ipcReply(%s)" % reply_json, generation)


func _defer_eval(script: String, generation: int = -1) -> void:
	if generation < 0:
		generation = _document_generation
	var target = _cef
	(func() -> void:
		if target == _cef and is_instance_valid(target) \
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
		if _cef != null:
			_defer_eval("window.minerva._dispatchIPCError(%s)" % _encode_json(size_error))
		return
	if _cef == null:
		return
	var js := "window.minerva._dispatchPluginEvent.apply(null,%s)" % \
		_encode_json([event_name, payload])
	_defer_eval(js)


## Push a plugin state update to the webview JS.
func push_plugin_state(state: Dictionary) -> void:
	var size_error := PluginPayloadLimits.check(state, plugin_id)
	if not size_error.is_empty():
		push_warning("[PluginWebview] %s" % size_error.error_message)
		if _cef != null:
			_defer_eval("window.minerva._dispatchIPCError(%s)" % _encode_json(size_error))
		return
	if _cef == null:
		return
	var js := "window.minerva._dispatchPluginState(%s)" % _encode_json(state)
	_defer_eval(js)
