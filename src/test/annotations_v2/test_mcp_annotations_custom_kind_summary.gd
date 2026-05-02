extends SceneTree
## Test that minerva_annotations_list via editor_name uses the host's registry
## for kind resolution, so custom-kind summaries propagate correctly.
##
## Run: godot --headless --path src --script test/annotations_v2/test_mcp_annotations_custom_kind_summary.gd

var _pass_count := 0
var _fail_count := 0


func _initialize() -> void:
	print("[tags: unit]")
	print("=== test_mcp_annotations_custom_kind_summary ===\n")
	await test_list_editor_path_returns_custom_kind_summary()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


class _CustomKind extends AnnotationKind:
	func _init() -> void:
		name = &"custom_test_kind"
		display_name = "Custom Test Kind"
		owning_plugin = &"test"

	func render(_ctx: AnnotationRenderContext, _ann: Dictionary) -> void:
		pass

	func summary(_ann: Dictionary) -> String:
		return "distinctive-custom-summary"

	func accepted_anchor_types() -> Array:
		return ["core/canvas.point"]


class _FixtureHost extends AnnotationHost:
	var _annotations: Array = []
	var _registry: AnnotationRegistry = null

	func _init(registry: AnnotationRegistry) -> void:
		_registry = registry

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func push(ann: Dictionary) -> void:
		_annotations.append(ann.duplicate(true))


func test_list_editor_path_returns_custom_kind_summary() -> void:
	print("test_list_editor_path_returns_custom_kind_summary:")
	AnnotationHostRegistry._reset_for_test()

	var registry := AnnotationRegistry.new()
	registry.register_annotation_kind(_CustomKind.new())

	var host := _FixtureHost.new(registry)
	host.push({
		"id": "ann_custom1",
		"kind": "custom_test_kind",
		"view_context": "test",
		"author": "ai",
		"primitives": [],
	})
	AnnotationHostRegistry.register("CustomPanel", host)

	var tools := MCPAnnotationTools.new(null)
	var result: Dictionary = await tools.handle("minerva_annotations_list", {
		"editor_name": "CustomPanel",
	})

	check("list custom kind: success=true", result.get("success", false))
	var annotations: Array = result.get("annotations", [])
	check("list custom kind: one annotation returned", annotations.size() == 1)
	if annotations.size() > 0:
		var summary: String = str(annotations[0].get("summary", ""))
		check("list custom kind: summary matches custom kind output", summary == "distinctive-custom-summary")

	AnnotationHostRegistry._reset_for_test()
