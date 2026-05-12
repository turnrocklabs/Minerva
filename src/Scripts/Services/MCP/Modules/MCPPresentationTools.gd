class_name MCPPresentationTools
extends MCPToolModule
## MCP tool module for the presentation plugin (.mdeck slide decks).
##
## Two operating modes per tool:
##   * Live tab — pass `tab_name` to mutate an open SlideEditorPanel via its
##     public get_deck()/set_deck() accessors. Changes are immediately visible.
##   * Disk     — pass `path` to mutate a .mdeck JSON file directly. The file
##     can later be opened with presentation_open_deck.
##
## The presentation plugin is OFF-TREE (~/github/plugins/presentation/) so its
## class_names (Presentation_SlideModel, Presentation_SlideEditorPanel) do NOT
## register in res://. We treat the .mdeck file format as the contract and
## build dictionaries inline. The plugin's validate_deck() is the safety net
## at load time.
##
## Schema reference: slide_model.gd (version=1, normalized 0..1 coords, etc.)


const PLUGIN_ID: String = "presentation"
const PANEL_NAME: String = "slide_editor_panel"
const FILE_EXT: String = ".mdeck"

const SCHEMA_VERSION: int = 1
const ASPECT_DEFAULT: String = "16:9"
const ASPECTS_VALID: PackedStringArray = ["16:9", "4:3", "1:1"]

const TILE_TEXT: String = "text"
const TILE_IMAGE: String = "image"
const TILE_SPREADSHEET: String = "spreadsheet"

# T6 R5: CELL_* constants moved to plugin (plugins/presentation/main.go).

const TEXT_MODE_PLAIN: String = "plain"
const TEXT_MODE_BULLET: String = "bullet"
const TEXT_MODE_NUMBERED: String = "numbered"
const TEXT_MODES_VALID: PackedStringArray = [TEXT_MODE_PLAIN, TEXT_MODE_BULLET, TEXT_MODE_NUMBERED]

const BG_COLOR: String = "color"
const BG_IMAGE: String = "image"


# Per-instance counter so generated IDs don't collide within a session.
var _id_counter: int = 0
var _id_seed: int = -1


# ---------------------------------------------------------------------------
# Autoload lookup helpers
# ---------------------------------------------------------------------------
# Direct `SingletonObject.x` references at parse time can fail during the
# GDScript class_name scan pass (which runs BEFORE autoloads register), since
# this file has class_name MCPPresentationTools. Use these helpers instead.

func _get_editor_pane() -> Variant:
	var tree = Engine.get_main_loop()
	if not (tree is SceneTree):
		return null
	var root: Node = (tree as SceneTree).root
	if root == null:
		return null
	var so: Node = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	if "editor_pane" in so:
		return so.editor_pane
	return null


# ---------------------------------------------------------------------------
# Tool registration
# ---------------------------------------------------------------------------

## Cap on text-tile content returned by inspect tools to keep responses small.
## Truncated content is suffixed with a `_truncated: true` marker on the dict.
const INSPECT_CONTENT_CAP_BYTES: int = 8192


func get_tool_names() -> Array[String]:
	# T6 R2/R3 migration: the tools below moved to the off-tree presentation
	# plugin (~/github/plugins/presentation). Migrated reads (R2):
	#   - minerva_presentation_list_slides
	#   - minerva_presentation_list_tiles
	#   - minerva_presentation_list_annotations
	#   - minerva_presentation_list_annotation_kinds
	#   - minerva_presentation_get_slide
	#   - minerva_presentation_get_tile
	# Migrated slide-level mutators (R3):
	#   - minerva_presentation_add_slide
	#   - minerva_presentation_set_slide_title
	#   - minerva_presentation_set_aspect
	#   - minerva_presentation_move_slide
	#   - minerva_presentation_remove_slide
	# Migrated tile-level mutators (R4):
	#   - minerva_presentation_add_text_tile
	#   - minerva_presentation_remove_tile
	# Migrated spreadsheet ops (R5):
	#   - minerva_presentation_add_spreadsheet_tile
	#   - minerva_presentation_modify_spreadsheet_cells
	#   - minerva_presentation_resize_spreadsheet
	# Helpers (_resolve_target / _slide_at) remain because the still-unmigrated
	# tools (modify_tile, add_image_tile, set_slide_background, annotations,
	# get_state) use them.
	return [
		"minerva_presentation_open_deck",
	]



func register_tools() -> void:
	# T6 R6: minerva_presentation_create_deck migrated to plugin.

	server._register_tool("minerva_presentation_open_deck",
		"Open an existing .mdeck file as a presentation editor tab. Returns the tab_name to use for follow-up live-mutation calls. If a tab with the same path is already open, focuses it.",
		{
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "Path to a .mdeck file on disk."},
			},
			"required": ["path"],
		}
	, "presentation")

	# T6 R2: minerva_presentation_list_slides registration removed. Tool now
	# served by ~/github/plugins/presentation (Go backend, dynamic discovery).

	# T6 R3: minerva_presentation_add_slide migrated to plugin.

	# T6 R7: minerva_presentation_set_slide_background migrated to plugin.

	# T6 R4: minerva_presentation_add_text_tile migrated to plugin.
	# T6 tail R3: minerva_presentation_modify_tile migrated to plugin (source_graphics_editor deferred to a follow-up round).

	# T6 R3: set_slide_title / set_aspect / move_slide migrated to plugin.

	# T6 R5: add_spreadsheet_tile / modify_spreadsheet_cells / resize_spreadsheet migrated to plugin.

	# T6 tail R5: minerva_presentation_get_state migrated to plugin (panel UI state piggybacks on host_owned_save.get_request via _ui_state sibling key).

	# T6 R2: minerva_presentation_list_annotation_kinds migrated to plugin.
	# T6 tail: minerva_presentation_{list_open,add,remove,set_resolved}_annotation migrated to plugin.

	# T6 R4: minerva_presentation_remove_tile migrated to plugin.

	# T6 R3: minerva_presentation_remove_slide migrated to plugin.

	# T6 R2: minerva_presentation_list_tiles migrated to plugin.
	# T6 R2: minerva_presentation_list_annotations migrated to plugin.
	# T6 R2: minerva_presentation_get_tile migrated to plugin.
	# T6 R2: minerva_presentation_get_slide migrated to plugin.

	# T6 tail R4: minerva_presentation_add_image_tile migrated to plugin (source_graphics_editor uses host.editors.export).


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		# T6 R6: create_deck migrated to plugin.
		"minerva_presentation_open_deck":
			return _open_deck(arguments)
		# T6 R2: list_slides / list_tiles / list_annotations / get_tile / get_slide moved to plugin.
		# T6 R3: add_slide / set_slide_title / set_aspect / move_slide / remove_slide moved to plugin.
		# T6 R4: add_text_tile / remove_tile moved to plugin.
		# T6 R7: set_slide_background moved to plugin.
		# T6 tail R4: add_image_tile moved to plugin.
		# T6 tail R3: modify_tile moved to plugin.
		# T6 tail R5: get_state moved to plugin.
		# T6 R2: minerva_presentation_list_annotation_kinds moved to plugin.
		# T6 tail: minerva_presentation_{list_open,add,remove,set_resolved}_annotation moved to plugin.
		# T6 R5: spreadsheet ops (add_spreadsheet_tile, modify_spreadsheet_cells,
		# resize_spreadsheet) moved to plugin.
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


# ---------------------------------------------------------------------------
# Tool handlers
# ---------------------------------------------------------------------------

# T6 R6: _create_deck moved to plugin.


func _open_deck(args: Dictionary) -> Dictionary:
	var missing: Variant = MCPToolUtils.check_required(args, ["path"])
	if missing != null:
		return missing
	var path: String = String(args.get("path", "")).strip_edges()
	if not FileAccess.file_exists(path):
		return MCPToolUtils.error("File not found: %s" % path)

	# If already open, focus it and return its tab name.
	var existing: Variant = _find_panel_for_path(path)
	if existing != null:
		var ed: Variant = _editor_for_panel(existing)
		if ed != null:
			return MCPToolUtils.success({
				"tab_name": str(ed.tab_title),
				"slide_count": (existing.get_deck().get("slides", []) as Array).size(),
				"reused_existing_tab": true,
			})

	var editor_pane = _get_editor_pane()
	if editor_pane == null:
		return MCPToolUtils.error("No editor pane available")
	if not editor_pane.has_method("add_plugin_scene_editor"):
		return MCPToolUtils.error("EditorPane.add_plugin_scene_editor not available")

	var basename: String = path.get_file()
	var editor = editor_pane.add_plugin_scene_editor(PLUGIN_ID, PANEL_NAME, path, basename)
	if editor == null:
		return MCPToolUtils.error("Failed to open deck (add_plugin_scene_editor returned null)")

	var panel: Variant = _panel_in_editor(editor)
	var slide_count: int = 0
	if panel != null and panel.has_method("get_deck"):
		slide_count = (panel.get_deck().get("slides", []) as Array).size()

	return MCPToolUtils.success({
		"tab_name": str(editor.tab_title),
		"slide_count": slide_count,
		"reused_existing_tab": false,
	})


func _find_panel_for_path(path: String) -> Variant:
	var editor_pane = _get_editor_pane()
	if editor_pane == null:
		return null
	var target := ProjectSettings.globalize_path(path)
	for editor in editor_pane.get_open_editors():
		if not _is_presentation_editor(editor):
			continue
		var p: Variant = _panel_in_editor(editor)
		if p == null:
			continue
		# Editors associated with a file expose `file_path` or similar; fall
		# back to comparing tab_title basename if not available.
		if "file_path" in editor and str(editor.file_path) != "":
			if ProjectSettings.globalize_path(str(editor.file_path)) == target:
				return p
		elif str(editor.tab_title) == path.get_file():
			return p
	return null


func _is_presentation_editor(editor) -> bool:
	if editor == null:
		return false
	if not ("plugin_id" in editor) or not ("panel_name" in editor):
		return false
	return str(editor.plugin_id) == PLUGIN_ID and str(editor.panel_name) == PANEL_NAME


## Walk an editor's children to find the SlideEditorPanel. Identified by the
## presence of get_deck / set_deck methods (duck-typing — class_name unreachable).
func _panel_in_editor(editor) -> Variant:
	if editor == null:
		return null
	var stack: Array = [editor]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_method("get_deck") and n.has_method("set_deck"):
			return n
		for child in n.get_children():
			stack.append(child)
	return null


func _editor_for_panel(panel: Node) -> Variant:
	var cursor: Node = panel
	while cursor != null:
		if "plugin_id" in cursor and "tab_title" in cursor:
			if str(cursor.plugin_id) == PLUGIN_ID:
				return cursor
		cursor = cursor.get_parent()
	return null


# ---------------------------------------------------------------------------
# Disk I/O
# ---------------------------------------------------------------------------

