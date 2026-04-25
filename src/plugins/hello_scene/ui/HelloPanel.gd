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


# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_label = $VBoxContainer/Label
	_line_edit = $VBoxContainer/LineEdit
	_greet_button = $VBoxContainer/Button

	_greet_button.pressed.connect(_on_greet_pressed)
	_line_edit.text_changed.connect(_on_text_changed)

	_label.text = "Hello Scene ready. Type something and press Greet."


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


func _on_panel_unload() -> void:
	if _greet_button != null and _greet_button.pressed.is_connected(_on_greet_pressed):
		_greet_button.pressed.disconnect(_on_greet_pressed)
	if _line_edit != null and _line_edit.text_changed.is_connected(_on_text_changed):
		_line_edit.text_changed.disconnect(_on_text_changed)


## Capture the FULL visible state of the panel (DCR-1 grandchild 019dc5d4...).
## Used for both host_owned save (Ctrl+S writes to .hello) and project-state
## capture (stashed in .minproj under tab_state.__panel_state).
func _on_panel_save_request() -> Dictionary:
	return {
		"version": 1,
		"text": _line_edit.text if _line_edit != null else "",
		"label_text": _label.text if _label != null else "",
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
