class_name MCPCadTools
extends MCPToolModule
## MCP tool module for CAD editor introspection (task 019dd2049ff6).
##
## Five read-only tools that let an AI agent answer questions about a live
## Cad_AnnotationHost without filesystem access or IPC round-trips:
##
##   cad_get_mesh_info       — geometry summary + bounding box
##   cad_list_edges_live     — full edge registry as the host holds it
##   cad_get_edge            — single edge by id
##   cad_get_selected_edge   — currently selected edge id + dict
##   cad_get_document_source — file_path, dsl_text, evaluated flag
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
		"minerva_cad_get_document_source",
		"minerva_cad_annotate_edges",
		"minerva_cad_clear_edge_annotations",
	]


func register_tools() -> void:
	server._register_tool(
		"minerva_cad_get_mesh_info",
		"Return geometry summary for a live CAD editor: vertex count, face count, "
		+ "axis-aligned bounding box, and whether any geometry exists. "
		+ "Bounding box coordinates are in millimetres (CAD always uses mm). "
		+ "has_geometry is false when the panel has not yet evaluated any DSL source. "
		+ "Use cad_get_document_source to check what DSL is loaded.",
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
		"minerva_cad_get_document_source",
		"Return the DSL source text and file path for a live CAD editor. "
		+ "file_path is null or empty when the panel was opened without a file. "
		+ "dsl_text is null or empty when no source has been loaded yet. "
		+ "evaluated is true when the panel has mesh geometry (i.e. cad_get_mesh_info "
		+ "would return has_geometry: true). "
		+ "Use this to answer 'what is the user editing?' without filesystem access.",
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
		"minerva_cad_get_document_source":
			return _cad_get_document_source(arguments)
		"minerva_cad_annotate_edges":
			return _cad_annotate_edges(arguments)
		"minerva_cad_clear_edge_annotations":
			return _cad_clear_edge_annotations(arguments)
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


func _cad_get_document_source(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_document_source"):
		return _err(
			"cad_get_document_source: host for '%s' does not expose get_document_source."
			% str(args.get("editor_name", ""))
		)

	if not host.has_method("get_mesh_data"):
		return _err(
			"cad_get_document_source: host for '%s' does not expose get_mesh_data."
			% str(args.get("editor_name", ""))
		)

	var source: Dictionary = host.call("get_document_source")
	var file_path: Variant = source.get("file_path", null)
	var dsl_text: Variant = source.get("dsl_text", null)

	# Normalise empty strings to null so callers can do a simple null check.
	if file_path is String and (file_path as String).is_empty():
		file_path = null
	if dsl_text is String and (dsl_text as String).is_empty():
		dsl_text = null

	# evaluated == has any mesh geometry been produced.
	var mesh: Dictionary = host.call("get_mesh_data")
	var vertices: Array = mesh.get("vertices", []) if mesh is Dictionary else []
	var evaluated: bool = vertices.size() > 0

	return _ok({
		"file_path": file_path,
		"dsl_text": dsl_text,
		"evaluated": evaluated,
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

		var edge_dict: Dictionary = edge_lookup[edge_id] as Dictionary

		# Compute midpoint from edge geometry.
		var midpoint: Array = _edge_midpoint(edge_dict)

		# Build label.
		var label: String = ""
		if label_format_override != null and str(label_format_override) != "":
			label = str(label_format_override)
		else:
			label = str(edge_id)

		# Build annotation envelope.
		# Bug 019dd65c237d resolved by Round 2b-α Unit 1: the AnnotationCanvas is
		# now parented to a full-rect overlay above all 4 SubViewportContainers,
		# and viewport_rect offsets are applied per-pane in cad_edge_number_kind.
		# visible_in_views defaults to all 4 panes (no metadata restriction needed).
		var annotation: Dictionary = {
			"kind": "cad_edge_number",
			"payload": {
				"edge_id": edge_id,
				"label": label,
				"group_id": group_id,
			},
			"primitives": [
				{"type": "point", "at": midpoint},
			],
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


## Compute the 3-D midpoint of an edge dict from the registry.
## Returns [x, y, z] as a float array.
##
## For straight edges: midpoint = (start + end) / 2.
## For circle edges:   midpoint = center.
## Fallback: [0, 0, 0] when geometry fields are absent.
static func _edge_midpoint(edge_dict: Dictionary) -> Array:
	var kind: String = str(edge_dict.get("kind", ""))
	if kind == "circle":
		var center: Variant = edge_dict.get("center", null)
		if center is Array and (center as Array).size() >= 3:
			var ca: Array = center as Array
			return [float(ca[0]), float(ca[1]), float(ca[2])]
		return [0.0, 0.0, 0.0]

	# Straight (or unknown kind): use (start + end) / 2.
	var start: Variant = edge_dict.get("start", null)
	var end_pt: Variant = edge_dict.get("end", null)
	if start is Array and (start as Array).size() >= 3 and end_pt is Array and (end_pt as Array).size() >= 3:
		var sa: Array = start as Array
		var ea: Array = end_pt as Array
		return [
			(float(sa[0]) + float(ea[0])) * 0.5,
			(float(sa[1]) + float(ea[1])) * 0.5,
			(float(sa[2]) + float(ea[2])) * 0.5,
		]
	return [0.0, 0.0, 0.0]
