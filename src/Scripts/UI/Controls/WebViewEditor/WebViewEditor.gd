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
	var bridge_js: String = MinervaBridge.BRIDGE_JS
	# Insert before </head> if present, otherwise before <body, otherwise prepend
	if source.find("</head>") >= 0:
		return source.replace("</head>", bridge_js + "</head>")
	elif source.find("<body") >= 0:
		return source.replace("<body", bridge_js + "<body")
	else:
		return bridge_js + source


func _on_ipc_message(msg: String) -> void:
	# Future JS bridge handler — log for now.
	print("[WebViewEditor:%s] IPC: %s" % [editor_id, msg.left(120)])
