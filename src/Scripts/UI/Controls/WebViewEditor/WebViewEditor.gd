class_name WebViewEditor
extends PanelContainer
## Editor panel that hosts a Godot WRY WebView to render HTML content.

## Emitted when the HTML content changes (via set_html).
signal content_changed

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
	# Destroy the native WRY webview window when the editor tab is closed.
	# WRY only hides the OS window in response to Godot's visibility_changed
	# signal, which does NOT fire on tree removal — toggle visible first so
	# the native window un-draws immediately, then free the node.
	if _webview != null:
		_webview.visible = false
		remove_child(_webview)
		_webview.queue_free()
		_webview = null


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

	# Destroy existing webview
	if _webview != null:
		remove_child(_webview)
		_webview.queue_free()
		_webview = null

	if not ClassDB.class_exists("WebView"):
		return

	# Create fresh webview with html set BEFORE add_child
	var webview: Control = ClassDB.instantiate("WebView")
	if webview == null:
		return

	webview.url = ""
	webview.full_window_size = false
	webview.html = _inject_bridge(source)

	add_child(webview)
	webview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	webview.size_flags_horizontal = SIZE_EXPAND_FILL
	webview.size_flags_vertical = SIZE_EXPAND_FILL

	if webview.has_signal("ipc_message"):
		webview.ipc_message.connect(_on_ipc_message)

	_webview = webview
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
	# Insert before </head> if present, otherwise before <body, otherwise prepend
	if source.find("</head>") >= 0:
		return source.replace("</head>", bridge_js + "</head>")
	elif source.find("<body") >= 0:
		return source.replace("<body", bridge_js + "<body")
	else:
		return bridge_js + source


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
	return "<script>window.__MINERVA_PANEL = %s;</script>" % JSON.stringify(ctx)


func _on_ipc_message(msg: String) -> void:
	print("[WebViewEditor:%s] IPC: %s" % [editor_id, msg.left(200)])

	# Parse the JSON message
	var json := JSON.new()
	if json.parse(msg) != OK or not json.data is Dictionary:
		push_warning("[WebViewEditor:%s] Invalid IPC JSON: %s" % [editor_id, msg.left(100)])
		return

	var data: Dictionary = json.data
	var ipc_id = data.get("id", "")
	var message_type: String = str(data.get("type", ""))
	var payload: Dictionary = data.get("payload", {})

	# Check if this is a plugin panel
	if not plugin_panel_name.is_empty():
		_handle_plugin_ipc(ipc_id, message_type, payload)
	else:
		# Regular Minerva webview IPC — existing behavior (currently just logs)
		print("[WebViewEditor:%s] Non-plugin IPC type=%s" % [editor_id, message_type])


func _handle_plugin_ipc(ipc_id, message_type: String, payload: Dictionary) -> void:
	var broker = _get_webview_broker()
	if broker == null:
		_send_ipc_reply(ipc_id, {"success": false, "error_message": "Webview broker not available"})
		return

	var result: Dictionary = await broker.handle_ipc_message(plugin_panel_name, message_type, payload)

	# Relay result back to JS
	_send_ipc_reply(ipc_id, result)


func _send_ipc_reply(ipc_id, result: Dictionary) -> void:
	if _webview == null:
		return
	var reply := result.duplicate()
	reply["id"] = ipc_id
	var reply_json := JSON.stringify(reply)
	# Defer: the IPC handler runs inside WebView's mutable borrow (emitted from
	# Rust); calling eval() synchronously would re-bind and panic. call_deferred
	# schedules the eval for idle, after the signal emission has released.
	_webview.call_deferred("eval", "window.minerva._ipcReply(%s)" % reply_json)


func _get_webview_broker():
	var singleton = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if singleton and singleton.get("plugin_webview_broker"):
		return singleton.plugin_webview_broker
	return null


## Push a plugin event to the webview JS.
func push_plugin_event(event_name: String, payload: Dictionary) -> void:
	if _webview == null:
		return
	var js := "window.minerva._dispatchPluginEvent(%s, %s)" % [
		JSON.stringify(event_name), JSON.stringify(payload)
	]
	_webview.call_deferred("eval", js)


## Push a plugin state update to the webview JS.
func push_plugin_state(state: Dictionary) -> void:
	if _webview == null:
		return
	var js := "window.minerva._dispatchPluginState(%s)" % JSON.stringify(state)
	_webview.call_deferred("eval", js)
