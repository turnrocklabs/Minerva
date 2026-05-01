extends SceneTree
## Smoke test for the Hello Scene visible annotation demo fixture.
##
## Run: godot --headless --path src --script test/test_hello_annotation_demo_fixture.gd

var _pass_count := 0
var _fail_count := 0


func _initialize() -> void:
	print("=== Hello Annotation Demo Fixture Tests ===\n")

	var host := Helloscene_AnnotationHost.new()
	host.register_anchor_resolver(
		"hello_scene/widget.point",
		Callable(host, "resolve_widget_point_anchor")
	)
	host.set_annotations(Helloscene_AnnotationHost.make_demo_annotations())

	var annotations := host.get_annotations()
	check_eq("fixture creates four annotations", annotations.size(), 4)
	check("fixture includes callout", _has_kind(annotations, "callout"))
	check("fixture includes arrow", _has_kind(annotations, "2d_arrow"))
	check("fixture includes free text", _has_kind(annotations, "2d_text"))
	check("fixture includes plugin-owned hello_scene anchor", _has_anchor_plugin(annotations, "hello_scene"))
	check("fixture includes stale/snapshot fallback anchor", _has_anchor_plugin(annotations, "missing_plugin"))

	var resolved: Variant = host.resolve_position_source(_first_anchor_for_plugin(annotations, "hello_scene"))
	check("hello_scene plugin anchor resolves through host", resolved is Vector2 and (resolved as Vector2) != Vector2.ZERO)

	_finish()


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	check("%s — expected %s, got %s" % [description, str(expected), str(actual)], actual == expected)


func _has_kind(annotations: Array, kind: String) -> bool:
	for ann in annotations:
		if ann is Dictionary and str((ann as Dictionary).get("kind", "")) == kind:
			return true
	return false


func _has_anchor_plugin(annotations: Array, plugin: String) -> bool:
	return not _first_anchor_for_plugin(annotations, plugin).is_empty()


func _first_anchor_for_plugin(annotations: Array, plugin: String) -> Dictionary:
	for ann in annotations:
		if not ann is Dictionary:
			continue
		var anchor: Variant = (ann as Dictionary).get("anchor", {})
		if anchor is Dictionary and str((anchor as Dictionary).get("plugin", "")) == plugin:
			return anchor as Dictionary
		var payload: Variant = (ann as Dictionary).get("kind_payload", {})
		if payload is Dictionary:
			for key in ["endpoint_a", "endpoint_b"]:
				var endpoint: Variant = (payload as Dictionary).get(key, {})
				if endpoint is Dictionary and str((endpoint as Dictionary).get("plugin", "")) == plugin:
					return endpoint as Dictionary
	return {}


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)
