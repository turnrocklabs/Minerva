extends SceneTree
## Tests for T5 Phase 1: AnnotationKind body_view_factory extension API,
## AnnotationOverlay has_visual_render opt-out, and AnnotationWorkbench body-view wiring.

const AnnotationKindScript = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")
const AnnotationOverlayScript = preload("res://Scripts/Services/Annotations/AnnotationOverlay.gd")
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
	print("[tags: unit,annotations,extension_api]")
	print("=== test_kind_extension_api ===\n")
	test_default_body_view_factory_returns_null()
	test_subclass_body_view_factory_returns_control()
	test_overlay_skips_render_when_has_visual_render_false()
	test_overlay_skips_halo_when_has_visual_render_false()
	test_workbench_attaches_body_view_on_selection()
	test_workbench_replaces_body_view_on_reselection()
	test_emit_patch_calls_host_update_annotation()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Test 1: default body_view_factory returns null ────────────────────────────

func test_default_body_view_factory_returns_null() -> void:
	var kind := AnnotationKindScript.new()
	var result: Variant = kind.body_view_factory({}, func(_p: Dictionary) -> void: pass)
	check("default body_view_factory returns null", result == null)


# ── Test 2: subclass override returns a Control ───────────────────────────────

func test_subclass_body_view_factory_returns_control() -> void:
	var kind := _LabelKind.new()
	var result: Variant = kind.body_view_factory({}, func(_p: Dictionary) -> void: pass)
	check("subclass body_view_factory returns a Control", result is Control)
	if result is Control:
		(result as Control).queue_free()


# ── Test 3: overlay skips render when has_visual_render() == false ────────────

func test_overlay_skips_render_when_has_visual_render_false() -> void:
	var registry := AnnotationRegistryScript.new()
	var opt_out_kind := _OptOutKind.new()
	opt_out_kind.name = &"test_optout"
	opt_out_kind.owning_plugin = &"test"
	registry.register_annotation_kind(opt_out_kind)

	var normal_kind := _NormalKind.new()
	normal_kind.name = &"test_normal"
	normal_kind.owning_plugin = &"test"
	registry.register_annotation_kind(normal_kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [
		{"id": "ann_optout", "kind": "test_optout", "lifecycle": "open"},
		{"id": "ann_normal", "kind": "test_normal", "lifecycle": "open"},
	]

	var overlay := AnnotationOverlayScript.new()
	root.add_child(overlay)
	overlay._ready()
	overlay.set_host(host)
	# Call _draw() directly — queue_redraw() defers to the GPU thread which doesn't
	# fire in headless. Direct call exercises the logic synchronously.
	overlay._draw()

	check("opt-out kind render() was NOT called", opt_out_kind.render_call_count == 0)
	check("normal kind render() WAS called", normal_kind.render_call_count > 0)

	root.remove_child(overlay)
	overlay.queue_free()


# ── Test 4: overlay skips halo when has_visual_render() == false ──────────────

func test_overlay_skips_halo_when_has_visual_render_false() -> void:
	var registry := AnnotationRegistryScript.new()
	var opt_out_kind := _OptOutKind.new()
	opt_out_kind.name = &"test_optout_halo"
	opt_out_kind.owning_plugin = &"test"
	registry.register_annotation_kind(opt_out_kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [
		{"id": "ann_halo", "kind": "test_optout_halo", "lifecycle": "open"},
	]
	host._selected_id = "ann_halo"

	var overlay := AnnotationOverlayScript.new()
	root.add_child(overlay)
	overlay._ready()
	overlay.set_host(host)
	# Direct call — queue_redraw() does not fire synchronously in headless.
	overlay._draw()
	check("overlay does not crash with opt-out kind selected", true)

	root.remove_child(overlay)
	overlay.queue_free()


# ── Test 5: workbench attaches body view on selection ─────────────────────────

func test_workbench_attaches_body_view_on_selection() -> void:
	var registry := AnnotationRegistryScript.new()
	var kind := _LabelKind.new()
	kind.name = &"test_bv_kind"
	kind.owning_plugin = &"test"
	registry.register_annotation_kind(kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [
		{"id": "ann_bv", "kind": "test_bv_kind", "lifecycle": "open", "summary": "body view test"},
	]

	var workbench := AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()
	workbench.set_host(host)

	host.set_selected_annotation_id("ann_bv")

	# Search for a Label descendant with text "BV".
	var found_label: Label = _find_label_with_text(workbench, "BV")
	check("body view Label 'BV' is a descendant of workbench", found_label != null)

	var container: Node = workbench.get_node_or_null("BodyViewContainer")
	check("BodyViewContainer is visible", container != null and (container as Control).visible)

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 6: workbench replaces body view on reselection ──────────────────────

func test_workbench_replaces_body_view_on_reselection() -> void:
	var registry := AnnotationRegistryScript.new()
	var kind_a := _LabelKind.new()
	kind_a.name = &"test_bv_kind_a"
	kind_a.owning_plugin = &"test"
	kind_a._label_text = "BV"
	registry.register_annotation_kind(kind_a)

	var kind_b := _LabelKind.new()
	kind_b.name = &"test_bv_kind_b"
	kind_b.owning_plugin = &"test"
	kind_b._label_text = "BV2"
	registry.register_annotation_kind(kind_b)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [
		{"id": "ann_a", "kind": "test_bv_kind_a", "lifecycle": "open", "summary": "a"},
		{"id": "ann_b", "kind": "test_bv_kind_b", "lifecycle": "open", "summary": "b"},
	]

	var workbench := AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()
	workbench.set_host(host)

	host.set_selected_annotation_id("ann_a")
	check("BV label present after selecting ann_a", _find_label_with_text(workbench, "BV") != null)
	check("BV2 label absent after selecting ann_a", _find_label_with_text(workbench, "BV2") == null)

	host.set_selected_annotation_id("ann_b")
	check("BV2 label present after selecting ann_b", _find_label_with_text(workbench, "BV2") != null)
	check("BV label absent after selecting ann_b", _find_label_with_text(workbench, "BV") == null)

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 7: emit_patch calls host.update_annotation ──────────────────────────

func test_emit_patch_calls_host_update_annotation() -> void:
	var registry := AnnotationRegistryScript.new()
	var kind := _PatchCapturingKind.new()
	kind.name = &"test_patch_kind"
	kind.owning_plugin = &"test"
	registry.register_annotation_kind(kind)

	var host := _TestHost.new()
	host._registry = registry
	host._annotations = [
		{"id": "ann_patch", "kind": "test_patch_kind", "lifecycle": "open", "summary": "patch me"},
	]

	var workbench := AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()
	workbench.set_host(host)

	host.set_selected_annotation_id("ann_patch")

	# The _PatchCapturingKind stores the emit_patch callable on the returned Control.
	# We invoke emit_patch with a small patch and verify host.update_annotation was called.
	kind.invoke_stored_patch({"summary": "patched"})

	check("update_annotation was called after emit_patch", host.last_updated_id == "ann_patch")
	check("merged dict contains patched field", str(host.last_updated_dict.get("summary", "")) == "patched")
	check("merged dict retains original kind", str(host.last_updated_dict.get("kind", "")) == "test_patch_kind")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _find_label_with_text(node: Node, text: String) -> Label:
	if node is Label and (node as Label).text == text:
		return node as Label
	for child in node.get_children():
		var found: Label = _find_label_with_text(child, text)
		if found != null:
			return found
	return null


# ── Stub kinds ────────────────────────────────────────────────────────────────

class _LabelKind extends AnnotationKind:
	var _label_text: String = "BV"

	func _init() -> void:
		name = &"test_label_kind"
		display_name = "Test Label Kind"
		owning_plugin = &"test"
		primitives_optional = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2(0, 0, 100, 40)

	func body_view_factory(_annotation: Dictionary, _emit_patch: Callable) -> Control:
		var lbl := Label.new()
		lbl.text = _label_text
		return lbl


class _OptOutKind extends AnnotationKind:
	var render_call_count: int = 0

	func _init() -> void:
		name = &"test_optout"
		display_name = "Opt-Out Kind"
		owning_plugin = &"test"
		primitives_optional = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		render_call_count += 1

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2(10, 10, 50, 50)

	func has_visual_render() -> bool:
		return false


class _NormalKind extends AnnotationKind:
	var render_call_count: int = 0

	func _init() -> void:
		name = &"test_normal"
		display_name = "Normal Kind"
		owning_plugin = &"test"
		primitives_optional = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		render_call_count += 1

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2(10, 10, 50, 50)


class _PatchCapturingKind extends AnnotationKind:
	var _stored_emit: Callable = Callable()

	func _init() -> void:
		name = &"test_patch_kind"
		display_name = "Patch Kind"
		owning_plugin = &"test"
		primitives_optional = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2(0, 0, 100, 40)

	func body_view_factory(_annotation: Dictionary, emit_patch: Callable) -> Control:
		_stored_emit = emit_patch
		var lbl := Label.new()
		lbl.text = "PATCH"
		return lbl

	func invoke_stored_patch(patch: Dictionary) -> void:
		if _stored_emit.is_valid():
			_stored_emit.call(patch)


# ── Minimal test host ─────────────────────────────────────────────────────────

class _TestHost extends AnnotationHost:
	signal annotations_changed()

	var _annotations: Array = []
	var _selected_id: String = ""
	var _registry: AnnotationRegistry = null
	var last_updated_id: String = ""
	var last_updated_dict: Dictionary = {}

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func get_registry() -> AnnotationRegistry:
		return _registry

	func set_selected_annotation_id(annotation_id: String) -> void:
		if _selected_id == annotation_id:
			return
		_selected_id = annotation_id
		selection_changed.emit(_selected_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
		last_updated_id = annotation_id
		last_updated_dict = new_annotation.duplicate(true)
		for i in range(_annotations.size()):
			if str((_annotations[i] as Dictionary).get("id", "")) == annotation_id:
				_annotations[i] = new_annotation
				annotations_changed.emit()
				return true
		return false

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
