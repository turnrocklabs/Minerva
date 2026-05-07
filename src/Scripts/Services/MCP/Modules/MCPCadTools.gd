class_name MCPCadTools
extends MCPToolModule
## MCP tool module for CAD editor introspection (task 019dd2049ff6).
##
## Read-only tools that let an AI agent answer questions about a live
## Cad_AnnotationHost without filesystem access or IPC round-trips:
##
##   cad_get_mesh_info       — geometry summary + bounding box
##   cad_list_edges_live     — full edge registry as the host holds it
##   cad_get_edge            — single edge by id
##   cad_get_selected_edge   — currently selected edge id + dict
##
## (cad_get_document_source removed in T8 of DCR 019dfa66 — use minerva_doc_read
## with the file path instead, which goes through the buffer-canonical pipeline.)
##
## All tools take `editor_name` (the tab title from minerva_list_editors) and
## resolve to a live AnnotationHost via AnnotationHostRegistry.
##
## Off-tree discipline: Cad_AnnotationHost is a plugin class; platform code
## MUST NOT reference it by class_name. All host method calls use duck typing
## (has_method / call) so this module compiles without the plugin loaded.
## The host is typed as AnnotationHost (the platform base class) — the type
## returned by AnnotationHostRegistry.get_host().
##
## Units: the CAD worker always returns geometry in millimetres. This is
## documented in the tool description and in the cad_get_mesh_info response
## (units: "mm"). No conversion is performed here.


func get_tool_names() -> Array[String]:
	return [
		"minerva_cad_get_mesh_info",
		"minerva_cad_list_edges_live",
		"minerva_cad_get_edge",
		"minerva_cad_get_selected_edge",
		"minerva_cad_annotate_edges",
		"minerva_cad_clear_edge_annotations",
		"minerva_cad_list_user_labels",
		"minerva_cad_export",
		"minerva_cad_snapshot",
	]


func register_tools() -> void:
	server._register_tool(
		"minerva_cad_get_mesh_info",
		"Return geometry summary for a live CAD editor: vertex count, face count, "
		+ "axis-aligned bounding box, and whether any geometry exists. "
		+ "Bounding box coordinates are in millimetres (CAD always uses mm). "
		+ "has_geometry is false when the panel has not yet evaluated any DSL source. "
		+ "Use minerva_doc_read (with the editor's file path) to check what DSL is loaded.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors). "
					+ "Must match a live CAD panel.",
				},
			},
			"required": ["editor_name"],
		},
		"cad"
	)

	server._register_tool(
		"minerva_cad_list_edges_live",
		"Return the full edge registry from a live CAD editor as an array of edge dicts. "
		+ "Each dict has at minimum: id (int), kind (string: 'straight' or 'circle'). "
		+ "Straight edges include length (mm); circle edges include radius (mm). "
		+ "The exact dict shape mirrors what the CAD worker returns — no transformation. "
		+ "Returns an empty array when no geometry has been evaluated yet.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors).",
				},
			},
			"required": ["editor_name"],
		},
		"cad"
	)

	server._register_tool(
		"minerva_cad_get_edge",
		"Return a single edge dict from a live CAD editor by integer id. "
		+ "Returns {ok: true, edge: null} when the id is not found (not an error). "
		+ "Use cad_list_edges_live to enumerate available ids.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors).",
				},
				"edge_id": {
					"type": "integer",
					"description": "Numeric edge id as reported by cad_list_edges_live.",
				},
			},
			"required": ["editor_name", "edge_id"],
		},
		"cad"
	)

	server._register_tool(
		"minerva_cad_get_selected_edge",
		"Return the currently selected edge id and its full dict from a live CAD editor. "
		+ "selected_edge_id is -1 and edge is null when no edge is selected. "
		+ "Edge selection is driven by the user clicking in the 3-D viewport or via the "
		+ "Prev/Next buttons in the sidebar.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors).",
				},
			},
			"required": ["editor_name"],
		},
		"cad"
	)

	server._register_tool(
		"minerva_cad_annotate_edges",
		"Create one cad_edge_number annotation per resolved edge on a live CAD panel. "
		+ "Exactly one selector must be supplied: either edge_ids (explicit list of integer edge ids) "
		+ "or tags_any (list of tag strings — edges whose tags intersect this set are annotated). "
		+ "An optional group_id groups annotations for later bulk clearing; one is minted if omitted. "
		+ "An optional label_format overrides the display text (default: str(edge_id)). "
		+ "Returns {group_id, created_edge_ids, skipped_unknown_ids}. "
		+ "Unknown edge ids are skipped with a warning rather than causing an error.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors).",
				},
				"edge_ids": {
					"type": "array",
					"items": {"type": "integer"},
					"description": "Explicit list of edge ids to annotate. Mutually exclusive with tags_any.",
				},
				"tags_any": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Annotate all edges whose tags field contains at least one of these strings. "
					+ "Mutually exclusive with edge_ids.",
				},
				"group_id": {
					"type": "string",
					"description": "Logical group label for later bulk clearing via clear_edge_annotations. "
					+ "Minted automatically if omitted.",
				},
				"label_format": {
					"type": "string",
					"description": "Override display text for every annotation. "
					+ "The literal string is used as-is (no substitution). "
					+ "Default: str(edge_id).",
				},
			},
			"required": ["editor_name"],
		},
		"cad"
	)

	server._register_tool(
		"minerva_cad_clear_edge_annotations",
		"Remove cad_edge_number annotations from a live CAD panel. "
		+ "Exactly one predicate must be supplied: "
		+ "group_id removes only annotations with that group label; "
		+ "all=true removes all cad_edge_number annotations regardless of group. "
		+ "Returns {cleared_count}. "
		+ "Returns cleared_count=0 (not an error) when no matching annotations exist.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors).",
				},
				"group_id": {
					"type": "string",
					"description": "Remove only annotations whose group_id payload field matches this string. "
					+ "Mutually exclusive with all.",
				},
				"all": {
					"type": "boolean",
					"description": "If true, remove ALL cad_edge_number annotations on this host. "
					+ "Mutually exclusive with group_id.",
				},
			},
			"required": ["editor_name"],
		},
		"cad"
	)

	server._register_tool(
		"minerva_cad_snapshot",
		"Capture a PNG snapshot of a live CAD editor's 3-D viewport so vision-capable "
		+ "models can SEE the geometry instead of just reading mesh/edge metadata. "
		+ "view selects which pane: 'iso' (perspective), 'top'/'front'/'right' "
		+ "(orthographic outline), or 'active' (whichever pane is currently focused / "
		+ "the only one visible in narrow layout). Wide layout renders all 4 panes "
		+ "simultaneously so any view works; in narrow layout only the active view "
		+ "captures live (others may be stale or null). "
		+ "Saves the PNG under user://cad_snapshots/ unless output_path is supplied. "
		+ "Returns {path, absolute_path, width, height, view, content_type ('image/png'), "
		+ "has_geometry, vertex_count, face_count, bounding_box (mm, null when no geometry), "
		+ "units ('mm')}; pass return_base64=true to additionally include image_base64 "
		+ "(raw base64 PNG, no data: prefix) for direct vision consumption. "
		+ "max_edge clamps the long edge (default 1024) to avoid blowing tool budgets. "
		+ "output_path under res:// is rejected.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors).",
				},
				"view": {
					"type": "string",
					"enum": ["iso", "top", "front", "right", "active"],
					"description": "Which viewport pane to capture. Default 'active'.",
				},
				"output_path": {
					"type": "string",
					"description": "Where to write the PNG. Default: user://cad_snapshots/<editor>_<view>_<ts>.png. "
					+ "Absolute, ~-prefixed, or user:// paths accepted.",
				},
				"return_base64": {
					"type": "boolean",
					"description": "If true, also include image_base64 (raw base64 PNG, no data: prefix) in the result.",
				},
				"max_edge": {
					"type": "integer",
					"description": "Clamp the long edge of the captured image to this many pixels (default 1024). "
					+ "Aspect ratio preserved.",
				},
			},
			"required": ["editor_name"],
		},
		"cad"
	)

	server._register_tool(
		"minerva_cad_export",
		"Export the geometry of a live CAD editor to a file. "
		+ "Resolves the editor's current DSL source via DocumentRegistry, then "
		+ "dispatches to the cad plugin's worker which re-evaluates the DSL and "
		+ "writes the file. Supported formats: 'stl' (binary STL — build123d default), "
		+ "'step' or 'stp' (STEP AP214 — OCCT default), '3mf' (build123d Mesher). "
		+ "Path is absolute as-is; ~-prefixed paths are expanded; bare relative "
		+ "paths resolve against the user's home directory. "
		+ "Returns {path, bytes_written, format} on success. DSL parse/translate "
		+ "errors are surfaced verbatim — the user can fix them and retry.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors). "
					+ "Must match a live CAD panel.",
				},
				"format": {
					"type": "string",
					"enum": ["stl", "step", "stp", "3mf"],
					"description": "Output format. STL is binary by default.",
				},
				"path": {
					"type": "string",
					"description": "Absolute, ~-prefixed, or bare relative path. "
					+ "Bare relative paths resolve against the user's home directory.",
				},
			},
			"required": ["editor_name", "format", "path"],
		},
		"cad"
	)

	server._register_tool(
		"minerva_cad_list_user_labels",
		"Return the list of cad_edge_number annotations the USER has authored on a live CAD panel. "
		+ "Use this whenever the user references 'the edges I labeled' (or 'pinned', 'tagged', "
		+ "'marked', 'selected') and expects you to operate on a SET of edges they identified — "
		+ "minerva_cad_get_selected_edge only returns the single most-recent click, not the "
		+ "set the user has been building up. "
		+ "Returns {labels: [{edge_id, text, annotation_id, view_context}], count}. "
		+ "Each label corresponds to one cad_edge_number annotation with author=='human'; "
		+ "agent-minted annotations (via minerva_cad_annotate_edges) are excluded. "
		+ "text is whatever the user typed in the annotation dialog (may be empty). "
		+ "When count==0 the user has not labelled anything — fall back to "
		+ "minerva_cad_get_selected_edge or ask which edges they mean.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors).",
				},
			},
			"required": ["editor_name"],
		},
		"cad"
	)



func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_cad_get_mesh_info":
			return _cad_get_mesh_info(arguments)
		"minerva_cad_list_edges_live":
			return _cad_list_edges_live(arguments)
		"minerva_cad_get_edge":
			return _cad_get_edge(arguments)
		"minerva_cad_get_selected_edge":
			return _cad_get_selected_edge(arguments)
		"minerva_cad_annotate_edges":
			return _cad_annotate_edges(arguments)
		"minerva_cad_clear_edge_annotations":
			return _cad_clear_edge_annotations(arguments)
		"minerva_cad_list_user_labels":
			return _cad_list_user_labels(arguments)
		"minerva_cad_export":
			return await _cad_export(arguments)
		"minerva_cad_snapshot":
			return _cad_snapshot(arguments)
	return _err("Unknown CAD tool: %s" % tool_name)


# ── Tool implementations ──────────────────────────────────────────────────────

func _cad_get_mesh_info(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_mesh_data"):
		return _err(
			"cad_get_mesh_info: host for '%s' does not expose get_mesh_data — "
			+ "plugin version may not support MCP introspection."
			% str(args.get("editor_name", ""))
		)

	var mesh: Dictionary = host.call("get_mesh_data")
	var vertices: Array = mesh.get("vertices", []) if mesh is Dictionary else []
	var faces: Array = mesh.get("faces", []) if mesh is Dictionary else []
	var has_geometry: bool = vertices.size() > 0

	var bbox: Variant = null
	if has_geometry:
		bbox = _compute_bbox(vertices)

	return _ok({
		"has_geometry": has_geometry,
		"vertex_count": vertices.size(),
		"face_count": faces.size(),
		"bounding_box": bbox,
		"units": "mm",
	})


func _cad_list_edges_live(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_edge_registry"):
		return _err(
			"cad_list_edges_live: host for '%s' does not expose get_edge_registry."
			% str(args.get("editor_name", ""))
		)

	var edges: Array = host.call("get_edge_registry")
	return _ok({"edges": edges})


func _cad_get_edge(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_edge_registry"):
		return _err(
			"cad_get_edge: host for '%s' does not expose get_edge_registry."
			% str(args.get("editor_name", ""))
		)

	var edge_id_variant: Variant = args.get("edge_id", null)
	if edge_id_variant == null:
		return _err("edge_id is required")
	var edge_id: int = int(edge_id_variant)

	var edges: Array = host.call("get_edge_registry")
	var found: Variant = null
	for edge in edges:
		if edge is Dictionary and int(edge.get("id", -1)) == edge_id:
			found = edge
			break

	return _ok({"edge": found})


func _cad_get_selected_edge(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_selected_edge_id"):
		return _err(
			"cad_get_selected_edge: host for '%s' does not expose get_selected_edge_id."
			% str(args.get("editor_name", ""))
		)

	var selected_id: int = host.call("get_selected_edge_id")

	# Look up the full edge dict if there is a selection.
	var edge_dict: Variant = null
	if selected_id != -1 and host.has_method("get_edge_registry"):
		var edges: Array = host.call("get_edge_registry")
		for edge in edges:
			if edge is Dictionary and int(edge.get("id", -1)) == selected_id:
				edge_dict = edge
				break

	return _ok({
		"selected_edge_id": selected_id,
		"edge": edge_dict,
	})


func _cad_annotate_edges(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	# Validate that the host exposes the edge registry.
	if not host.has_method("get_edge_registry"):
		return _err(
			"cad_annotate_edges: host for '%s' does not expose get_edge_registry."
			% str(args.get("editor_name", ""))
		)

	# ── Selector validation ───────────────────────────────────────────────────
	var has_edge_ids: bool = args.has("edge_ids") and args["edge_ids"] != null
	var has_tags_any: bool = args.has("tags_any") and args["tags_any"] != null

	if has_edge_ids and has_tags_any:
		return _err(
			"cad_annotate_edges: provide exactly one selector: edge_ids or tags_any, not both."
		)
	if not has_edge_ids and not has_tags_any:
		return _err(
			"cad_annotate_edges: exactly one selector is required: edge_ids or tags_any."
		)

	# ── Build edge id list from selector ──────────────────────────────────────
	var all_edges: Array = host.call("get_edge_registry")

	# Build a lookup for fast validation: edge_id (int) → edge dict.
	var edge_lookup: Dictionary = {}
	for edge_info in all_edges:
		if edge_info is Dictionary:
			edge_lookup[int(edge_info.get("id", -1))] = edge_info

	var target_ids: Array = []

	if has_edge_ids:
		var raw_ids: Variant = args["edge_ids"]
		if raw_ids is Array:
			for raw_id in (raw_ids as Array):
				target_ids.append(int(raw_id))
		else:
			return _err("cad_annotate_edges: edge_ids must be an array of integers.")
	else:
		# tags_any filter: collect edges whose tags intersect with tags_any.
		var filter_tags: Array = []
		var raw_tags: Variant = args["tags_any"]
		if raw_tags is Array:
			for t in (raw_tags as Array):
				filter_tags.append(str(t))
		else:
			return _err("cad_annotate_edges: tags_any must be an array of strings.")

		for edge_info in all_edges:
			if not (edge_info is Dictionary):
				continue
			var edge_tags: Variant = (edge_info as Dictionary).get("tags", [])
			var tags_arr: Array = edge_tags as Array if edge_tags is Array else []
			for edge_tag in tags_arr:
				if filter_tags.has(str(edge_tag)):
					target_ids.append(int((edge_info as Dictionary).get("id", -1)))
					break

	# ── Mint or use group_id ──────────────────────────────────────────────────
	var group_id: String = str(args.get("group_id", ""))
	if group_id.is_empty():
		# Mint: "cad_edge_grp_" + 8 random hex digits.
		group_id = "cad_edge_grp_%08x" % (randi() & 0xFFFFFFFF)

	var label_format_override: Variant = args.get("label_format", null)

	# ── Create annotations ────────────────────────────────────────────────────
	var created_ids: Array = []
	var skipped_unknown: Array = []

	for edge_id in target_ids:
		if not edge_lookup.has(edge_id):
			skipped_unknown.append(edge_id)
			push_warning(
				"[MCPCadTools] cad_annotate_edges: edge_id %d not found in registry — skipped."
				% edge_id
			)
			continue

		# Build label.
		var label: String = ""
		if label_format_override != null and str(label_format_override) != "":
			label = str(label_format_override)
		else:
			label = str(edge_id)

		var view_context := ""
		if host.has_method("get_view_context"):
			view_context = str(host.call("get_view_context"))

		# Build a v2 live edge-anchor annotation. The CAD renderer resolves the
		# current midpoint from this anchor each draw; primitive-only v1 edge
		# annotations are kept as a renderer compatibility path only.
		var annotation: Dictionary = {
			"kind": "cad_edge_number",
			"schema_version": 2,
			"author": "ai",
			"view_context": view_context,
			"anchor": {
				"plugin": "cad",
				"type": "edge",
				"id": edge_id,
			},
			"payload": {
				"text": label,
				"group_id": group_id,
				"box_offset": [0.0, 0.0, 0.0],
			},
		}

		host.call("add_annotation", annotation)
		created_ids.append(edge_id)

	return _ok({
		"group_id": group_id,
		"created_edge_ids": created_ids,
		"skipped_unknown_ids": skipped_unknown,
	})


func _cad_clear_edge_annotations(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	# Validate predicate.
	var has_group_id: bool = args.has("group_id") and args["group_id"] != null and str(args["group_id"]) != ""
	var clear_all: bool = bool(args.get("all", false))

	if has_group_id and clear_all:
		return _err(
			"cad_clear_edge_annotations: provide exactly one predicate: group_id or all=true, not both."
		)
	if not has_group_id and not clear_all:
		return _err(
			"cad_clear_edge_annotations: a predicate is required: group_id or all=true."
		)

	if not host.has_method("get_annotations"):
		return _err(
			"cad_clear_edge_annotations: host for '%s' does not expose get_annotations."
			% str(args.get("editor_name", ""))
		)

	if not host.has_method("remove_annotation"):
		return _err(
			"cad_clear_edge_annotations: host for '%s' does not expose remove_annotation."
			% str(args.get("editor_name", ""))
		)

	var filter_group: String = str(args.get("group_id", ""))
	var annotations: Array = host.call("get_annotations")

	# Collect ids to remove first (can't mutate while iterating).
	var to_remove: Array = []
	for ann in annotations:
		if not (ann is Dictionary):
			continue
		var ann_dict: Dictionary = ann as Dictionary
		var kind: String = str(ann_dict.get("kind", ""))
		if kind != "cad_edge_number":
			continue
		if clear_all:
			to_remove.append(str(ann_dict.get("id", "")))
		else:
			# Match by group_id in payload.
			var payload: Variant = ann_dict.get("payload", {})
			if payload is Dictionary:
				var ann_group: String = str((payload as Dictionary).get("group_id", ""))
				if ann_group == filter_group:
					to_remove.append(str(ann_dict.get("id", "")))

	for ann_id in to_remove:
		if ann_id != "":
			host.call("remove_annotation", ann_id)

	return _ok({"cleared_count": to_remove.size()})


func _cad_list_user_labels(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_annotations"):
		return _err(
			"cad_list_user_labels: host for '%s' does not expose get_annotations."
			% str(args.get("editor_name", ""))
		)

	var annotations: Array = host.call("get_annotations")
	var labels: Array = []
	for ann in annotations:
		if not (ann is Dictionary):
			continue
		var ann_dict: Dictionary = ann as Dictionary
		# Filter to cad_edge_number kind authored by the user. The cad_edge_number
		# tool stamps author="human"; agent-minted annotations from
		# minerva_cad_annotate_edges stamp author="ai". The exclusion is deliberate:
		# agent labels are bookkeeping, not user intent the agent should act on.
		if str(ann_dict.get("kind", "")) != "cad_edge_number":
			continue
		if str(ann_dict.get("author", "")) != "human":
			continue

		var anchor: Variant = ann_dict.get("anchor", {})
		if not (anchor is Dictionary):
			continue
		var anchor_d: Dictionary = anchor as Dictionary
		if not anchor_d.has("id"):
			continue
		var edge_id: int = int(anchor_d["id"])

		var payload: Dictionary = ann_dict.get("payload", {}) as Dictionary
		var text: String = str(payload.get("text", ""))

		labels.append({
			"edge_id": edge_id,
			"text": text,
			"annotation_id": str(ann_dict.get("id", "")),
			"view_context": str(ann_dict.get("view_context", "")),
		})

	return _ok({
		"labels": labels,
		"count": labels.size(),
	})


## Export geometry to a file. Resolves source via DocumentBuffer, then
## delegates to the cad plugin's `cad.export` MCP tool (which forwards to the
## Python worker via cad-plugin → bridge → mcad_worker).
func _cad_export(args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return _err("editor_name is required")

	var fmt: String = str(args.get("format", "")).strip_edges().to_lower()
	const _SUPPORTED := ["stl", "step", "stp", "3mf"]
	if fmt.is_empty():
		return _err("format is required (one of: stl, step, stp, 3mf)")
	if not _SUPPORTED.has(fmt):
		return _err("unsupported format '%s' (supported: %s)" % [fmt, str(_SUPPORTED)])

	var path: String = str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return _err("path is required (absolute, ~-prefixed, or bare relative resolved against home)")

	# Resolve editor → DocumentBuffer source. CAD panels are paired_dsl plugin
	# scenes; the broker holds the canonical buffer attached to the panel.
	var source: String = ""
	var editor: Variant = MCPToolUtils.find_editor_by_name(editor_name)
	if editor == null:
		return _err("editor_not_found: %s" % editor_name)

	var pbroker = SingletonObject.plugin_scene_panel_broker
	if pbroker != null:
		var ed_pid: String = str(editor.plugin_id) if "plugin_id" in editor else ""
		var ed_pname: String = str(editor.panel_name) if "panel_name" in editor else ""
		if not ed_pid.is_empty() and not ed_pname.is_empty():
			var attached: DocumentBuffer = pbroker.get_attached_buffer(ed_pid, ed_pname)
			if attached != null:
				source = attached.text
	if source.is_empty() and editor.has_method("get_document_buffer"):
		var ed_buf: DocumentBuffer = editor.get_document_buffer()
		if ed_buf != null:
			source = ed_buf.text
	if source.is_empty():
		return _err(
			"no_source_for_editor: '%s' has no DocumentBuffer attached. "
			% editor_name
			+ "Ensure the panel is open and the DSL has been entered."
		)

	# Dispatch to cad plugin's `cad.export` MCP tool.
	if SingletonObject.plugin_manager == null:
		return _err("plugin_manager not initialised")
	var conn = SingletonObject.plugin_manager.get_connection("cad")
	if conn == null:
		return _err("cad plugin not running — start it via PluginManager UI or minerva_plugin_start")

	var plugin_args := {
		"source": source,
		"format": fmt,
		"path": path,
	}
	var plugin_result: Dictionary = await conn.call_tool("cad.export", plugin_args)

	# The plugin returns {ok: true, result: {...}} or {ok: false, error: {...}}
	# wrapped in the MCP envelope. MCPServerConnection._normalize_mcp_tool_result
	# already unwraps the {content:[{text}]} envelope to return the inner dict.
	if plugin_result.has("error"):
		var err_field: Variant = plugin_result["error"]
		if err_field is Dictionary:
			var err_d: Dictionary = err_field
			return _err(
				"cad_export_failed (kind=%s): %s"
				% [str(err_d.get("kind", "unknown")), str(err_d.get("message", ""))]
			)
		return _err("cad_export_failed: %s" % str(err_field))

	if not plugin_result.get("ok", false):
		return _err("cad_export_failed: %s" % JSON.stringify(plugin_result))

	var result_payload: Variant = plugin_result.get("result", plugin_result)
	if not (result_payload is Dictionary):
		return _err("cad_export_failed: unexpected payload shape: %s" % JSON.stringify(plugin_result))
	var rd: Dictionary = result_payload as Dictionary

	return _ok({
		"path": str(rd.get("path", path)),
		"bytes_written": int(rd.get("bytes_written", 0)),
		"format": str(rd.get("format", fmt)),
	})


## Capture a PNG snapshot of the requested CAD viewport via
## Cad_AnnotationHost.render_view_to_image(). Saves to disk and optionally
## returns a base64-encoded copy for inline vision consumption.
##
## "active" view resolves to whatever the host's _active_viewport_id currently
## reports (set_active_viewport tracks user focus). Named views capture only
## reliably in WIDE layout where all 4 SubViewports render simultaneously; in
## narrow layout, off-screen views may return stale or null images.
const _SNAPSHOT_DEFAULT_DIR := "user://cad_snapshots"
const _SNAPSHOT_DEFAULT_MAX_EDGE := 1024
const _SNAPSHOT_VALID_VIEWS := ["iso", "top", "front", "right", "active"]

func _cad_snapshot(args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return _err("editor_name is required")

	var view_arg: String = str(args.get("view", "active")).strip_edges().to_lower()
	if view_arg.is_empty():
		view_arg = "active"
	if not _SNAPSHOT_VALID_VIEWS.has(view_arg):
		return _err("invalid view '%s' (valid: %s)" % [view_arg, str(_SNAPSHOT_VALID_VIEWS)])

	var max_edge: int = int(args.get("max_edge", _SNAPSHOT_DEFAULT_MAX_EDGE))
	if max_edge <= 0:
		max_edge = _SNAPSHOT_DEFAULT_MAX_EDGE

	var return_base64: bool = bool(args.get("return_base64", false))

	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("render_view_to_image"):
		return _err(
			"snapshot: host for '%s' does not expose render_view_to_image — "
			% editor_name
			+ "the cad plugin may be older than the snapshot wiring."
		)

	# Resolve "active" to the host's current active viewport id. Cad_AnnotationHost
	# exposes get_active_viewport() — fall back to "iso" if unavailable.
	var view_id: String = view_arg
	if view_arg == "active":
		if host.has_method("get_active_viewport"):
			view_id = str(host.call("get_active_viewport"))
		else:
			view_id = "iso"
		if view_id.is_empty():
			view_id = "iso"

	var img: Image = host.call("render_view_to_image", view_id, Rect2()) as Image
	if img == null:
		return _err(
			"snapshot: render_view_to_image returned null for view '%s'. "
			% view_id
			+ "First call may return null on cold start (frame_post_draw is "
			+ "scheduled — retry next frame). For non-active views in narrow "
			+ "layout, the SubViewport may not be rendering — switch to wide "
			+ "layout or to view='active'."
		)

	# Downsample to max_edge if oversize. Aspect ratio preserved.
	var orig_w: int = img.get_width()
	var orig_h: int = img.get_height()
	var long_edge: int = maxi(orig_w, orig_h)
	if long_edge > max_edge:
		var scale: float = float(max_edge) / float(long_edge)
		var new_w: int = int(orig_w * scale)
		var new_h: int = int(orig_h * scale)
		# duplicate before mutating — render_view_to_image returns a cached image.
		img = img.duplicate() as Image
		img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)

	# Resolve output path. Default: user://cad_snapshots/<editor>_<view>_<ts>.png.
	var output_raw: String = str(args.get("output_path", "")).strip_edges()
	var output_path: String = output_raw
	# Reject res:// — writing into the project bundle is a footgun on exported
	# projects (read-only on most platforms) and a sign of caller confusion.
	if output_path.begins_with("res://"):
		return _err(
			"snapshot: output_path under res:// is rejected (read-only on exported "
			+ "builds). Use an absolute path, ~-prefixed, or user://."
		)
	if output_path.is_empty():
		# ms suffix avoids same-second collisions between back-to-back snapshots.
		var ts: String = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
		var ms_suffix: String = str(Time.get_ticks_msec() % 1000).pad_zeros(3)
		output_path = "%s/%s_%s_%s.%s.png" % [
			_SNAPSHOT_DEFAULT_DIR,
			_sanitize_filename(editor_name),
			view_id,
			ts,
			ms_suffix,
		]
	elif output_path == "~" or output_path.begins_with("~/"):
		# Targeted tilde expansion only at the start of the path. Global replace
		# would also substitute literal `~` later in the string (e.g. backup
		# suffix `foo~`). On platforms with no HOME we leave the path alone and
		# let save_png surface the IO error rather than write to "/cad.png".
		var home: String = OS.get_environment("HOME")
		if not home.is_empty():
			output_path = home + output_path.substr(1)

	# Ensure parent dir exists. ProjectSettings.globalize_path handles both
	# user:// and absolute (no-op) paths uniformly.
	var globalized: String = ProjectSettings.globalize_path(output_path)
	var parent_dir: String = globalized.get_base_dir()
	if not parent_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(parent_dir)

	var save_err: Error = img.save_png(output_path)
	if save_err != OK:
		return _err("snapshot: failed to write PNG to %s (err=%d)" % [output_path, save_err])

	# Geometry summary (cheap — already used by minerva_cad_get_mesh_info).
	var has_geometry: bool = false
	var vertex_count: int = 0
	var face_count: int = 0
	var bbox: Variant = null
	if host.has_method("get_mesh_data"):
		var mesh: Dictionary = host.call("get_mesh_data")
		var vertices: Array = mesh.get("vertices", []) if mesh is Dictionary else []
		var faces: Array = mesh.get("faces", []) if mesh is Dictionary else []
		vertex_count = vertices.size()
		face_count = faces.size()
		has_geometry = vertex_count > 0
		if has_geometry:
			bbox = _compute_bbox(vertices)

	var result := {
		"path": output_path,
		"absolute_path": globalized,
		"width": img.get_width(),
		"height": img.get_height(),
		"view": view_id,
		"content_type": "image/png",
		"has_geometry": has_geometry,
		"vertex_count": vertex_count,
		"face_count": face_count,
		"bounding_box": bbox,
		"units": "mm",
	}

	if return_base64:
		var png_buf: PackedByteArray = img.save_png_to_buffer()
		if png_buf.is_empty():
			return _err("snapshot: failed to encode PNG buffer for base64 return")
		result["image_base64"] = Marshalls.raw_to_base64(png_buf)

	return _ok(result)


# ── Internal helpers ──────────────────────────────────────────────────────────

## Resolve editor_name → AnnotationHost via the registry.
## Returns null on missing host or missing editor_name arg.
func _resolve_host(args: Dictionary) -> AnnotationHost:
	var editor_name: String = str(args.get("editor_name", ""))
	if editor_name.is_empty():
		return null
	return AnnotationHostRegistry.get_host(editor_name)


## Build a structured error for a missing host, including known editor names.
func _no_host_error(args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", ""))
	if editor_name.is_empty():
		return _err("editor_name is required")
	var known: Array = AnnotationHostRegistry.list_editor_names()
	return _err(
		"no_cad_host_for_editor: '%s'. Known editors: %s" % [editor_name, str(known)]
	)


## Build a success response. Mirrors MCPToolUtils.success() so the module is
## self-contained and testable headlessly without the SingletonObject autoload.
static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


## Build an error response. Mirrors MCPToolUtils.error().
static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}


## Sanitize an editor name into a filesystem-safe path component. Replaces
## any character outside [A-Za-z0-9._-] with '_' so the default snapshot
## path is portable (Windows reserves : \ * ? < > | besides the obvious /).
static func _sanitize_filename(name: String) -> String:
	var out := ""
	for ch in name:
		var c: String = ch
		if (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "." or c == "_" or c == "-":
			out += c
		else:
			out += "_"
	if out.is_empty():
		out = "editor"
	return out


## Compute an axis-aligned bounding box from a vertex array.
## Each vertex is expected to be an Array of 3 floats [x, y, z].
## Returns {min: [x,y,z], max: [x,y,z]}, or null if vertices is empty.
static func _compute_bbox(vertices: Array) -> Variant:
	if vertices.is_empty():
		return null

	var min_x: float = INF
	var min_y: float = INF
	var min_z: float = INF
	var max_x: float = -INF
	var max_y: float = -INF
	var max_z: float = -INF

	for v in vertices:
		if not (v is Array) or (v as Array).size() < 3:
			continue
		var va: Array = v as Array
		var vx: float = float(va[0])
		var vy: float = float(va[1])
		var vz: float = float(va[2])
		if vx < min_x: min_x = vx
		if vy < min_y: min_y = vy
		if vz < min_z: min_z = vz
		if vx > max_x: max_x = vx
		if vy > max_y: max_y = vy
		if vz > max_z: max_z = vz

	# If no valid vertex was processed (e.g. all malformed), return null.
	if min_x == INF:
		return null

	return {
		"min": [min_x, min_y, min_z],
		"max": [max_x, max_y, max_z],
	}
