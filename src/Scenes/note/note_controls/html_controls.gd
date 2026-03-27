extends VBoxContainer
class_name NoteHtmlControls

## Manager that tracks all active WebViews across HTML notes (hard cap of 3)
static var _active_webviews: Array = []
const MAX_WEBVIEWS: int = 3

var note  # Note - type annotation removed to avoid circular dependency
var _webview: Control = null
var _clip_container: Control = null
var _placeholder: Button = null

var _content_backing: String

var content: String:
	set(value):
		_content_backing = value
		if is_node_ready():
			_render_or_placeholder()
		if note:
			note.changed.emit(&"content")
	get:
		return _content_backing

var sha256: String:
	get:
		var hash_ctx := HashingContext.new()
		hash_ctx.start(HashingContext.HASH_SHA256)
		hash_ctx.update(content.to_utf8_buffer())
		return hash_ctx.finish().hex_encode()


func setup(owner_note, html_content: String):
	note = owner_note
	_content_backing = html_content


func _ready() -> void:
	clip_contents = true
	_render_or_placeholder()


func _render_or_placeholder() -> void:
	# Clean up existing children
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_webview = null
	_clip_container = null
	_placeholder = null

	if _content_backing.is_empty():
		return

	if not ClassDB.class_exists("WebView"):
		_show_placeholder("WebView addon not installed")
		return

	# Check cap — show placeholder if at limit
	if _active_webviews.size() >= MAX_WEBVIEWS:
		_show_placeholder("Click to render")
		return

	_activate_webview()


func _activate_webview() -> void:
	# Evict oldest if at cap
	while _active_webviews.size() >= MAX_WEBVIEWS:
		var oldest = _active_webviews.pop_front()
		if oldest.controls and is_instance_valid(oldest.controls):
			oldest.controls._deactivate_webview()

	# Use PanelContainer to constrain native WebView window (matches experiment pattern)
	_clip_container = PanelContainer.new()
	_clip_container.clip_contents = true
	_clip_container.size_flags_horizontal = SIZE_EXPAND_FILL
	_clip_container.size_flags_vertical = SIZE_EXPAND_FILL
	_clip_container.custom_minimum_size = Vector2(0, 350)
	# Make the panel transparent so it doesn't draw over the webview
	var empty_style := StyleBoxEmpty.new()
	_clip_container.add_theme_stylebox_override("panel", empty_style)
	add_child(_clip_container)

	var webview: Control = ClassDB.instantiate("WebView")
	if webview == null:
		_show_placeholder("Failed to create WebView")
		return

	webview.url = ""
	webview.full_window_size = false
	# Inject compact padding for note context
	var note_css := "<style>html,body{padding:8px !important;margin:0 !important}</style>"
	var html: String = _content_backing
	if html.find("</head>") >= 0:
		html = html.replace("</head>", note_css + "</head>")
	else:
		html = note_css + html
	webview.html = html

	# Add to clip container — constrains the native window size
	_clip_container.add_child(webview)
	webview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	webview.size_flags_horizontal = SIZE_EXPAND_FILL
	webview.size_flags_vertical = SIZE_EXPAND_FILL

	_webview = webview
	_active_webviews.append({"controls": self, "webview": webview})

	# Remove placeholder if it exists
	if _placeholder:
		remove_child(_placeholder)
		_placeholder.queue_free()
		_placeholder = null


func _deactivate_webview() -> void:
	if _webview:
		_clip_container.remove_child(_webview)
		_webview.queue_free()
		_webview = null
	if _clip_container:
		remove_child(_clip_container)
		_clip_container.queue_free()
		_clip_container = null
	_show_placeholder("Click to render")


func _show_placeholder(message: String) -> void:
	if _placeholder:
		return
	_placeholder = Button.new()
	_placeholder.text = message
	_placeholder.flat = true
	_placeholder.size_flags_horizontal = SIZE_EXPAND_FILL
	_placeholder.size_flags_vertical = SIZE_EXPAND_FILL
	_placeholder.custom_minimum_size = Vector2(0, 100)
	_placeholder.pressed.connect(_on_placeholder_clicked)
	add_child(_placeholder)


func _on_placeholder_clicked() -> void:
	_activate_webview()


func _exit_tree() -> void:
	# Clean up from active list
	for i in range(_active_webviews.size() - 1, -1, -1):
		if _active_webviews[i].controls == self:
			_active_webviews.remove_at(i)
