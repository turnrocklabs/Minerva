extends SceneTree
## Tests for Phase A of T_apply: per-kind action buttons on AnnotationWorkbench.

const AnnotationKindScript = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")
const AnnotationWorkbenchScript = preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd")
const AnnotationHostScript = preload("res://Scripts/Services/Annotations/AnnotationHost.gd")
const AnnotationRegistryScript = preload("res://Scripts/Services/Annotations/AnnotationRegistry.gd")

var _pass_count := 0
var _fail_count := 0


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func _initialize() -> void:
	print("[tags: unit,annotations,kind_actions]")
	print("=== test_kind_actions ===\n")
	test_default_actions_returns_empty()
	test_default_run_action_reports_not_implemented()
	test_subclass_actions_renders_buttons_in_row()
	test_requires_lifecycle_filter_hides_button()
	test_action_button_press_calls_kind_run_action()
	test_action_returning_ok_false_shows_status()
	test_action_with_lifecycle_triggers_host_transition()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Helper: build an annotation dict with a non-stale canvas.point anchor ────

## Returns a canvas.point anchor that AnnotationHost.resolve_anchor marks as not-stale.
static func _make_ann(ann_id: String, kind_name: String, lifecycle: String) -> Dictionary:
	return {
		"id": ann_id,
		"kind": kind_name,
		"lifecycle": lifecycle,
		"summary": "test",
		"anchor": {"plugin": "core", "type": "canvas.point",
			"id": {"x": 10.0, "y": 10.0},
			"snapshot": {"position": [10.0, 10.0]}},
	}


# ── Test 1: default actions() returns empty ───────────────────────────────────

func test_default_actions_returns_empty() -> void:
	var kind := AnnotationKindScript.new()
	check("default actions() returns empty array", kind.actions({}).is_empty())


# ── Test 2: default run_action() reports not implemented ─────────────────────

func test_default_run_action_reports_not_implemented() -> void:
	var kind := AnnotationKindScript.new()
	var result: Dictionary = kind.run_action("foo", {}, "dry_run", null)
	check("default run_action ok=false", result.get("ok") == false)
	check("default run_action has error key", result.has("error"))


# ── Test 3: subclass actions renders buttons in row ───────────────────────────

func test_subclass_actions_renders_buttons_in_row() -> void:
	var registry := AnnotationRegistryScript.new()
	var kind := _ActionKind.new()
	kind.name = &"test_action_kind_3"
	kind.owning_plugin = &"test"
	kind._actions_to_return = [{"id": "do_thing", "label": "Do"}]
	registry.register_annotation_kind(kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [_make_ann("ann1", "test_action_kind_3", "open")]

	var workbench := AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()
	workbench.set_host(host)

	var btn: Button = _find_button_with_text(workbench, "Do")
	check("action button 'Do' is present in row", btn != null)

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 4: requires_lifecycle filter hides/shows button ─────────────────────

func test_requires_lifecycle_filter_hides_button() -> void:
	var registry := AnnotationRegistryScript.new()
	var kind := _ActionKind.new()
	kind.name = &"test_lifecycle_filter_kind_4"
	kind.owning_plugin = &"test"
	kind._actions_to_return = [{"id": "x", "label": "X", "requires_lifecycle": ["applied"]}]
	registry.register_annotation_kind(kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [_make_ann("ann_lc", "test_lifecycle_filter_kind_4", "open")]

	var workbench := AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()
	workbench.set_host(host)

	check("button 'X' absent when lifecycle=open", _find_button_with_text(workbench, "X") == null)

	# Transition annotation to applied and refresh (workbench filter must show applied too)
	workbench._filter = "applied"
	host._annotations = [_make_ann("ann_lc", "test_lifecycle_filter_kind_4", "applied")]
	workbench.refresh()

	check("button 'X' present when lifecycle=applied", _find_button_with_text(workbench, "X") != null)

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 5: action button press calls kind.run_action for both phases ─────────

func test_action_button_press_calls_kind_run_action() -> void:
	var registry := AnnotationRegistryScript.new()
	var kind := _TrackingKind.new()
	kind.name = &"test_tracking_kind_5"
	kind.owning_plugin = &"test"
	registry.register_annotation_kind(kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [_make_ann("ann_track", "test_tracking_kind_5", "open")]

	var workbench := AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()
	workbench.set_host(host)

	var btn: Button = _find_button_with_text(workbench, "Act")
	check("action button 'Act' found", btn != null)
	if btn != null:
		btn.pressed.emit()

	check("dry_run phase was called", "dry_run" in kind.phases_seen)
	check("commit phase was called", "commit" in kind.phases_seen)
	check("action_id was 'act'", kind.last_action_id == "act")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 6: action returning ok=false shows status ────────────────────────────

func test_action_returning_ok_false_shows_status() -> void:
	var registry := AnnotationRegistryScript.new()
	var kind := _FailKind.new()
	kind.name = &"test_fail_kind_6"
	kind.owning_plugin = &"test"
	registry.register_annotation_kind(kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [_make_ann("ann_fail", "test_fail_kind_6", "open")]

	var workbench := AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()
	workbench.set_host(host)

	var btn: Button = _find_button_with_text(workbench, "Fail")
	check("action button 'Fail' found", btn != null)
	if btn != null:
		btn.pressed.emit()

	check("status label shows error message", workbench._status_label.text == "boom")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 7: action with lifecycle triggers host transition ────────────────────

func test_action_with_lifecycle_triggers_host_transition() -> void:
	var registry := AnnotationRegistryScript.new()
	var kind := _LifecycleKind.new()
	kind.name = &"test_lifecycle_kind_7"
	kind.owning_plugin = &"test"
	registry.register_annotation_kind(kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [_make_ann("ann_lc2", "test_lifecycle_kind_7", "open")]

	var workbench := AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()
	workbench.set_host(host)

	var btn: Button = _find_button_with_text(workbench, "Apply")
	check("action button 'Apply' found", btn != null)
	if btn != null:
		btn.pressed.emit()

	check("host update_annotation_lifecycle called", host.last_lifecycle_id == "ann_lc2")
	check("host lifecycle set to 'applied'", host.last_lifecycle_value == "applied")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _find_button_with_text(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child in node.get_children():
		var found: Button = _find_button_with_text(child, text)
		if found != null:
			return found
	return null


# ── Stub kinds ────────────────────────────────────────────────────────────────

## A kind that returns configurable actions.
class _ActionKind extends AnnotationKind:
	var _actions_to_return: Array = []

	func _init() -> void:
		name = &"test_action_kind"
		display_name = "Action Kind"
		owning_plugin = &"test"
		primitives_optional = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()

	func actions(_annotation: Dictionary) -> Array:
		return _actions_to_return

	func run_action(_action_id: String, _annotation: Dictionary, _phase: String, _host: AnnotationHost) -> Dictionary:
		return {"ok": true}


## A kind that tracks which phases and action ids it was called with.
class _TrackingKind extends AnnotationKind:
	var phases_seen: Array = []
	var last_action_id: String = ""

	func _init() -> void:
		name = &"test_tracking_kind"
		display_name = "Tracking Kind"
		owning_plugin = &"test"
		primitives_optional = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()

	func actions(_annotation: Dictionary) -> Array:
		return [{"id": "act", "label": "Act"}]

	func run_action(action_id: String, _annotation: Dictionary, phase: String, _host: AnnotationHost) -> Dictionary:
		last_action_id = action_id
		phases_seen.append(phase)
		return {"ok": true}


## A kind whose run_action always fails with "boom".
class _FailKind extends AnnotationKind:
	func _init() -> void:
		name = &"test_fail_kind"
		display_name = "Fail Kind"
		owning_plugin = &"test"
		primitives_optional = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()

	func actions(_annotation: Dictionary) -> Array:
		return [{"id": "fail", "label": "Fail"}]

	func run_action(_action_id: String, _annotation: Dictionary, _phase: String, _host: AnnotationHost) -> Dictionary:
		return {"ok": false, "error": "boom"}


## A kind whose run_action returns ok=true with a lifecycle transition.
class _LifecycleKind extends AnnotationKind:
	func _init() -> void:
		name = &"test_lifecycle_kind"
		display_name = "Lifecycle Kind"
		owning_plugin = &"test"
		primitives_optional = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()

	func actions(_annotation: Dictionary) -> Array:
		return [{"id": "apply_action", "label": "Apply"}]

	func run_action(_action_id: String, _annotation: Dictionary, _phase: String, _host: AnnotationHost) -> Dictionary:
		return {"ok": true, "lifecycle": "applied"}


# ── Minimal test host ─────────────────────────────────────────────────────────

class _TestHost extends AnnotationHost:
	signal annotations_changed()

	var _annotations: Array = []
	var _selected_id: String = ""
	var _registry: AnnotationRegistry = null
	var last_lifecycle_id: String = ""
	var last_lifecycle_value: String = ""

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_capabilities() -> Dictionary:
		return {
			"lifecycle": {
				"apply": false,
				"resolve": false,
				"reopen": false,
				"delete": false,
				"repair": false,
			},
		}

	func set_selected_annotation_id(annotation_id: String) -> void:
		if _selected_id == annotation_id:
			return
		_selected_id = annotation_id
		selection_changed.emit(_selected_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
		for i in range(_annotations.size()):
			if str((_annotations[i] as Dictionary).get("id", "")) == annotation_id:
				_annotations[i] = new_annotation
				annotations_changed.emit()
				return true
		return false

	func update_annotation_lifecycle(annotation_id: String, lifecycle: String, _patch: Dictionary = {}) -> Dictionary:
		last_lifecycle_id = annotation_id
		last_lifecycle_value = lifecycle
		for i in range(_annotations.size()):
			var ann: Dictionary = _annotations[i] as Dictionary
			if str(ann.get("id", "")) == annotation_id:
				ann = ann.duplicate(true)
				ann["lifecycle"] = lifecycle
				_annotations[i] = ann
				annotations_changed.emit()
				return {"ok": true}
		return {"ok": false, "error": "not found"}

	func remove_annotation(annotation_id: String) -> bool:
		for i in range(_annotations.size()):
			if str((_annotations[i] as Dictionary).get("id", "")) == annotation_id:
				_annotations.remove_at(i)
				if _selected_id == annotation_id:
					_selected_id = ""
					selection_changed.emit("")
				annotations_changed.emit()
				return true
		return false

	func capture_state_snapshot() -> Variant:
		return _annotations.duplicate(true)

	func restore_state_snapshot(_snapshot: Variant) -> bool:
		return true
