extends SceneTree
## Unit tests for MCPCadTools — read-only CAD MCP introspection surface.
## Task: 019dd2049ff6
##
## Run: godot --headless --path src --script test/test_mcp_cad_tools.gd
##
## Coverage:
##   cad_get_mesh_info: empty host → has_geometry=false, vertex/face count=0, bbox=null
##   cad_get_mesh_info: populated host → correct counts, bbox covers extent, has_geometry=true
##   cad_get_mesh_info: missing host → ok=false, error contains editor name
##   cad_list_edges_live: returns exact edge array the host holds
##   cad_list_edges_live: missing host → ok=false
##   cad_get_edge: hit returns correct dict
##   cad_get_edge: miss returns edge=null, ok=true (not an error)
##   cad_get_edge: missing host → ok=false
##   cad_get_selected_edge: no selection → selected_edge_id=-1, edge=null
##   cad_get_selected_edge: selection set → id+dict echoed
##   cad_get_selected_edge: missing host → ok=false
##   cad_get_document_source: empty host → file_path=null, dsl_text=null, evaluated=false
##   cad_get_document_source: populated host → echoes what panel set, evaluated=true when mesh present
##   cad_get_document_source: missing host → ok=false
##   editor_name missing → ok=false

## Preload is required for newly-added scripts that don't yet have a .uid file
## in the project cache. class_name resolution depends on uid indexing which only
## happens after the Godot editor imports the script; preload works without it.
const MCPCadToolsScript := preload("res://Scripts/Services/MCP/Modules/MCPCadTools.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== MCPCadTools Tests ===\n")

	# MCPCadTools.new(null) — server=null is fine; register_tools() is not called
	# in these tests (it requires a live server). handle() has no server dependency.
	var tools = MCPCadToolsScript.new(null)

	print("-- cad_get_mesh_info: empty host --")
	test_mesh_info_empty_host(tools)

	print("\n-- cad_get_mesh_info: populated host --")
	test_mesh_info_populated(tools)

	print("\n-- cad_get_mesh_info: missing host --")
	test_mesh_info_missing_host(tools)

	print("\n-- cad_get_mesh_info: missing editor_name --")
	test_missing_editor_name(tools, "minerva_cad_get_mesh_info")

	print("\n-- cad_list_edges_live: empty edges --")
	test_list_edges_empty(tools)

	print("\n-- cad_list_edges_live: populated edges --")
	test_list_edges_populated(tools)

	print("\n-- cad_list_edges_live: missing host --")
	test_list_edges_missing_host(tools)

	print("\n-- cad_get_edge: hit --")
	test_get_edge_hit(tools)

	print("\n-- cad_get_edge: miss --")
	test_get_edge_miss(tools)

	print("\n-- cad_get_edge: missing host --")
	test_get_edge_missing_host(tools)

	print("\n-- cad_get_selected_edge: no selection --")
	test_selected_edge_none(tools)

	print("\n-- cad_get_selected_edge: with selection --")
	test_selected_edge_set(tools)

	print("\n-- cad_get_selected_edge: missing host --")
	test_selected_edge_missing_host(tools)

	print("\n-- cad_get_document_source: empty host --")
	test_document_source_empty(tools)

	print("\n-- cad_get_document_source: populated, not yet evaluated --")
	test_document_source_set_no_mesh(tools)

	print("\n-- cad_get_document_source: populated + mesh present --")
	test_document_source_set_with_mesh(tools)

	print("\n-- cad_get_document_source: missing host --")
	test_document_source_missing_host(tools)

	print("\n-- cad_annotate_edges: happy path --")
	test_annotate_edges_happy(tools)

	print("\n-- cad_annotate_edges: user-supplied group_id --")
	test_annotate_edges_user_group_id(tools)

	print("\n-- cad_annotate_edges: skipped unknown ids --")
	test_annotate_edges_skipped_unknown(tools)

	print("\n-- cad_annotate_edges: tags_any filter --")
	test_annotate_edges_tags_any_filter(tools)

	print("\n-- cad_annotate_edges: requires selector --")
	test_annotate_edges_requires_selector(tools)

	print("\n-- cad_annotate_edges: rejects both selectors --")
	test_annotate_edges_rejects_both_selectors(tools)

	print("\n-- cad_clear_edge_annotations: clear by group_id --")
	test_clear_by_group_id(tools)

	print("\n-- cad_clear_edge_annotations: clear all=true --")
	test_clear_all_true(tools)

	print("\n-- cad_clear_edge_annotations: requires predicate --")
	test_clear_requires_predicate(tools)

	print("\n-- cad_clear_edge_annotations: no match returns zero --")
	test_clear_no_match_returns_zero(tools)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Fake host ─────────────────────────────────────────────────────────────────
## Stands in for Cad_AnnotationHost. Extends the platform AnnotationHost base
## (the type the registry stores) and implements the new MCP getter/setter API
## with the same method signatures the real class uses.
##
## MCPCadTools uses duck typing (has_method / call) for the CAD-specific
## methods, so this class is the correct test double.
class _FakeCadHost extends AnnotationHost:
	var _mesh_data: Dictionary = {}
	var _edge_registry_data: Array = []
	var _selected_edge_id: int = -1
	var _document_file_path: String = ""
	var _document_dsl_text: String = ""

	# ── AnnotationHost required virtuals (minimal stubs) ──────────────────────
	func get_registry() -> AnnotationRegistry:
		return null

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p

	func get_view_context() -> String:
		return "cad:iso"

	func describe_point(_doc_pos: Vector2) -> String:
		return ""

	func render_content_to_image(_viewport_rect: Rect2) -> Image:
		return null

	# ── CAD introspection API (mirrors Cad_AnnotationHost new methods) ────────
	func set_mesh_data(mesh: Dictionary) -> void:
		_mesh_data = mesh

	func get_mesh_data() -> Dictionary:
		return _mesh_data

	func set_edge_registry(edges: Array) -> void:
		_edge_registry_data = edges

	func get_edge_registry() -> Array:
		return _edge_registry_data

	func set_selected_edge_id(edge_id: int) -> void:
		_selected_edge_id = edge_id

	func get_selected_edge_id() -> int:
		return _selected_edge_id

	func set_document_source(file_path: String, dsl_text: String) -> void:
		_document_file_path = file_path
		_document_dsl_text = dsl_text

	func get_document_source() -> Dictionary:
		return {"file_path": _document_file_path, "dsl_text": _document_dsl_text}

	# ── Annotation store (for annotation tool tests) ──────────────────────────
	var _stored_annotations: Array = []  # Array[Dictionary]
	var _next_ann_id: int = 1

	func add_annotation(annotation: Dictionary) -> String:
		var stored: Dictionary = annotation.duplicate(true)
		var id: String = str(stored.get("id", ""))
		if id.is_empty():
			id = "ann_%04d" % _next_ann_id
			_next_ann_id += 1
		stored["id"] = id
		_stored_annotations.append(stored)
		return id

	func remove_annotation(annotation_id: String) -> bool:
		for i in range(_stored_annotations.size()):
			var entry: Dictionary = _stored_annotations[i] as Dictionary
			if str(entry.get("id", "")) == annotation_id:
				_stored_annotations.remove_at(i)
				return true
		return false

	func get_annotations() -> Array:
		return _stored_annotations.duplicate()


# ── Test helpers ──────────────────────────────────────────────────────────────

## Register a fake host under `editor_name` and return it.
func _make_host(editor_name: String) -> _FakeCadHost:
	AnnotationHostRegistry._reset_for_test()
	var h := _FakeCadHost.new()
	AnnotationHostRegistry.register(editor_name, h)
	return h


## 3-vertex, 1-face canned mesh covering a known bounding box.
## min = [-1, -2, -3], max = [4, 5, 6].
func _canned_mesh() -> Dictionary:
	return {
		"vertices": [
			[-1.0, -2.0, -3.0],
			[4.0, 5.0, 6.0],
			[2.0, 0.0, 1.0],
		],
		"faces": [[0, 1, 2]],
	}


## Two canned edges — one straight, one circle.
func _canned_edges() -> Array:
	return [
		{"id": 1, "kind": "straight", "length": 12.5},
		{"id": 2, "kind": "circle",   "radius": 3.0},
	]


# ── cad_get_mesh_info tests ───────────────────────────────────────────────────

func test_mesh_info_empty_host(tools) -> void:
	var h := _make_host("MyCAD")
	# host has no mesh — default _mesh_data is {}
	var result: Dictionary = tools.handle("minerva_cad_get_mesh_info", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	check("has_geometry=false", bool(result.get("has_geometry", true)) == false)
	check_eq("vertex_count=0", result.get("vertex_count", -1), 0)
	check_eq("face_count=0", result.get("face_count", -1), 0)
	check("bounding_box=null", result.get("bounding_box", "NOT_NULL") == null)
	check_eq("units=mm", result.get("units", ""), "mm")
	AnnotationHostRegistry._reset_for_test()


func test_mesh_info_populated(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_mesh_data(_canned_mesh())
	var result: Dictionary = tools.handle("minerva_cad_get_mesh_info", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	check("has_geometry=true", bool(result.get("has_geometry", false)) == true)
	check_eq("vertex_count=3", result.get("vertex_count", -1), 3)
	check_eq("face_count=1", result.get("face_count", -1), 1)
	# Bounding box present and covers canned extent.
	var bbox: Variant = result.get("bounding_box", null)
	check("bbox not null", bbox != null)
	if bbox != null and bbox is Dictionary:
		var bmin: Array = bbox.get("min", [])
		var bmax: Array = bbox.get("max", [])
		check("bbox.min[0]=-1", bmin.size() > 0 and absf(float(bmin[0]) - (-1.0)) < 0.001)
		check("bbox.min[1]=-2", bmin.size() > 1 and absf(float(bmin[1]) - (-2.0)) < 0.001)
		check("bbox.min[2]=-3", bmin.size() > 2 and absf(float(bmin[2]) - (-3.0)) < 0.001)
		check("bbox.max[0]=4", bmax.size() > 0 and absf(float(bmax[0]) - 4.0) < 0.001)
		check("bbox.max[1]=5", bmax.size() > 1 and absf(float(bmax[1]) - 5.0) < 0.001)
		check("bbox.max[2]=6", bmax.size() > 2 and absf(float(bmax[2]) - 6.0) < 0.001)
	AnnotationHostRegistry._reset_for_test()


func test_mesh_info_missing_host(tools) -> void:
	AnnotationHostRegistry._reset_for_test()
	var result: Dictionary = tools.handle("minerva_cad_get_mesh_info", {"editor_name": "NoSuchEditor"})
	check("success=false for missing host", bool(result.get("success", true)) == false)
	check("error contains editor name",
		str(result.get("error", "")).contains("NoSuchEditor"))


# ── Missing editor_name test (shared) ─────────────────────────────────────────

func test_missing_editor_name(tools, tool_name: String) -> void:
	AnnotationHostRegistry._reset_for_test()
	var result: Dictionary = tools.handle(tool_name, {})
	check("success=false when editor_name absent", bool(result.get("success", true)) == false)


# ── cad_list_edges_live tests ─────────────────────────────────────────────────

func test_list_edges_empty(tools) -> void:
	var h := _make_host("MyCAD")
	var result: Dictionary = tools.handle("minerva_cad_list_edges_live", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	var edges: Variant = result.get("edges", null)
	check("edges is Array", edges is Array)
	check("edges is empty", (edges as Array).is_empty())
	AnnotationHostRegistry._reset_for_test()


func test_list_edges_populated(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_canned_edges())
	var result: Dictionary = tools.handle("minerva_cad_list_edges_live", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	var edges: Variant = result.get("edges", null)
	check("edges is Array", edges is Array)
	check("two edges returned", (edges as Array).size() == 2)
	# Verify exact dict shape preserved — no transformation.
	var ea: Array = edges as Array
	check("first edge id=1", ea.size() > 0 and int((ea[0] as Dictionary).get("id", -1)) == 1)
	check("first edge kind=straight", ea.size() > 0 and str((ea[0] as Dictionary).get("kind", "")) == "straight")
	check("second edge id=2", ea.size() > 1 and int((ea[1] as Dictionary).get("id", -1)) == 2)
	check("second edge kind=circle", ea.size() > 1 and str((ea[1] as Dictionary).get("kind", "")) == "circle")
	AnnotationHostRegistry._reset_for_test()


func test_list_edges_missing_host(tools) -> void:
	AnnotationHostRegistry._reset_for_test()
	var result: Dictionary = tools.handle("minerva_cad_list_edges_live", {"editor_name": "Ghost"})
	check("success=false for missing host", bool(result.get("success", true)) == false)


# ── cad_get_edge tests ────────────────────────────────────────────────────────

func test_get_edge_hit(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_canned_edges())
	var result: Dictionary = tools.handle("minerva_cad_get_edge", {"editor_name": "MyCAD", "edge_id": 2})
	check("success=true", bool(result.get("success", false)) == true)
	var edge: Variant = result.get("edge", null)
	check("edge not null", edge != null)
	if edge != null and edge is Dictionary:
		check("edge id=2", int((edge as Dictionary).get("id", -1)) == 2)
		check("edge kind=circle", str((edge as Dictionary).get("kind", "")) == "circle")
	AnnotationHostRegistry._reset_for_test()


func test_get_edge_miss(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_canned_edges())
	var result: Dictionary = tools.handle("minerva_cad_get_edge", {"editor_name": "MyCAD", "edge_id": 999})
	check("success=true for miss", bool(result.get("success", false)) == true)
	check("edge=null for miss", result.get("edge", "NOT_NULL") == null)
	AnnotationHostRegistry._reset_for_test()


func test_get_edge_missing_host(tools) -> void:
	AnnotationHostRegistry._reset_for_test()
	var result: Dictionary = tools.handle("minerva_cad_get_edge", {"editor_name": "Ghost", "edge_id": 1})
	check("success=false for missing host", bool(result.get("success", true)) == false)


# ── cad_get_selected_edge tests ───────────────────────────────────────────────

func test_selected_edge_none(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_canned_edges())
	# Default selected_edge_id is -1.
	var result: Dictionary = tools.handle("minerva_cad_get_selected_edge", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	check_eq("selected_edge_id=-1", result.get("selected_edge_id", 0), -1)
	check("edge=null when no selection", result.get("edge", "NOT_NULL") == null)
	AnnotationHostRegistry._reset_for_test()


func test_selected_edge_set(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_canned_edges())
	h.set_selected_edge_id(1)
	var result: Dictionary = tools.handle("minerva_cad_get_selected_edge", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	check_eq("selected_edge_id=1", result.get("selected_edge_id", -1), 1)
	var edge: Variant = result.get("edge", null)
	check("edge dict present", edge != null)
	if edge != null and edge is Dictionary:
		check("edge id=1", int((edge as Dictionary).get("id", -1)) == 1)
	AnnotationHostRegistry._reset_for_test()


func test_selected_edge_missing_host(tools) -> void:
	AnnotationHostRegistry._reset_for_test()
	var result: Dictionary = tools.handle("minerva_cad_get_selected_edge", {"editor_name": "Ghost"})
	check("success=false for missing host", bool(result.get("success", true)) == false)


# ── cad_get_document_source tests ─────────────────────────────────────────────

func test_document_source_empty(tools) -> void:
	var h := _make_host("MyCAD")
	var result: Dictionary = tools.handle("minerva_cad_get_document_source", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	check("file_path=null when not set", result.get("file_path", "NOT_NULL") == null)
	check("dsl_text=null when not set", result.get("dsl_text", "NOT_NULL") == null)
	check("evaluated=false", bool(result.get("evaluated", true)) == false)
	AnnotationHostRegistry._reset_for_test()


func test_document_source_set_no_mesh(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_document_source("/home/user/box.mcad", "import build123d as bd\nb = bd.Box(10,10,10)")
	# No mesh pushed → evaluated=false.
	var result: Dictionary = tools.handle("minerva_cad_get_document_source", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	check_eq("file_path echoed", result.get("file_path", ""), "/home/user/box.mcad")
	check("dsl_text non-null", result.get("dsl_text", null) != null)
	check("dsl_text contains Box", str(result.get("dsl_text", "")).contains("Box"))
	check("evaluated=false (no mesh)", bool(result.get("evaluated", true)) == false)
	AnnotationHostRegistry._reset_for_test()


func test_document_source_set_with_mesh(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_document_source("/home/user/box.mcad", "import build123d as bd\nb = bd.Box(10,10,10)")
	h.set_mesh_data(_canned_mesh())
	var result: Dictionary = tools.handle("minerva_cad_get_document_source", {"editor_name": "MyCAD"})
	check("success=true", bool(result.get("success", false)) == true)
	check("evaluated=true (mesh present)", bool(result.get("evaluated", false)) == true)
	AnnotationHostRegistry._reset_for_test()


func test_document_source_missing_host(tools) -> void:
	AnnotationHostRegistry._reset_for_test()
	var result: Dictionary = tools.handle("minerva_cad_get_document_source", {"editor_name": "Ghost"})
	check("success=false for missing host", bool(result.get("success", true)) == false)


# ── cad_annotate_edges tests ──────────────────────────────────────────────────

## Five-edge registry used by annotation tests.
## Edges 1-5 as straight edges with known start/end so midpoint is computable.
func _annotation_edges() -> Array:
	return [
		{"id": 1, "kind": "straight", "length": 10.0, "start": [0.0, 0.0, 0.0], "end": [2.0, 0.0, 0.0], "tags": []},
		{"id": 2, "kind": "straight", "length": 10.0, "start": [0.0, 1.0, 0.0], "end": [2.0, 1.0, 0.0], "tags": []},
		{"id": 3, "kind": "straight", "length": 10.0, "start": [0.0, 2.0, 0.0], "end": [2.0, 2.0, 0.0], "tags": []},
		{"id": 4, "kind": "straight", "length": 10.0, "start": [0.0, 3.0, 0.0], "end": [2.0, 3.0, 0.0], "tags": []},
		{"id": 5, "kind": "straight", "length": 10.0, "start": [0.0, 4.0, 0.0], "end": [2.0, 4.0, 0.0], "tags": []},
	]


func test_annotate_edges_happy(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	var result: Dictionary = tools.handle(
		"minerva_cad_annotate_edges",
		{"editor_name": "MyCAD", "edge_ids": [1, 2, 3]}
	)
	check("success=true", bool(result.get("success", false)) == true)
	var created: Variant = result.get("created_edge_ids", null)
	check("created_edge_ids is Array", created is Array)
	check("3 annotations created", created is Array and (created as Array).size() == 3)
	var group_id: String = str(result.get("group_id", ""))
	check("group_id minted (non-empty)", not group_id.is_empty())
	check("group_id starts with cad_edge_grp_", group_id.begins_with("cad_edge_grp_"))
	var skipped: Variant = result.get("skipped_unknown_ids", null)
	check("skipped_unknown_ids is Array", skipped is Array)
	check("no skipped ids", skipped is Array and (skipped as Array).is_empty())
	check("3 annotations stored on host", h.get_annotations().size() == 3)
	# Each stored annotation must have kind = cad_edge_number and the group_id in payload.
	var all_ann: Array = h.get_annotations()
	var all_have_kind := true
	var all_have_group := true
	for ann in all_ann:
		if str((ann as Dictionary).get("kind", "")) != "cad_edge_number":
			all_have_kind = false
		var payload: Dictionary = (ann as Dictionary).get("payload", {}) as Dictionary
		if str(payload.get("group_id", "")) != group_id:
			all_have_group = false
	check("all annotations have kind=cad_edge_number", all_have_kind)
	check("all annotations carry minted group_id", all_have_group)
	AnnotationHostRegistry._reset_for_test()


func test_annotate_edges_user_group_id(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	var result: Dictionary = tools.handle(
		"minerva_cad_annotate_edges",
		{"editor_name": "MyCAD", "edge_ids": [1, 2], "group_id": "my-group"}
	)
	check("success=true", bool(result.get("success", false)) == true)
	check("returned group_id matches", str(result.get("group_id", "")) == "my-group")
	var all_ann: Array = h.get_annotations()
	var all_correct := true
	for ann in all_ann:
		var payload: Dictionary = (ann as Dictionary).get("payload", {}) as Dictionary
		if str(payload.get("group_id", "")) != "my-group":
			all_correct = false
	check("all annotations carry user group_id", all_correct)
	AnnotationHostRegistry._reset_for_test()


func test_annotate_edges_skipped_unknown(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	var result: Dictionary = tools.handle(
		"minerva_cad_annotate_edges",
		{"editor_name": "MyCAD", "edge_ids": [1, 99]}
	)
	check("success=true", bool(result.get("success", false)) == true)
	var created: Variant = result.get("created_edge_ids", null)
	check("1 annotation created", created is Array and (created as Array).size() == 1)
	check("created edge is id=1", created is Array and int((created as Array)[0]) == 1)
	var skipped: Variant = result.get("skipped_unknown_ids", null)
	check("1 skipped id", skipped is Array and (skipped as Array).size() == 1)
	check("skipped id is 99", skipped is Array and int((skipped as Array)[0]) == 99)
	AnnotationHostRegistry._reset_for_test()


func test_annotate_edges_tags_any_filter(tools) -> void:
	var h := _make_host("MyCAD")
	# Edges with explicit tags for filtering.
	h.set_edge_registry([
		{"id": 1, "kind": "straight", "start": [0.0, 0.0, 0.0], "end": [1.0, 0.0, 0.0], "tags": ["outer"]},
		{"id": 2, "kind": "straight", "start": [0.0, 1.0, 0.0], "end": [1.0, 1.0, 0.0], "tags": ["inner"]},
		{"id": 3, "kind": "straight", "start": [0.0, 2.0, 0.0], "end": [1.0, 2.0, 0.0], "tags": ["outer", "feature"]},
	])
	var result: Dictionary = tools.handle(
		"minerva_cad_annotate_edges",
		{"editor_name": "MyCAD", "tags_any": ["outer"]}
	)
	check("success=true", bool(result.get("success", false)) == true)
	var created: Variant = result.get("created_edge_ids", null)
	check("2 annotations created (edges 1 and 3)", created is Array and (created as Array).size() == 2)
	if created is Array and (created as Array).size() == 2:
		var ca: Array = created as Array
		var ids_set: Array = [int(ca[0]), int(ca[1])]
		ids_set.sort()
		check("created ids are [1, 3]", ids_set == [1, 3])
	check("edge 2 (inner) not annotated", h.get_annotations().size() == 2)
	AnnotationHostRegistry._reset_for_test()


func test_annotate_edges_requires_selector(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	var result: Dictionary = tools.handle(
		"minerva_cad_annotate_edges",
		{"editor_name": "MyCAD"}
	)
	check("success=false when no selector", bool(result.get("success", true)) == false)
	check("error message present", str(result.get("error", "")).length() > 0)
	AnnotationHostRegistry._reset_for_test()


func test_annotate_edges_rejects_both_selectors(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	var result: Dictionary = tools.handle(
		"minerva_cad_annotate_edges",
		{"editor_name": "MyCAD", "edge_ids": [1], "tags_any": ["outer"]}
	)
	check("success=false when both selectors given", bool(result.get("success", true)) == false)
	check("error message present", str(result.get("error", "")).length() > 0)
	AnnotationHostRegistry._reset_for_test()


# ── cad_clear_edge_annotations tests ─────────────────────────────────────────

## Helper: annotate a set of edge_ids under a given group_id, return the host.
func _annotate_group(tools, h: _FakeCadHost, edge_ids: Array, group_id: String) -> void:
	tools.handle(
		"minerva_cad_annotate_edges",
		{"editor_name": "MyCAD", "edge_ids": edge_ids, "group_id": group_id}
	)


func test_clear_by_group_id(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	_annotate_group(tools, h, [1, 2, 3], "group-A")
	_annotate_group(tools, h, [4, 5], "group-B")
	check("5 total before clear", h.get_annotations().size() == 5)

	var result: Dictionary = tools.handle(
		"minerva_cad_clear_edge_annotations",
		{"editor_name": "MyCAD", "group_id": "group-A"}
	)
	check("success=true", bool(result.get("success", false)) == true)
	check("cleared_count=3", int(result.get("cleared_count", -1)) == 3)
	check("2 annotations remain (group-B)", h.get_annotations().size() == 2)
	# Verify remaining annotations are all group-B.
	var remaining: Array = h.get_annotations()
	var all_b := true
	for ann in remaining:
		var payload: Dictionary = (ann as Dictionary).get("payload", {}) as Dictionary
		if str(payload.get("group_id", "")) != "group-B":
			all_b = false
	check("remaining annotations are all group-B", all_b)
	AnnotationHostRegistry._reset_for_test()


func test_clear_all_true(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	_annotate_group(tools, h, [1, 2, 3], "group-X")
	_annotate_group(tools, h, [4, 5], "group-Y")
	check("5 total before clear", h.get_annotations().size() == 5)

	var result: Dictionary = tools.handle(
		"minerva_cad_clear_edge_annotations",
		{"editor_name": "MyCAD", "all": true}
	)
	check("success=true", bool(result.get("success", false)) == true)
	check("cleared_count=5", int(result.get("cleared_count", -1)) == 5)
	check("0 annotations remain", h.get_annotations().is_empty())
	AnnotationHostRegistry._reset_for_test()


func test_clear_requires_predicate(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	var result: Dictionary = tools.handle(
		"minerva_cad_clear_edge_annotations",
		{"editor_name": "MyCAD"}
	)
	check("success=false when no predicate", bool(result.get("success", true)) == false)
	check("error message present", str(result.get("error", "")).length() > 0)
	AnnotationHostRegistry._reset_for_test()


func test_clear_no_match_returns_zero(tools) -> void:
	var h := _make_host("MyCAD")
	h.set_edge_registry(_annotation_edges())
	_annotate_group(tools, h, [1, 2], "group-A")

	var result: Dictionary = tools.handle(
		"minerva_cad_clear_edge_annotations",
		{"editor_name": "MyCAD", "group_id": "does-not-exist"}
	)
	check("success=true (not an error)", bool(result.get("success", false)) == true)
	check("cleared_count=0", int(result.get("cleared_count", -1)) == 0)
	check("annotations unchanged", h.get_annotations().size() == 2)
	AnnotationHostRegistry._reset_for_test()
