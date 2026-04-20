class_name CefWebViewEditor
extends PanelContainer
## CEF-backed variant of WebViewEditor. Same public API so existing callers
## (EditorPane.add_plugin_panel_editor, Editor.gd WEBVIEW branch) work with
## either implementation interchangeably. Used for plugin panels when
## CefTexture is available; WebViewEditor (WRY) remains as fallback.

signal content_changed

var html_source: String = ""
var _last_saved_html: String = ""
var editor_id: String = ""
var plugin_panel_name: String = ""
var plugin_id: String = ""

var _cef: Control = null
var _svc: SubViewportContainer = null
var _fallback_label: Label = null
var _tmp_html_path: String = ""


func _ready() -> void:
	editor_id = str(randi() % 1000000).pad_zeros(6)
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	clip_contents = true
	_apply_editor_style()
	_build_ui()
	SingletonObject.theme_changed.connect(func(_t): _apply_editor_style())


func _exit_tree() -> void:
	if _svc != null:
		remove_child(_svc)
		_svc.queue_free()
		_svc = null
		_cef = null
	# Clean up the tmp HTML file we wrote.
	if not _tmp_html_path.is_empty():
		var abs := ProjectSettings.globalize_path(_tmp_html_path)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)


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
		_show_fallback("CefTexture not available — godot-cef extension missing")
		return


func setup() -> void:
	pass


## Sets the HTML content and reloads the CEF browser to show it.
func set_html(source: String) -> void:
	html_source = source

	# Destroy existing CefTexture (matches WRY's destroy-and-recreate pattern).
	if _cef != null:
		remove_child(_cef)
		_cef.queue_free()
		_cef = null

	if not ClassDB.class_exists("CefTexture"):
		return

	# Write bridge-injected HTML to user:// temp file. CefTexture loads URLs,
	# not inline HTML, so we materialize to disk and hand it a file:// path.
	var injected := _inject_bridge(source)
	_tmp_html_path = "user://cef_panel_%s.html" % editor_id
	var abs_path: String = ProjectSettings.globalize_path(_tmp_html_path)
	var f := FileAccess.open(_tmp_html_path, FileAccess.WRITE)
	if f == null:
		push_error("[CefWebViewEditor:%s] Failed to write tmp HTML at %s" % [editor_id, _tmp_html_path])
		return
	f.store_string(injected)
	f.close()

	var cef: Control = ClassDB.instantiate("CefTexture")
	if cef == null:
		push_error("[CefWebViewEditor:%s] ClassDB.instantiate(CefTexture) returned null" % editor_id)
		return

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

	sv.add_child(cef)
	cef.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cef.size_flags_horizontal = SIZE_EXPAND_FILL
	cef.size_flags_vertical = SIZE_EXPAND_FILL
	cef.set("expand_mode", 1)  # TextureRect.EXPAND_IGNORE_SIZE if applicable
	cef.set("custom_minimum_size", Vector2.ZERO)

	add_child(svc)

	if cef.has_signal("ipc_message"):
		cef.ipc_message.connect(_on_ipc_message)

	_cef = cef
	_svc = svc

	var file_url := "file://" + abs_path
	cef.set("url", file_url)
	content_changed.emit()


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
	var bridge_js: String = CefBridge.BRIDGE_JS
	if source.find("</head>") >= 0:
		return source.replace("</head>", bridge_js + "</head>")
	elif source.find("<body") >= 0:
		return source.replace("<body", bridge_js + "<body")
	else:
		return bridge_js + source


func _on_ipc_message(msg: String) -> void:
	print("[CefWebViewEditor:%s] IPC: %s" % [editor_id, msg.left(200)])

	var json := JSON.new()
	if json.parse(msg) != OK or not json.data is Dictionary:
		push_warning("[CefWebViewEditor:%s] Invalid IPC JSON: %s" % [editor_id, msg.left(100)])
		return

	var data: Dictionary = json.data
	var ipc_id = data.get("id", "")
	var message_type: String = str(data.get("type", ""))
	var payload: Dictionary = data.get("payload", {})

	if not plugin_panel_name.is_empty():
		_handle_plugin_ipc(ipc_id, message_type, payload)
	else:
		print("[CefWebViewEditor:%s] Non-plugin IPC type=%s" % [editor_id, message_type])


func _handle_plugin_ipc(ipc_id, message_type: String, payload: Dictionary) -> void:
	var broker = _get_webview_broker()
	if broker == null:
		_send_ipc_reply(ipc_id, {"success": false, "error_message": "Webview broker not available"})
		return

	var result: Dictionary = await broker.handle_ipc_message(plugin_panel_name, message_type, payload)
	_send_ipc_reply(ipc_id, result)


func _send_ipc_reply(ipc_id, result: Dictionary) -> void:
	if _cef == null:
		return
	var reply := result.duplicate()
	reply["id"] = ipc_id
	var reply_json := JSON.stringify(reply)
	_cef.call_deferred("eval", "window.minerva._ipcReply(%s)" % reply_json)


func _get_webview_broker():
	var singleton = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if singleton and singleton.get("plugin_webview_broker"):
		return singleton.plugin_webview_broker
	return null


## Push a plugin event to the webview JS.
func push_plugin_event(event_name: String, payload: Dictionary) -> void:
	if _cef == null:
		return
	var js := "window.minerva._dispatchPluginEvent(%s, %s)" % [
		JSON.stringify(event_name), JSON.stringify(payload)
	]
	_cef.call_deferred("eval", js)


## Push a plugin state update to the webview JS.
func push_plugin_state(state: Dictionary) -> void:
	if _cef == null:
		return
	var js := "window.minerva._dispatchPluginState(%s)" % JSON.stringify(state)
	_cef.call_deferred("eval", js)
