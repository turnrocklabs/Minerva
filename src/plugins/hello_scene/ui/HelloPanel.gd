class_name Helloscene_HelloPanel
extends MinervaPluginPanel
## Hello Scene panel — Phase 1B integration-validation plugin (§2.6 MVP scope).
##
## Reference implementation for the plugin authoring contract:
##   - Extends MinervaPluginPanel (DCR-1 grandchild 019dc5d4f6877ae5be60ea02e51dcd38)
##   - Declares capabilities ["project_state", "host_owned_save", "project_export"]
##     in manifest.json — install-time validator confirms the matching hooks
##     and channels exist.
##   - Captures FULL UI state on save (line_edit text, label text, dirty flag)
##     and restores all of it on load — the "walk away from the computer"
##     contract for project-state round-trip.
##   - Forwards content changes to the plugin server so server-side state
##     (greet count, cached text) round-trips through serialize/deserialize.
##
## class_name prefix "Helloscene" = canonical_prefix("hello_scene")
## per design §6.1: plugin_id.replace("_","").lower() → first-upper.


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _ctx: Dictionary = {}
var _reply_counter: int = 0

# Node references — set in _ready() after scene tree is available.
var _label: Label = null
var _line_edit: LineEdit = null
var _greet_button: Button = null
var _toolbar: AnnotationToolbar = null
var _canvas: Helloscene_AnnotationCanvas = null

# Annotation-substrate ownership (created in _ready, lives for panel lifetime).
var _annotation_registry: AnnotationRegistry = null
var _annotation_host: Helloscene_AnnotationHost = null

# Editor name under which we registered our annotation host with
# AnnotationHostRegistry. Tracked so _on_panel_unload deregisters the same
# key regardless of any later tab-rename. Empty string when not registered.
var _registered_editor_name: String = ""


# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_label = $VBoxContainer/Label
	_line_edit = $VBoxContainer/LineEdit
	_greet_button = $VBoxContainer/Button
	_toolbar = $VBoxContainer/CanvasRow/AnnotationToolbar
	_canvas = $VBoxContainer/CanvasRow/AnnotationCanvas

	_greet_button.pressed.connect(_on_greet_pressed)
	_line_edit.text_changed.connect(_on_text_changed)

	# Build the annotation registry, populate built-in 2D kinds, and wire
	# the host/toolbar/canvas trio. This is the reference wiring pattern
	# CAD/PCB will copy.
	_annotation_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_annotation_registry)

	_annotation_host = Helloscene_AnnotationHost.new()
	_annotation_host._registry = _annotation_registry

	_toolbar.set_registry(_annotation_registry)
	_toolbar.set_host(_annotation_host)
	_toolbar.active_tool_changed.connect(_on_active_tool_changed)

	_canvas.set_host(_annotation_host)
	# Wire canvas + root into the host so describe_point can resolve UI elements.
	_annotation_host.set_canvas_and_root(_canvas, self)

	_label.text = "Hello Scene ready. Type something and press Greet."


func _on_active_tool_changed(tool: AnnotationAuthorTool) -> void:
	if _canvas != null:
		_canvas.set_active_tool(tool)


# ---------------------------------------------------------------------------
# Plugin platform lifecycle hooks (override MinervaPluginPanel virtuals).
# ---------------------------------------------------------------------------

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx
	# Only set the initial-loaded label if we haven't already restored a
	# saved label from project state — _on_panel_load_request fires AFTER
	# _on_panel_loaded for project-restore, so we need this guard for the
	# fresh-tab case.  Without it the live greet result would survive a
	# walk-away/walk-back, which is the user-visible test for §2.6.
	var plugin_id: String = ctx.get("plugin_id", "")
	var panel_name: String = ctx.get("panel_name", "")
	_label.text = ("Hello Scene loaded — plugin: %s, panel: %s") % [plugin_id, panel_name]

	# Register our live AnnotationHost so MCP queries (minerva_annotations_list
	# editor_name=…) can answer "what did the user just draw?" without
	# requiring a save-to-sidecar first. The lookup key is the editor's tab
	# title — the same string surfaced by minerva_list_editors.
	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and _annotation_host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, _annotation_host)
			_registered_editor_name = ed_name


func _on_panel_unload() -> void:
	if _greet_button != null and _greet_button.pressed.is_connected(_on_greet_pressed):
		_greet_button.pressed.disconnect(_on_greet_pressed)
	if _line_edit != null and _line_edit.text_changed.is_connected(_on_text_changed):
		_line_edit.text_changed.disconnect(_on_text_changed)
	# Symmetric teardown for the toolbar→canvas active-tool forwarder.
	if _toolbar != null and _toolbar.active_tool_changed.is_connected(_on_active_tool_changed):
		_toolbar.active_tool_changed.disconnect(_on_active_tool_changed)
	if _canvas != null:
		_canvas.set_active_tool(null)
		_canvas.set_host(null)
	# Symmetric to _on_panel_loaded's register call.
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""


## Capture the FULL visible state of the panel (DCR-1 grandchild 019dc5d4...).
## Used for both host_owned save (Ctrl+S writes to .hello) and project-state
## capture (stashed in .minproj under tab_state.__panel_state).
func _on_panel_save_request() -> Dictionary:
	var annotations: Array = _annotation_host.get_annotations() if _annotation_host != null else []

	# Write the file-bound sidecar IF we have a document path. This is a side
	# effect inside _on_panel_save_request — known smell, tracked in a future
	# task to introduce a cleaner _on_file_saved(path) hook.
	#
	# We deliberately call write_sidecar even when `annotations` is empty:
	# write_sidecar applies the zero-annotation rule and DELETES the file when
	# the list is empty.  That keeps a stale sidecar from resurrecting deleted
	# annotations on the next load (sidecar wins precedence — see load_request).
	var file_path: String = _ctx.get("file_path", "")
	if not file_path.is_empty():
		var sidecar_data := {
			"substrate_version": 1,
			# kind = plugin_id (globally unique).  PCB's sidecar will use its
			# own plugin_id discriminator following the same convention.
			"document": {"path": file_path, "kind": "hello_scene"},
			"annotations": annotations,
			"unknown_kinds": [],
		}
		var err := AnnotationSidecar.write_sidecar(file_path, sidecar_data)
		if err != OK:
			push_warning("[HelloPanel] sidecar write failed for '%s': %d" % [file_path, err])

	return {
		"version": 1,
		"text": _line_edit.text if _line_edit != null else "",
		"label_text": _label.text if _label != null else "",
		"annotations": annotations,
	}


## Restore state from a previously-captured save.  Mirrors _on_panel_save_request.
func _on_panel_load_request(document: Dictionary) -> void:
	if _line_edit != null:
		_line_edit.text = str(document.get("text", ""))
	if _label != null:
		# Prefer the saved label_text (round-trips transient strings like a
		# greet response); fall back to a "Loaded:" prefix if no label was
		# saved (e.g. older .hello files written by the v0 hooks).
		var saved_label: String = str(document.get("label_text", ""))
		if not saved_label.is_empty():
			_label.text = saved_label
		else:
			_label.text = "Loaded: " + str(document.get("text", ""))

	if _annotation_host == null:
		return

	# Sidecar precedence: if a sidecar exists at the document path, it wins
	# over whatever's in the project-state Dict. Reasoning: the file is
	# authoritative; an explicit Ctrl+S save means "this is the document
	# state" and should override walk-away/walk-back transient state.
	var file_path: String = _ctx.get("file_path", "")
	var annotations_to_restore: Array = []

	if not file_path.is_empty():
		var sidecar: Dictionary = AnnotationSidecar.read_sidecar(file_path)
		if not sidecar.is_empty() and sidecar.has("annotations"):
			var sidecar_anns = sidecar.get("annotations", [])
			if sidecar_anns is Array:
				annotations_to_restore = sidecar_anns

	# Fall back to project-state Dict if no sidecar
	if annotations_to_restore.is_empty():
		var doc_anns = document.get("annotations", [])
		if doc_anns is Array:
			annotations_to_restore = doc_anns

	_annotation_host.set_annotations(annotations_to_restore)


# ---------------------------------------------------------------------------
# UI event handlers
# ---------------------------------------------------------------------------

func _on_greet_pressed() -> void:
	if $_MinervaIPC == null:
		_label.text = "Error: $_MinervaIPC not attached (broker not wired?)"
		return

	var message: String = ""
	if _line_edit != null:
		message = _line_edit.text

	_reply_counter += 1
	var reply_id: String = "hello_greet_%d" % _reply_counter
	request.emit("hello.greet", {"message": message}, reply_id)
	var result: Dictionary = await $_MinervaIPC.await_reply(reply_id)

	if result.get("success", false):
		var payload: Dictionary = result.get("result", {})
		var text_content: String = payload.get("text", "(no text in response)")
		if _label != null:
			_label.text = text_content
	else:
		var err: String = result.get("error_message", "unknown error")
		if _label != null:
			_label.text = "Greet failed: " + err


func _on_text_changed(new_text: String) -> void:
	# Flip the Editor's is_modified flag so the tab shows the unsaved indicator.
	content_changed.emit()
	# Forward to the plugin server so it can cache the text for serialize.
	# Fire-and-forget: we don't await the reply — content_changed should not
	# block typing.  The reply_id is unique but we never await it.
	if has_node("_MinervaIPC"):
		_reply_counter += 1
		var reply_id: String = "hello_changed_%d" % _reply_counter
		request.emit("hello.content_changed", {"text": new_text}, reply_id)
