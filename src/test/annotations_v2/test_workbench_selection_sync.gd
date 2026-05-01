extends SceneTree
## Tests for AnnotationWorkbench ↔ host selection_changed wiring (T4).
## State-and-signal only — no draw-frame tests.

const AnnotationWorkbenchScript = preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd")
const AnnotationHostScript = preload("res://Scripts/Services/Annotations/AnnotationHost.gd")

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
	print("[tags: unit,ux,selection]")
	print("=== test_workbench_selection_sync ===\n")
	test_set_host_connects_selection_changed()
	test_set_host_seeds_selected_id_from_existing_selection()
	test_set_host_disconnects_from_old_host()
	test_set_host_null_is_safe()
	test_select_annotation_calls_host_and_emits_signal()
	test_remove_annotation_clears_workbench_selected_id()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Test 1: set_host connects selection_changed ───────────────────────────────

func test_set_host_connects_selection_changed() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()

	var host := _TestHost.new()
	workbench.set_host(host)

	host.set_selected_annotation_id("ann_abc")
	check("emitting selection_changed updates _selected_id", workbench._selected_id == "ann_abc")

	host.set_selected_annotation_id("")
	check("emitting selection_changed with empty clears _selected_id", workbench._selected_id == "")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 2: set_host seeds _selected_id from pre-existing selection ───────────

func test_set_host_seeds_selected_id_from_existing_selection() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()

	var host := _TestHost.new()
	host._selected_id = "ann_pre"

	workbench.set_host(host)
	check("set_host seeds _selected_id from existing host selection", workbench._selected_id == "ann_pre")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 3: set_host disconnects from old host ────────────────────────────────

func test_set_host_disconnects_from_old_host() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()

	var old_host := _TestHost.new()
	workbench.set_host(old_host)
	old_host.set_selected_annotation_id("ann_old")
	check("old host selection sets _selected_id before rebind", workbench._selected_id == "ann_old")

	var new_host := _TestHost.new()
	workbench.set_host(new_host)
	check("after rebind _selected_id is cleared (new host has no selection)", workbench._selected_id == "")

	# Emitting on old host must NOT update workbench anymore.
	old_host.set_selected_annotation_id("ann_should_not_propagate")
	check("old host signal no longer updates workbench after rebind", workbench._selected_id == "")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 4: set_host(null) is safe ────────────────────────────────────────────
# Choice: _selected_id is cleared to "" on null bind (safe default).

func test_set_host_null_is_safe() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()

	var host := _TestHost.new()
	workbench.set_host(host)
	host.set_selected_annotation_id("ann_before_null")

	# Bind to null — must not crash, _selected_id is cleared.
	workbench.set_host(null)
	check("set_host(null) does not crash", true)
	check("set_host(null) clears _selected_id", workbench._selected_id == "")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 5: _select_annotation calls host + emits annotation_selected ─────────

func test_select_annotation_calls_host_and_emits_signal() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()

	var host := _TestHost.new()
	workbench.set_host(host)

	var captured := {"id": ""}
	workbench.annotation_selected.connect(func(id: String) -> void: captured["id"] = id)

	workbench._select_annotation("ann_xyz")
	check("_select_annotation calls host.set_selected_annotation_id", host.get_selected_annotation_id() == "ann_xyz")
	check("_select_annotation emits annotation_selected signal", str(captured.get("id", "")) == "ann_xyz")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 6: remove_annotation clearing selection propagates to workbench ───────

func test_remove_annotation_clears_workbench_selected_id() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench._ready()

	var host := _TestHost.new()
	host._annotations = [
		{"id": "ann_del", "kind": "callout", "lifecycle": "open", "summary": "to remove"},
	]
	workbench.set_host(host)
	host.set_selected_annotation_id("ann_del")
	check("selection set before remove", workbench._selected_id == "ann_del")

	host.remove_annotation("ann_del")
	check("after host removes selected annotation, workbench _selected_id is cleared", workbench._selected_id == "")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Minimal test host ─────────────────────────────────────────────────────────

class _TestHost extends AnnotationHost:
	signal annotations_changed()

	var _annotations: Array = []
	var _selected_id: String = ""

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func set_selected_annotation_id(annotation_id: String) -> void:
		if _selected_id == annotation_id:
			return
		_selected_id = annotation_id
		selection_changed.emit(_selected_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func remove_annotation(annotation_id: String) -> bool:
		for i in range(_annotations.size()):
			var entry: Dictionary = _annotations[i] as Dictionary
			if str(entry.get("id", "")) == annotation_id:
				_annotations.remove_at(i)
				if _selected_id == annotation_id:
					_selected_id = ""
					selection_changed.emit("")
				annotations_changed.emit()
				return true
		return false
