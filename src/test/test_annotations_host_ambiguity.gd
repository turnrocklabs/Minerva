extends SceneTree
## Regression coverage for bug 019f6b9221b6 + the host-resolution ambiguity
## described in its comment #531.
##
## Run: godot --headless --path src --script test/test_annotations_host_ambiguity.gd
##
## LIVE SHAPE reproduced (docket bugs minerva:019f6b9221b6): minerva_annotations_add
## with a FILE-BACKED plugin editor's editor_name returned {"success":true,"id":"",
## "ref":"C74", ...} — a fabricated success for an annotation that was never
## stored — and annotations_list on the same editor_name showed count 0.
## Existing suites (e.g. test_pcb_workflow_kinds' E2E-5A) never catch this because
## their test hosts register unambiguously, one host per editor_name. This suite
## specifically registers TWO competing hosts under the SAME editor_name — a
## generic buffer-canonical text host and a plugin panel host — the way the live
## app can (a text-document host for the file buffer and a plugin panel host both
## binding to the same tab title) and proves:
##   1. Resolution ambiguity: AnnotationHostRegistry's panel-host-priority policy
##      makes annotations_add / annotations_list resolve the SAME (panel) host
##      regardless of which order the two hosts registered in.
##   2. Swallowed empty-id: a host that rejects a write (add_annotation() returns
##      "") never produces a fabricated success echo — MCPAnnotationTools returns
##      a structured error instead.
##
## Zero pcb vocabulary: the "panel" host below is a generic stand-in (document
## kind "widget") for any plugin-contributed AnnotationHost — pcb's
## PcbAnnotationHost is one concrete example, not a dependency of this test.

var _pass_count: int = 0
var _fail_count: int = 0


func _initialize() -> void:
	print("=== Annotation Host Ambiguity Tests (bug 019f6b9221b6) ===\n")

	var tools := MCPAnnotationTools.new(null)

	print("-- resolution ambiguity: panel host wins regardless of registration order --")
	await test_panel_host_wins_text_registered_first(tools)
	await test_panel_host_wins_panel_registered_first(tools)

	print("\n-- resolution ambiguity: add and list agree on the same host --")
	await test_add_and_list_resolve_same_host(tools)

	print("\n-- swallowed empty id: host rejection never fabricates success --")
	await test_empty_id_add_returns_structured_error(tools)
	await test_empty_id_add_does_not_leak_ref_or_echo(tools)

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


# ── Stub kind: a generic plugin-contributed annotation kind ──────────────────
# Stands in for any plugin-registered kind (e.g. pcb's pcb_route_hint) that
# lives ONLY in the panel host's own registry, never in a generic text host's.

class _StubWidgetKind extends AnnotationKind:
	func _init() -> void:
		name = &"widget_marker"
		display_name = "Widget Marker"
		owning_plugin = &"widget"
		primitives_optional = true

	func accepted_anchor_types() -> Array:
		return ["*/*"]

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()


# ── Stub hosts ─────────────────────────────────────────────────────────────────

## Generic buffer-canonical text host stand-in. Its registry only knows core
## kinds — it has never heard of "widget_marker", mirroring how
## TextEditorAnnotationHost's private registry never has a plugin's kinds.
class _StubTextHost extends AnnotationHost:
	var _annotations: Array = []
	var _registry: AnnotationRegistry = null
	var _next_id: int = 0

	func _init() -> void:
		_registry = AnnotationRegistry.new()
		BuiltinKinds.register_all(_registry)

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_document_identity() -> Dictionary:
		return {"kind": "text", "path": "", "display_name": "Text", "save_policy": "sidecar"}

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func add_annotation(annotation: Dictionary) -> String:
		_next_id += 1
		var stored: Dictionary = annotation.duplicate(true)
		stored["id"] = "ann_text_%d" % _next_id
		_annotations.append(stored)
		return stored["id"]

	func update_annotation(_annotation_id: String, _new_annotation: Dictionary) -> bool:
		return false

	func remove_annotation(_annotation_id: String) -> bool:
		return false


## Plugin panel host stand-in (generic — "widget", not pcb). Its registry
## carries core kinds PLUS the plugin's own kind, matching how a real plugin
## host (e.g. PcbAnnotationHost) layers its domain kind on top of BuiltinKinds.
class _StubPanelHost extends AnnotationHost:
	var _annotations: Array = []
	var _registry: AnnotationRegistry = null
	var _next_id: int = 0

	func _init() -> void:
		_registry = AnnotationRegistry.new()
		BuiltinKinds.register_all(_registry)
		_registry.register_annotation_kind(_StubWidgetKind.new())

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_document_identity() -> Dictionary:
		return {"kind": "widget", "path": "", "display_name": "Widget", "save_policy": "sidecar"}

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func add_annotation(annotation: Dictionary) -> String:
		_next_id += 1
		var stored: Dictionary = annotation.duplicate(true)
		stored["id"] = "ann_panel_%d" % _next_id
		_annotations.append(stored)
		return stored["id"]

	func update_annotation(_annotation_id: String, _new_annotation: Dictionary) -> bool:
		return false

	func remove_annotation(_annotation_id: String) -> bool:
		return false


## A host whose add_annotation() ALWAYS returns "" — the shape of a host that
## rejects a write internally (e.g. AnnotationV2Schema.validate_with_registry
## found the anchor incompatible with the kind) without raising an engine
## error. Its registry knows the kind, so the MCP-layer pre-checks
## (registry.has_kind / dispatch_validate) pass — exactly the live symptom
## ("why did kind validation pass?").
class _StubRejectingHost extends AnnotationHost:
	var _registry: AnnotationRegistry = null

	func _init() -> void:
		_registry = AnnotationRegistry.new()
		BuiltinKinds.register_all(_registry)
		_registry.register_annotation_kind(_StubWidgetKind.new())

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_document_identity() -> Dictionary:
		return {"kind": "widget", "path": "", "display_name": "Widget", "save_policy": "sidecar"}

	func get_annotations() -> Array:
		return []

	func add_annotation(_annotation: Dictionary) -> String:
		return ""

	func update_annotation(_annotation_id: String, _new_annotation: Dictionary) -> bool:
		return false

	func remove_annotation(_annotation_id: String) -> bool:
		return false


func _widget_annotation() -> Dictionary:
	return {
		"kind": "widget_marker",
		"view_context": "widget",
	}


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_panel_host_wins_text_registered_first(tools: MCPAnnotationTools) -> void:
	print("test_panel_host_wins_text_registered_first:")
	AnnotationHostRegistry._reset_for_test()
	var text_host := _StubTextHost.new()
	var panel_host := _StubPanelHost.new()
	# Live order: the buffer-canonical text host registers first (synchronous,
	# on tab creation); the plugin panel host mounts and registers afterwards
	# (its own hook runs later/deferred).
	AnnotationHostRegistry.register("shared.widget", text_host)
	AnnotationHostRegistry.register("shared.widget", panel_host)

	var result := await tools.handle("minerva_annotations_add", {
		"editor_name": "shared.widget",
		"annotation": _widget_annotation(),
	})
	check("add succeeds", bool(result.get("success", false)))
	check("id is non-empty", not str(result.get("id", "")).is_empty())
	check("annotation landed in the PANEL host", panel_host.get_annotations().size() == 1)
	check("annotation did NOT land in the text host", text_host.get_annotations().size() == 0)
	AnnotationHostRegistry._reset_for_test()


func test_panel_host_wins_panel_registered_first(tools: MCPAnnotationTools) -> void:
	print("test_panel_host_wins_panel_registered_first:")
	AnnotationHostRegistry._reset_for_test()
	var panel_host := _StubPanelHost.new()
	var text_host := _StubTextHost.new()
	# Reverse order — the fix must not depend on arrival order.
	AnnotationHostRegistry.register("shared.widget", panel_host)
	AnnotationHostRegistry.register("shared.widget", text_host)

	var result := await tools.handle("minerva_annotations_add", {
		"editor_name": "shared.widget",
		"annotation": _widget_annotation(),
	})
	check("add succeeds", bool(result.get("success", false)))
	check("annotation landed in the PANEL host", panel_host.get_annotations().size() == 1)
	check("annotation did NOT land in the text host", text_host.get_annotations().size() == 0)
	AnnotationHostRegistry._reset_for_test()


func test_add_and_list_resolve_same_host(tools: MCPAnnotationTools) -> void:
	print("test_add_and_list_resolve_same_host:")
	AnnotationHostRegistry._reset_for_test()
	var text_host := _StubTextHost.new()
	var panel_host := _StubPanelHost.new()
	AnnotationHostRegistry.register("shared.widget", text_host)
	AnnotationHostRegistry.register("shared.widget", panel_host)

	var add_result := await tools.handle("minerva_annotations_add", {
		"editor_name": "shared.widget",
		"annotation": _widget_annotation(),
	})
	check("add succeeds", bool(add_result.get("success", false)))

	var list_result := await tools.handle("minerva_annotations_list", {
		"editor_name": "shared.widget",
	})
	check("list succeeds", bool(list_result.get("success", false)))
	var annotations: Array = list_result.get("annotations", [])
	check("list sees exactly the one annotation the add call created (got %d)" % annotations.size(),
		annotations.size() == 1)
	if annotations.size() == 1:
		check("listed annotation is the widget_marker kind",
			str((annotations[0] as Dictionary).get("kind", "")) == "widget_marker")
	AnnotationHostRegistry._reset_for_test()


func test_empty_id_add_returns_structured_error(tools: MCPAnnotationTools) -> void:
	print("test_empty_id_add_returns_structured_error:")
	AnnotationHostRegistry._reset_for_test()
	var host := _StubRejectingHost.new()
	AnnotationHostRegistry.register("rejecting.widget", host)

	var result := await tools.handle("minerva_annotations_add", {
		"editor_name": "rejecting.widget",
		"annotation": _widget_annotation(),
	})
	check("ok is false (never a bare success)", result.get("ok", true) == false)
	check("success is not true", result.get("success", false) != true)
	check("errors array is present", result.has("errors") and result["errors"] is Array and (result["errors"] as Array).size() > 0)
	AnnotationHostRegistry._reset_for_test()


func test_empty_id_add_does_not_leak_ref_or_echo(tools: MCPAnnotationTools) -> void:
	print("test_empty_id_add_does_not_leak_ref_or_echo:")
	AnnotationHostRegistry._reset_for_test()
	var host := _StubRejectingHost.new()
	AnnotationHostRegistry.register("rejecting.widget2", host)

	var result := await tools.handle("minerva_annotations_add", {
		"editor_name": "rejecting.widget2",
		"annotation": _widget_annotation(),
	})
	# Bug 019f6b9221b6's exact live shape: {"echo":"Created C74 — ...","id":"",
	# "ref":"C74","success":true}. None of those fields may appear on a rejected
	# write — a caller must never see a ref/echo for an annotation that was
	# never stored.
	check("no 'id' key on failure", not result.has("id"))
	check("no 'ref' key on failure", not result.has("ref"))
	check("no 'echo' key on failure", not result.has("echo"))
	check("host stored nothing", host.get_annotations().size() == 0)
	AnnotationHostRegistry._reset_for_test()
