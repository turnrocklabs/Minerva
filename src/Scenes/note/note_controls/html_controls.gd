extends VBoxContainer
class_name NoteHtmlControls

## Manager that tracks all active WebViews across HTML notes (hard cap of 3)
static var _active_webviews: Array = []
const MAX_WEBVIEWS: int = 3

var note  # Note - type annotation removed to avoid circular dependency
var _webview: Control = null
var _clip_container: Control = null
var _subviewport: SubViewport = null
var _document: WebDocumentLifetime = null
var _placeholder: Button = null
var _loaded_url: String = ""
var _load_error: String = ""

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
	_remove_active_entry()
	_deactivate_webview(false)
	# Clean up existing children
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_webview = null
	_clip_container = null
	_placeholder = null

	if _content_backing.is_empty():
		return

	if not ClassDB.class_exists("CefTexture"):
		_show_placeholder("Web content unavailable — CEF browser extension is missing")
		return

	# Check cap — show placeholder if at limit
	if _active_webviews.size() >= MAX_WEBVIEWS:
		_show_placeholder("Click to render")
		return

	_activate_webview()


func _activate_webview() -> void:
	if not ClassDB.class_exists("CefTexture"):
		_show_placeholder("Web content unavailable — CEF browser extension is missing")
		return
	# Evict oldest if at cap
	while _active_webviews.size() >= MAX_WEBVIEWS:
		var oldest = _active_webviews.pop_front()
		if oldest.controls and is_instance_valid(oldest.controls):
			oldest.controls._deactivate_webview()

	# HTML notes intentionally receive no Minerva bridge or plugin authority.
	# The native exact-document lock blocks top-level link replacement.
	var note_css := "<style>html,body{padding:8px !important;margin:0 !important}</style>"
	var raw_html: String = _content_backing
	if raw_html.find("</head>") >= 0:
		raw_html = raw_html.replace("</head>", note_css + "</head>")
	else:
		raw_html = note_css + raw_html
	_document = WebDocumentLifetime.create_unprivileged(raw_html, 0)
	if _document == null:
		_show_placeholder("Failed to prepare web content")
		return
	var webview: Control = ClassDB.instantiate("CefTexture")
	if webview == null or not webview.has_method("lock_initial_document") \
			or not webview.lock_initial_document(_document.file_url,
				ProjectSettings.globalize_path(_document.file_path)):
		if webview != null:
			webview.free()
		_document.dispose()
		_document = null
		_show_placeholder("Failed to create CEF web content")
		return
	webview.set("url", _document.file_url)
	var loaded_document = _document
	if webview.has_signal("load_finished"):
		webview.load_finished.connect(func(url: String, _status: int) -> void:
			if _webview == webview and _document == loaded_document:
				_loaded_url = url
		)
	if webview.has_signal("load_error"):
		webview.load_error.connect(func(_url: String, code: int, message: String) -> void:
			if _webview == webview and _document == loaded_document:
				_load_error = "%d: %s" % [code, message]
		)
	if webview.has_method("set_enable_accelerated_osr"):
		webview.set("enable_accelerated_osr", false)

	_clip_container = SubViewportContainer.new()
	_clip_container.clip_contents = true
	_clip_container.stretch = true
	_clip_container.size_flags_horizontal = SIZE_EXPAND_FILL
	_clip_container.size_flags_vertical = SIZE_EXPAND_FILL
	_clip_container.custom_minimum_size = Vector2(0, 350)
	_subviewport = SubViewport.new()
	_subviewport.handle_input_locally = true
	_subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_subviewport.transparent_bg = true
	_clip_container.add_child(_subviewport)
	_subviewport.add_child(webview)
	webview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	webview.size_flags_horizontal = SIZE_EXPAND_FILL
	webview.size_flags_vertical = SIZE_EXPAND_FILL
	_webview = webview
	add_child(_clip_container)

	_active_webviews.append({"controls": self, "webview": webview})

	# Remove placeholder if it exists
	if _placeholder:
		remove_child(_placeholder)
		_placeholder.queue_free()
		_placeholder = null


func _deactivate_webview(show_placeholder := true) -> void:
	var retired_container := _clip_container
	_loaded_url = ""
	_load_error = ""
	if retired_container:
		if retired_container.get_parent() == self:
			remove_child(retired_container)
		_retire_webview.call_deferred(retired_container)
		_clip_container = null
		_subviewport = null
		_webview = null
	_document = null
	if show_placeholder:
		_show_placeholder("Click to render")


static func _retire_webview(container: Control) -> void:
	# Freed a frame later so a teardown started from inside a tree exit never
	# frees a node the engine is still notifying. The backing file and its
	# directory are not GDScript's to remove: the native document lock deletes
	# them once the browser has closed.
	if is_instance_valid(container):
		container.free()


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


## Leaving the tree releases the browser and its cap slot; a note that comes
## back (drag and drop reparents it) renders again or shows the placeholder,
## exactly as it did on its first _ready.
func _exit_tree() -> void:
	_remove_active_entry()
	_deactivate_webview(false)


func _enter_tree() -> void:
	if is_node_ready():
		_render_or_placeholder()


func _remove_active_entry() -> void:
	for i in range(_active_webviews.size() - 1, -1, -1):
		if _active_webviews[i].controls == self:
			_active_webviews.remove_at(i)
