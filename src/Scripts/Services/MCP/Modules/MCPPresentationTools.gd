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
		"minerva_presentation_add_image_tile",
		"minerva_presentation_modify_tile",
		"minerva_presentation_get_state",
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

	server._register_tool("minerva_presentation_modify_tile",
		"Modify fields on an existing tile by id. Every field is optional; only specified ones change. Coords clamped to [0,1] when provided. For image tiles, provide AT MOST ONE of image_path, image_base64, solid_color, source_graphics_editor to replace tile.src in place — kind cannot change (remove + add for that). For text tiles, content/text_mode update straightforwardly. font_size sets fixed-font mode (8..200 px); pass 0 to clear and revert to coupled mode (font derived from tile.h). auto_fit=true picks the largest font fitting (w, h) at any viewport (font_size wins if both set); pass auto_fit=false to clear the field.",
		{
			"type": "object",
			"properties": {
				"tab_name": {"type": "string"},
				"path": {"type": "string"},
				"slide_index": {"type": "integer"},
				"tile_id": {"type": "string"},
				"x": {"type": "number"},
				"y": {"type": "number"},
				"w": {"type": "number"},
				"h": {"type": "number"},
				"rotation": {"type": "number"},
				"content": {"type": "string"},
				"text_mode": {"type": "string", "description": "plain | bullet | numbered (text tiles only)"},
				"font_size": {"type": "integer", "description": "Fixed font size in px (8..200). 0 clears the override (coupled mode). Text tiles only."},
				"auto_fit": {"type": "boolean", "description": "Text tiles only. true = enable auto-fit; false = clear the field. font_size wins when both set."},
				"image_path": {"type": "string"},
				"image_base64": {"type": "string"},
				"solid_color": {"type": "string"},
				"source_graphics_editor": {"type": "string"},
			},
			"required": ["slide_index", "tile_id"],
		}
	, "presentation")

	# T6 R3: set_slide_title / set_aspect / move_slide migrated to plugin.

	# T6 R5: add_spreadsheet_tile / modify_spreadsheet_cells / resize_spreadsheet migrated to plugin.

	server._register_tool("minerva_presentation_get_state",
		"Read the live UI state of an open presentation tab — useful for HITL (\"what slide is the user on?\"). Returns selected_slide_index plus slide_count and the title of the selected slide. Tab must be open; this tool does NOT accept a path because state only exists in a live editor.",
		{
			"type": "object",
			"properties": {
				"tab_name": {"type": "string"},
			},
			"required": ["tab_name"],
		}
	, "presentation")

	# T6 R2: minerva_presentation_list_annotation_kinds migrated to plugin.
	# T6 tail: minerva_presentation_{list_open,add,remove,set_resolved}_annotation migrated to plugin.

	# T6 R4: minerva_presentation_remove_tile migrated to plugin.

	# T6 R3: minerva_presentation_remove_slide migrated to plugin.

	# T6 R2: minerva_presentation_list_tiles migrated to plugin.
	# T6 R2: minerva_presentation_list_annotations migrated to plugin.
	# T6 R2: minerva_presentation_get_tile migrated to plugin.
	# T6 R2: minerva_presentation_get_slide migrated to plugin.

	server._register_tool("minerva_presentation_add_image_tile",
		"Add an image tile to a slide. Coords x/y/w/h are 0..1 normalized. Provide exactly one image source: image_path, image_base64, source_graphics_editor (name of an open graphics editor — pulls layer 0's PNG bytes), or solid_color (hex; generates a small flat-color PNG that scales to fill the tile — handy for HR lines and decorative blocks).",
		{
			"type": "object",
			"properties": {
				"tab_name": {"type": "string"},
				"path": {"type": "string"},
				"slide_index": {"type": "integer"},
				"x": {"type": "number"},
				"y": {"type": "number"},
				"w": {"type": "number"},
				"h": {"type": "number"},
				"image_path": {"type": "string"},
				"image_base64": {"type": "string", "description": "Bare base64 PNG/JPEG."},
				"source_graphics_editor": {"type": "string", "description": "Name of an open graphics editor whose top layer should be embedded."},
				"solid_color": {"type": "string", "description": "Hex color (e.g. #1F4E5A) to synthesize as a small solid PNG."},
				"rotation": {"type": "number"},
			},
			"required": ["slide_index", "x", "y", "w", "h"],
		}
	, "presentation")


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
		"minerva_presentation_add_image_tile":
			return _add_image_tile(arguments)
		"minerva_presentation_modify_tile":
			return _modify_tile(arguments)
		"minerva_presentation_get_state":
			return _get_state(arguments)
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


func _list_slides(args: Dictionary) -> Dictionary:
	var resolved := _resolve_target(args)
	if resolved.has("error"):
		return resolved
	var deck: Dictionary = resolved["deck"]
	var slides: Array = deck.get("slides", []) as Array
	var summaries: Array = []
	for i in range(slides.size()):
		var s: Dictionary = slides[i] as Dictionary
		var item: Dictionary = {
			"index": i,
			"id": str(s.get("id", "")),
			"tile_count": (s.get("tiles", []) as Array).size(),
		}
		if s.has("title"):
			item["title"] = str(s["title"])
		summaries.append(item)
	return MCPToolUtils.success({
		"slides": summaries,
		"aspect": str(deck.get("aspect", ASPECT_DEFAULT)),
		"version": int(deck.get("version", SCHEMA_VERSION)),
	})


# T6 R3: _add_slide moved to plugin (~/github/plugins/presentation/main.go toolAddSlide).


# T6 R7: _set_slide_background moved to plugin.
# T6 R4: _add_text_tile moved to plugin.


func _add_image_tile(args: Dictionary) -> Dictionary:
	var resolved := _resolve_target(args)
	if resolved.has("error"):
		return resolved
	var deck: Dictionary = resolved["deck"]
	var slide_v := _slide_at(deck, args)
	if slide_v is Dictionary and slide_v.has("__error__"):
		return MCPToolUtils.error(slide_v["__error__"])
	var slide: Dictionary = slide_v as Dictionary

	var coords_err := _validate_coords(args)
	if coords_err != "":
		return MCPToolUtils.error(coords_err)

	var has_path := args.has("image_path") and not String(args.get("image_path", "")).is_empty()
	var has_b64 := args.has("image_base64") and not String(args.get("image_base64", "")).is_empty()
	var has_src_editor := args.has("source_graphics_editor") and not String(args.get("source_graphics_editor", "")).is_empty()
	var has_solid := args.has("solid_color") and not String(args.get("solid_color", "")).is_empty()
	var sources_set := int(has_path) + int(has_b64) + int(has_src_editor) + int(has_solid)
	if sources_set != 1:
		return MCPToolUtils.error("Provide exactly one of: image_path, image_base64, source_graphics_editor, solid_color")

	var b64: String = ""
	if has_path:
		var read := _read_file_as_base64(String(args["image_path"]))
		if read.has("error"):
			return MCPToolUtils.error(read["error"])
		b64 = read["base64"]
	elif has_b64:
		b64 = String(args["image_base64"])
	elif has_src_editor:
		var pulled := _read_graphics_editor_as_base64(String(args["source_graphics_editor"]))
		if pulled.has("error"):
			return MCPToolUtils.error(pulled["error"])
		b64 = pulled["base64"]
	else:
		# Synthesize a PNG sized to the tile's RENDERED aspect (which is
		# normalized w/h × slide aspect), so the plugin's STRETCH_KEEP_ASPECT_CENTERED
		# renders edge-to-edge. A square source in a wide HR rect would otherwise
		# show as a centered square box.
		var slide_aspect: float = _parse_aspect_ratio(String(deck.get("aspect", "16:9")))
		b64 = _make_solid_color_png_base64(
			String(args["solid_color"]),
			float(args["w"]),
			float(args["h"]),
			slide_aspect
		)
		if b64.is_empty():
			return MCPToolUtils.error("solid_color must be a valid hex color (e.g. #1F4E5A)")

	var tile: Dictionary = {
		"id": _gen_id("tile"),
		"kind": TILE_IMAGE,
		"x": float(args["x"]),
		"y": float(args["y"]),
		"w": float(args["w"]),
		"h": float(args["h"]),
		"src": b64,
	}
	var rotation: float = MCPToolUtils.coerce_float(args.get("rotation", 0.0))
	if not is_zero_approx(rotation):
		tile["rotation"] = rotation

	(slide["tiles"] as Array).append(tile)
	var commit_err := _commit_target(resolved, deck)
	if commit_err != "":
		return MCPToolUtils.error(commit_err)
	return MCPToolUtils.success({"tile_id": str(tile["id"])})


# ---------------------------------------------------------------------------
# Inspect handlers (read-only)
# ---------------------------------------------------------------------------

func _list_tiles(args: Dictionary) -> Dictionary:
	var resolved := _resolve_target(args)
	if resolved.has("error"):
		return resolved
	var deck: Dictionary = resolved["deck"]
	var slide_v := _slide_at(deck, args)
	if slide_v is Dictionary and slide_v.has("__error__"):
		return MCPToolUtils.error(slide_v["__error__"])
	var slide: Dictionary = slide_v as Dictionary

	var tiles: Array = slide.get("tiles", []) as Array
	var summaries: Array = []
	for t_v in tiles:
		summaries.append(_summarize_tile(t_v as Dictionary))
	return MCPToolUtils.success({
		"slide_index": MCPToolUtils.coerce_int(args["slide_index"]),
		"tiles": summaries,
	})


func _list_annotations(args: Dictionary) -> Dictionary:
	var resolved := _resolve_target(args)
	if resolved.has("error"):
		return resolved
	var deck: Dictionary = resolved["deck"]
	var slide_v := _slide_at(deck, args)
	if slide_v is Dictionary and slide_v.has("__error__"):
		return MCPToolUtils.error(slide_v["__error__"])
	var slide: Dictionary = slide_v as Dictionary

	# annotations is omit-when-default — absent key means empty list.
	var anns: Array = slide.get("annotations", []) as Array
	var summaries: Array = []
	for a_v in anns:
		summaries.append(_summarize_annotation(a_v as Dictionary))
	return MCPToolUtils.success({
		"slide_index": MCPToolUtils.coerce_int(args["slide_index"]),
		"annotations": summaries,
	})


func _get_tile(args: Dictionary) -> Dictionary:
	var missing: Variant = MCPToolUtils.check_required(args, ["tile_id"])
	if missing != null:
		return missing
	var resolved := _resolve_target(args)
	if resolved.has("error"):
		return resolved
	var deck: Dictionary = resolved["deck"]
	var slide_v := _slide_at(deck, args)
	if slide_v is Dictionary and slide_v.has("__error__"):
		return MCPToolUtils.error(slide_v["__error__"])
	var slide: Dictionary = slide_v as Dictionary

	var tile_id: String = String(args["tile_id"]).strip_edges()
	var tile: Dictionary = _find_tile_in_slide(slide, tile_id)
	if tile.is_empty():
		return MCPToolUtils.error("tile_id not found on slide %d: %s" % [
			MCPToolUtils.coerce_int(args["slide_index"]), tile_id
		])

	var include_src: bool = bool(args.get("include_src", false))
	var out: Dictionary = tile.duplicate(true)
	# Image tiles: drop or keep `src` based on include_src. Always include
	# src_size_bytes so the caller can budget.
	if String(out.get("kind", "")) == TILE_IMAGE:
		var src_str: String = String(out.get("src", ""))
		out["src_size_bytes"] = src_str.length()
		if not include_src:
			out.erase("src")
	return MCPToolUtils.success({
		"slide_index": MCPToolUtils.coerce_int(args["slide_index"]),
		"tile": out,
	})


func _get_slide(args: Dictionary) -> Dictionary:
	var resolved := _resolve_target(args)
	if resolved.has("error"):
		return resolved
	var deck: Dictionary = resolved["deck"]
	var slide_v := _slide_at(deck, args)
	if slide_v is Dictionary and slide_v.has("__error__"):
		return MCPToolUtils.error(slide_v["__error__"])
	var slide: Dictionary = slide_v as Dictionary

	var include_src: bool = bool(args.get("include_tile_src", false))
	var out: Dictionary = slide.duplicate(true)
	# Strip / annotate image tile srcs unless asked.
	var out_tiles: Array = out.get("tiles", []) as Array
	for i in range(out_tiles.size()):
		var t: Dictionary = out_tiles[i] as Dictionary
		if String(t.get("kind", "")) == TILE_IMAGE:
			var src_str: String = String(t.get("src", ""))
			t["src_size_bytes"] = src_str.length()
			if not include_src:
				t.erase("src")
	return MCPToolUtils.success({
		"slide_index": MCPToolUtils.coerce_int(args["slide_index"]),
		"slide": out,
	})


## Build a small summary dict for a tile suitable for list_tiles. Keeps image
## bytes out, caps text content at INSPECT_CONTENT_CAP_BYTES.
func _summarize_tile(tile: Dictionary) -> Dictionary:
	var kind: String = String(tile.get("kind", ""))
	var item: Dictionary = {
		"tile_id": String(tile.get("id", "")),
		"kind": kind,
		"x": float(tile.get("x", 0.0)),
		"y": float(tile.get("y", 0.0)),
		"w": float(tile.get("w", 0.0)),
		"h": float(tile.get("h", 0.0)),
	}
	if tile.has("rotation"):
		item["rotation"] = float(tile["rotation"])
	match kind:
		TILE_TEXT:
			item["text_mode"] = String(tile.get("text_mode", TEXT_MODE_PLAIN))
			var content: String = String(tile.get("content", ""))
			if content.length() > INSPECT_CONTENT_CAP_BYTES:
				item["content"] = content.substr(0, INSPECT_CONTENT_CAP_BYTES)
				item["_truncated"] = true
			else:
				item["content"] = content
		TILE_IMAGE:
			item["src_size_bytes"] = String(tile.get("src", "")).length()
		"spreadsheet":
			# Use literal — TILE_SPREADSHEET isn't a constant in this module yet
			# (v1 didn't author them), but the substrate uses "spreadsheet" as kind.
			item["rows"] = MCPToolUtils.coerce_int(tile.get("rows", 0))
			item["cols"] = MCPToolUtils.coerce_int(tile.get("cols", 0))
	return item


## Build a small summary dict for an annotation envelope. Envelope shape is
## opaque per substrate contract: `{id, kind, ...}` with kind-specific fields.
## We expose id+kind plus a best-effort payload_summary, position, resolved.
func _summarize_annotation(env: Dictionary) -> Dictionary:
	var kind: String = String(env.get("kind", ""))
	var item: Dictionary = {
		"annotation_id": String(env.get("id", "")),
		"kind": kind,
	}
	# Substrate annotation v2 carries a lifecycle state machine
	# ("open" | "applied" | "resolved" | "stale") — that's the authoritative
	# resolved-ness signal (no separate `resolved` bool exists). We surface
	# both: lifecycle verbatim (when present) for callers that care about
	# applied/stale, plus a derived resolved bool for the common case.
	# Hint: 019df443eb8777be962510697cdaddad
	var lifecycle: String = String(env.get("lifecycle", ""))
	if not lifecycle.is_empty():
		item["lifecycle"] = lifecycle
	item["resolved"] = (lifecycle == "resolved")

	# Best-effort position: prefer explicit position dict, else first vertex
	# of common geometry fields. Skip silently when nothing usable.
	var pos: Variant = _extract_position(env)
	if pos != null:
		item["position"] = pos

	# Best-effort payload_summary — text content for text-bearing kinds,
	# else a short geometry note. Capped at the inspect cap.
	var summary: String = _summarize_annotation_payload(env)
	if not summary.is_empty():
		if summary.length() > INSPECT_CONTENT_CAP_BYTES:
			item["payload_summary"] = summary.substr(0, INSPECT_CONTENT_CAP_BYTES)
			item["_truncated"] = true
		else:
			item["payload_summary"] = summary
	return item


func _extract_position(env: Dictionary) -> Variant:
	if env.has("position") and env["position"] is Dictionary:
		return env["position"]
	# Common substrate shapes — anchor / center / first vertex.
	for key in ["anchor", "center", "origin"]:
		if env.has(key) and env[key] is Dictionary:
			return env[key]
	if env.has("points") and env["points"] is Array and (env["points"] as Array).size() > 0:
		var first = (env["points"] as Array)[0]
		if first is Dictionary:
			return first
	return null


func _summarize_annotation_payload(env: Dictionary) -> String:
	# Substrate annotation v2 always has `summary` — use it first. Fall back to
	# kind-specific text fields for callout / text_2d / non-v2 envelopes.
	for key in ["summary", "text", "content", "label", "message"]:
		if env.has(key) and env[key] is String and not (env[key] as String).is_empty():
			return env[key] as String
	# Geometric kinds: short note about size.
	if env.has("points") and env["points"] is Array:
		return "%d points" % (env["points"] as Array).size()
	if env.has("rect") and env["rect"] is Dictionary:
		var r: Dictionary = env["rect"]
		return "rect %sx%s" % [str(r.get("w", "?")), str(r.get("h", "?"))]
	return ""


func _find_tile_in_slide(slide: Dictionary, tile_id: String) -> Dictionary:
	for t_v in slide.get("tiles", []) as Array:
		var t: Dictionary = t_v as Dictionary
		if String(t.get("id", "")) == tile_id:
			return t
	return {}


# ---------------------------------------------------------------------------
# Modify handlers
# ---------------------------------------------------------------------------
# Backed onto the same _resolve_target / _commit_target pattern as authoring.
# Field-by-field semantics: every property is optional; absent = unchanged.

const _MODIFY_COORD_KEYS: PackedStringArray = ["x", "y", "w", "h"]


func _modify_tile(args: Dictionary) -> Dictionary:
	var missing: Variant = MCPToolUtils.check_required(args, ["tile_id"])
	if missing != null:
		return missing
	var target := _resolve_target(args)
	if target.has("error"):
		return target
	var deck: Dictionary = target["deck"]
	var slide_v := _slide_at(deck, args)
	if slide_v is Dictionary and slide_v.has("__error__"):
		return MCPToolUtils.error(slide_v["__error__"])
	var slide: Dictionary = slide_v as Dictionary

	var tile_id: String = String(args["tile_id"]).strip_edges()
	var tile: Dictionary = _find_tile_in_slide(slide, tile_id)
	if tile.is_empty():
		return MCPToolUtils.error("tile_id not found on slide %d: %s" % [
			MCPToolUtils.coerce_int(args["slide_index"]), tile_id
		])
	var kind: String = String(tile.get("kind", ""))

	# Stage all mutations into a patch dict so a late-stage failure (e.g. an
	# invalid solid_color hex) doesn't leave the live tile half-modified.
	# We compute everything against the staged view, then merge in one shot.
	var patch: Dictionary = {}
	var erase_keys: Array[String] = []

	# Coords: validate only when provided; clamp to [0,1].
	for axis in _MODIFY_COORD_KEYS:
		if args.has(axis) and args[axis] != null:
			var v: float = MCPToolUtils.coerce_float(args[axis], -1.0)
			if v < 0.0 or v > 1.0:
				return MCPToolUtils.error("%s must be in [0, 1], got %f" % [axis, v])
			patch[axis] = clampf(v, 0.0, 1.0)

	# Rotation: 0 erases the field (omit-when-default), nonzero sets it.
	if args.has("rotation") and args["rotation"] != null:
		var rot: float = MCPToolUtils.coerce_float(args["rotation"], 0.0)
		if is_zero_approx(rot):
			erase_keys.append("rotation")
		else:
			patch["rotation"] = rot

	# Text-tile fields.
	if args.has("content") and args["content"] != null:
		if kind != TILE_TEXT:
			return MCPToolUtils.error("content can only be set on text tiles (this is %s)" % kind)
		patch["content"] = String(args["content"])
	if args.has("text_mode") and args["text_mode"] != null:
		if kind != TILE_TEXT:
			return MCPToolUtils.error("text_mode can only be set on text tiles (this is %s)" % kind)
		var mode: String = String(args["text_mode"])
		if not TEXT_MODES_VALID.has(mode):
			return MCPToolUtils.error("text_mode must be one of %s" % str(TEXT_MODES_VALID))
		patch["text_mode"] = mode
	if args.has("font_size") and args["font_size"] != null:
		if kind != TILE_TEXT:
			return MCPToolUtils.error("font_size can only be set on text tiles (this is %s)" % kind)
		var fs: int = MCPToolUtils.coerce_int(args["font_size"], 0)
		if fs == 0:
			erase_keys.append("font_size")
		else:
			if fs < 8 or fs > 200:
				return MCPToolUtils.error("font_size must be in [8, 200] or 0 to clear, got %d" % fs)
			patch["font_size"] = fs
	if args.has("auto_fit") and args["auto_fit"] != null:
		if kind != TILE_TEXT:
			return MCPToolUtils.error("auto_fit can only be set on text tiles (this is %s)" % kind)
		if bool(args["auto_fit"]):
			patch["auto_fit"] = true
		else:
			erase_keys.append("auto_fit")

	# Image-source replacement — at most one of these is allowed.
	var has_path := args.has("image_path") and not String(args.get("image_path", "")).is_empty()
	var has_b64 := args.has("image_base64") and not String(args.get("image_base64", "")).is_empty()
	var has_solid := args.has("solid_color") and not String(args.get("solid_color", "")).is_empty()
	var has_src_editor := args.has("source_graphics_editor") and not String(args.get("source_graphics_editor", "")).is_empty()
	var src_count := int(has_path) + int(has_b64) + int(has_solid) + int(has_src_editor)
	if src_count > 1:
		return MCPToolUtils.error("Provide at most one of: image_path, image_base64, solid_color, source_graphics_editor")
	if src_count == 1:
		if kind != TILE_IMAGE:
			return MCPToolUtils.error("Image-source fields only apply to image tiles (this is %s)" % kind)
		var b64: String = ""
		if has_path:
			var read := _read_file_as_base64(String(args["image_path"]))
			if read.has("error"):
				return MCPToolUtils.error(read["error"])
			b64 = read["base64"]
		elif has_b64:
			b64 = String(args["image_base64"])
		elif has_src_editor:
			var pulled := _read_graphics_editor_as_base64(String(args["source_graphics_editor"]))
			if pulled.has("error"):
				return MCPToolUtils.error(pulled["error"])
			b64 = pulled["base64"]
		else:
			# Solid color — synthesize at the post-merge w/h so a same-call
			# resize is reflected in the synthesized aspect.
			var effective_w: float = float(patch.get("w", tile.get("w", 1.0)))
			var effective_h: float = float(patch.get("h", tile.get("h", 1.0)))
			var slide_aspect: float = _parse_aspect_ratio(String(deck.get("aspect", "16:9")))
			b64 = _make_solid_color_png_base64(
				String(args["solid_color"]), effective_w, effective_h, slide_aspect
			)
			if b64.is_empty():
				return MCPToolUtils.error("solid_color must be a valid hex color (e.g. #1F4E5A)")
		patch["src"] = b64

	# All validations passed — apply patch atomically.
	for k in patch.keys():
		tile[k] = patch[k]
	for ek in erase_keys:
		tile.erase(ek)

	var commit_err := _commit_target(target, deck)
	if commit_err != "":
		return MCPToolUtils.error(commit_err)
	return MCPToolUtils.success({
		"slide_index": MCPToolUtils.coerce_int(args["slide_index"]),
		"tile_id": tile_id,
	})


## Reads live UI state from an open presentation tab. Tab-only — there's no
## "selected slide" concept for an on-disk file.
func _get_state(args: Dictionary) -> Dictionary:
	var tab_name: String = String(args.get("tab_name", "")).strip_edges()
	if tab_name.is_empty():
		return MCPToolUtils.error("tab_name is required")
	var panel: Variant = _find_panel_by_tab_name(tab_name)
	if panel == null:
		return MCPToolUtils.error("No open presentation tab named: %s" % tab_name)
	if not panel.has_method("get_selected_slide_index"):
		return MCPToolUtils.error("Panel does not expose selected slide (plugin may be out of date)")
	var deck: Dictionary = panel.get_deck()
	var slides: Array = deck.get("slides", []) as Array
	var idx: int = int(panel.get_selected_slide_index())
	var slide_title: String = ""
	if idx >= 0 and idx < slides.size():
		slide_title = String((slides[idx] as Dictionary).get("title", ""))
	return MCPToolUtils.success({
		"selected_slide_index": idx,
		"slide_count": slides.size(),
		"slide_title": slide_title,
	})


# T6 R3: _set_slide_title and _set_aspect moved to plugin.




# T6 tail: _list_open_annotations moved to plugin.




# T6 R5: _add_spreadsheet_tile / _modify_spreadsheet_cells / _resize_spreadsheet
#        plus their helpers (_empty_cell / _empty_cell_grid / _normalize_cell /
#        _auto_cell_type) moved to plugin.
# T6 R4: _remove_tile and _add_text_tile moved to plugin.
# T6 R3: _remove_slide and _move_slide moved to plugin.


# ---------------------------------------------------------------------------
# Target resolution (live tab vs disk)
# ---------------------------------------------------------------------------

## Returns: {deck: Dictionary, mode: "tab"|"path", panel: Variant?, path: String?, error?: String}
## Mutators read deck from this, mutate, then call _commit_target to write back.
func _resolve_target(args: Dictionary) -> Dictionary:
	var tab_name: String = String(args.get("tab_name", "")).strip_edges()
	var path: String = String(args.get("path", "")).strip_edges()
	if tab_name.is_empty() and path.is_empty():
		return MCPToolUtils.error("Provide either tab_name (open tab) or path (.mdeck file)")

	if not tab_name.is_empty():
		var panel: Variant = _find_panel_by_tab_name(tab_name)
		if panel == null:
			return MCPToolUtils.error("No open presentation tab named: %s" % tab_name)
		return {
			"deck": panel.get_deck(),
			"mode": "tab",
			"panel": panel,
		}

	if not FileAccess.file_exists(path):
		return MCPToolUtils.error("File not found: %s" % path)
	var loaded := _read_deck_from_disk(path)
	if loaded.has("error"):
		return loaded
	return {
		"deck": loaded["deck"],
		"mode": "path",
		"path": path,
	}


## Writes the deck back to its source. For "tab" mode, calls panel.set_deck()
## and emits content_changed so Minerva's host saves on next checkpoint. For
## "path" mode, writes JSON to disk. Returns "" on success or an error message.
func _commit_target(resolved: Dictionary, deck: Dictionary) -> String:
	var mode: String = String(resolved.get("mode", ""))
	if mode == "tab":
		var panel = resolved["panel"]
		if panel == null or not is_instance_valid(panel) or not panel.has_method("set_deck"):
			return "Panel no longer valid"
		panel.set_deck(deck)
		# Mark the tab dirty so the host save flow picks up the change.
		if panel.has_signal("content_changed"):
			panel.emit_signal("content_changed")
		return ""
	if mode == "path":
		return _write_deck_to_disk(String(resolved["path"]), deck)
	return "Unknown target mode: %s" % mode


# ---------------------------------------------------------------------------
# Panel discovery helpers
# ---------------------------------------------------------------------------

## Find an open SlideEditorPanel by its tab title. Returns the panel control
## (which has get_deck/set_deck) or null. Duck-typed because off-tree class_names
## don't register in res://.
func _find_panel_by_tab_name(tab_name: String) -> Variant:
	var editor_pane = _get_editor_pane()
	if editor_pane == null:
		return null
	var clean := tab_name.strip_edges()
	for editor in editor_pane.get_open_editors():
		if str(editor.tab_title) != clean:
			continue
		if not _is_presentation_editor(editor):
			continue
		var p: Variant = _panel_in_editor(editor)
		if p != null:
			return p
	# Fallback: by tab index
	for i in range(editor_pane.Tabs.get_tab_count()):
		if editor_pane.Tabs.get_tab_title(i) == clean:
			var ed = editor_pane.Tabs.get_tab_control(i)
			if ed != null and _is_presentation_editor(ed):
				return _panel_in_editor(ed)
	return null


## Find a panel whose loaded file path matches. Uses the panel's _ctx
## (set in _on_panel_loaded). Returns panel or null.
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

func _read_deck_from_disk(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return MCPToolUtils.error("Could not open %s for reading" % path)
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return MCPToolUtils.error("Invalid .mdeck JSON: %s" % path)
	return {"deck": parsed}


func _write_deck_to_disk(path: String, deck: Dictionary) -> String:
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var mk := DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			return "Could not create directory: %s" % dir
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open %s for writing" % path
	f.store_string(JSON.stringify(deck, "  "))
	f.close()
	return ""


func _read_file_as_base64(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return MCPToolUtils.error("File not found: %s" % path)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return MCPToolUtils.error("Could not open file: %s" % path)
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() == 0:
		return MCPToolUtils.error("Empty file: %s" % path)
	return {"base64": Marshalls.raw_to_base64(bytes)}


# ---------------------------------------------------------------------------
# Image generation helpers
# ---------------------------------------------------------------------------

## Create a flat-color PNG sized to match the target tile's RENDERED aspect
## ratio, then base64-encode it. The rendered aspect is `(w_norm/h_norm) * slide_aspect`
## because tiles are positioned in normalized 0..1 coords on a slide whose
## displayed aspect is e.g. 16:9. Aspect-matching is required because the
## plugin's image renderer uses STRETCH_KEEP_ASPECT_CENTERED — a source whose
## aspect doesn't match the rect's aspect renders as a smaller centered shape,
## not a fill.
##
## We floor (not round) the short edge so the source aspect comes out slightly
## MORE extreme than the rect aspect — that biases STRETCH_KEEP_ASPECT_CENTERED
## to fit-by-the-long-axis (e.g. fill width on a wide HR), with at most one
## sub-pixel of underfill on the short axis. Rounding-up would invert this and
## leave a visible side-padding gap on extreme rects (the HR-stub bug).
##
## Long edge of 4096 keeps short-edge rounding error <0.5% even at aspect 200:1,
## so even a 1px tall HR's ideal-short comes out near-integer. Flat-color PNGs
## RLE-compress to a few KB regardless of dimensions.
func _make_solid_color_png_base64(hex: String, w_norm: float = 1.0, h_norm: float = 1.0, slide_aspect: float = 16.0 / 9.0) -> String:
	var s := hex.strip_edges()
	if s.is_empty():
		return ""
	if not s.begins_with("#"):
		s = "#" + s
	if not Color.html_is_valid(s):
		return ""
	var c := Color.html(s)
	var w_safe: float = max(w_norm, 0.0001)
	var h_safe: float = max(h_norm, 0.0001)
	# Rendered rect aspect = (w_norm × slide_w) / (h_norm × slide_h)
	#                      = (w_norm / h_norm) × (slide_w / slide_h)
	var rect_aspect: float = (w_safe / h_safe) * max(slide_aspect, 0.0001)
	var target_long_px: int = 4096
	var px_w: int
	var px_h: int
	if rect_aspect >= 1.0:
		px_w = target_long_px
		# Floor (not round) so source aspect ≥ rect aspect → fill-by-width.
		px_h = max(1, int(floor(target_long_px / rect_aspect)))
	else:
		px_h = target_long_px
		px_w = max(1, int(floor(target_long_px * rect_aspect)))
	var img := Image.create(px_w, px_h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return Marshalls.raw_to_base64(img.save_png_to_buffer())


## Parse "16:9" / "4:3" / "1:1" → width/height ratio. Falls back to 16/9 on
## anything unparseable.
func _parse_aspect_ratio(s: String) -> float:
	var parts: PackedStringArray = s.split(":")
	if parts.size() != 2:
		return 16.0 / 9.0
	var w: float = float(parts[0])
	var h: float = float(parts[1])
	if w <= 0.0 or h <= 0.0:
		return 16.0 / 9.0
	return w / h


## Pull the top layer's PNG bytes from an open graphics editor. Returns
## {base64: "..."} on success or {error: "..."}.
func _read_graphics_editor_as_base64(editor_name: String) -> Dictionary:
	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if editor == null:
		return MCPToolUtils.error("Graphics editor not found: %s" % editor_name)
	var editor_script = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != editor_script.Type.GRAPHICS:
		return MCPToolUtils.error("Editor '%s' is not a graphics editor" % editor_name)
	if not editor.graphics_editor:
		return MCPToolUtils.error("Graphics editor '%s' not initialized" % editor_name)

	var ge = editor.graphics_editor
	# Layers are typically stored on the editor; pick the top non-empty layer.
	var layers = ge.layers if "layers" in ge else null
	if layers == null or not (layers is Array) or (layers as Array).is_empty():
		return MCPToolUtils.error("Graphics editor '%s' has no layers" % editor_name)
	# Walk top → bottom looking for a layer with a usable image.
	for i in range((layers as Array).size() - 1, -1, -1):
		var layer = (layers as Array)[i]
		if layer == null or not ("image" in layer) or layer.image == null:
			continue
		var img: Image = layer.image
		if img.get_width() <= 0 or img.get_height() <= 0:
			continue
		var img_for_export: Image = img.duplicate()
		if img_for_export.get_format() != Image.FORMAT_RGBA8:
			img_for_export.convert(Image.FORMAT_RGBA8)
		var buf: PackedByteArray = img_for_export.save_png_to_buffer()
		if buf.size() == 0:
			continue
		return {"base64": Marshalls.raw_to_base64(buf)}
	return MCPToolUtils.error("No usable image layer in graphics editor '%s'" % editor_name)


# ---------------------------------------------------------------------------
# Schema constructors (mirror slide_model.gd; off-tree means we can't import)
# ---------------------------------------------------------------------------

# T6 R6: _make_deck moved to plugin (used only by removed _create_deck).


func _make_slide(title: String = "") -> Dictionary:
	var s: Dictionary = {
		"id": _gen_id("slide"),
		"background": {"kind": BG_COLOR, "value": "#ffffff"},
		"tiles": [],
		"reveal": [],
	}
	if title != "":
		s["title"] = title
	return s


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

func _slide_at(deck: Dictionary, args: Dictionary) -> Dictionary:
	if not args.has("slide_index"):
		return {"__error__": "slide_index is required"}
	var idx: int = MCPToolUtils.coerce_int(args["slide_index"], -1)
	var slides: Array = deck.get("slides", []) as Array
	if idx < 0 or idx >= slides.size():
		return {"__error__": "slide_index out of range: %d (deck has %d slides)" % [idx, slides.size()]}
	return slides[idx] as Dictionary


func _validate_coords(args: Dictionary) -> String:
	for axis in ["x", "y", "w", "h"]:
		if not args.has(axis):
			return "%s is required" % axis
		var v: float = MCPToolUtils.coerce_float(args[axis], -1.0)
		if v < 0.0 or v > 1.0:
			return "%s must be in [0, 1], got %f" % [axis, v]
	return ""


# T6 R7: _normalize_hex moved to plugin (used only by removed _set_slide_background).


# ---------------------------------------------------------------------------
# ID generation (mirrors slide_model.gd:_gen_id pattern)
# ---------------------------------------------------------------------------

func _gen_id(prefix: String) -> String:
	if _id_seed < 0:
		_id_seed = randi() & 0xffff
	_id_counter += 1
	var ts: int = int(Time.get_unix_time_from_system())
	return "%s_%d_%04x_%d" % [prefix, ts, _id_seed, _id_counter]
