extends SceneTree
## Panel-owned annotation-dock placement (PCB UI redesign round A).
##
## Run: godot --headless --path src --script test/test_annotation_dock_panel_owned.gd
##
## A plugin surface may expose the duck-typed hook
##   get_annotation_dock_parent() -> Control
## to claim ownership of WHERE the platform AnnotationDockPane is mounted
## (e.g. inside the panel's own responsive sidebar). This suite covers:
##   1. AnnotationDockMount.resolve_dock_parent contract — Control returned,
##      missing method, non-Control return, freed-Control return.
##   2. Probe of the panel-owned mount sequence with a REAL AnnotationDockPane:
##      dock lands inside the panel-provided parent (not the editor VBox),
##      is column-shaped (DockMode.RIGHT), and a freed dock (plugin reload)
##      is detected and rebuilt rather than reused.
##
## The full Editor scene is too entangled for headless instantiation; per the
## input-probe precedent this reproduces the mount steps faithfully and pins
## AnnotationDockMount.resolve_dock_parent, which the real mount path calls.

const DockMountScript := preload("res://Scripts/Services/Annotations/AnnotationDockMount.gd")
const DockPaneScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationDockPane.gd")

var _pass := 0
var _fail := 0


func check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


## Surface fixture that opts in to panel-owned dock placement.
class OptInSurface extends Control:
	var sidebar: VBoxContainer = null

	func _init() -> void:
		sidebar = VBoxContainer.new()
		sidebar.name = "RightSidebar"
		add_child(sidebar)

	func get_annotation_dock_parent() -> Control:
		return sidebar


## Surface fixture returning a non-Control (contract violation → fallback).
class BadReturnSurface extends Control:
	func get_annotation_dock_parent() -> Variant:
		return "not a control"


func _init() -> void:
	print("=== Annotation dock panel-owned placement ===\n")
	await process_frame

	_test_resolver_contract()
	await _test_panel_owned_mount_probe()
	await _test_reload_rebuild_probe()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1. Resolver contract ───────────────────────────────────────────────────────

func _test_resolver_contract() -> void:
	print("-- resolver contract --")

	var opt_in := OptInSurface.new()
	get_root().add_child(opt_in)
	var resolved := DockMountScript.resolve_dock_parent(opt_in)
	check("opt-in surface resolves to its sidebar", resolved == opt_in.sidebar)

	var plain := Control.new()
	get_root().add_child(plain)
	check("surface without hook resolves null",
		DockMountScript.resolve_dock_parent(plain) == null)

	var bad := BadReturnSurface.new()
	get_root().add_child(bad)
	check("non-Control return resolves null (fallback)",
		DockMountScript.resolve_dock_parent(bad) == null)

	check("null surface resolves null",
		DockMountScript.resolve_dock_parent(null) == null)

	# Freed parent: hook returns a Control that has been freed.
	var freed_holder := OptInSurface.new()
	get_root().add_child(freed_holder)
	freed_holder.sidebar.free()
	check("freed-Control return resolves null (fallback)",
		DockMountScript.resolve_dock_parent(freed_holder) == null)

	for n in [opt_in, plain, bad, freed_holder]:
		n.queue_free()


# ── 2. Panel-owned mount probe ─────────────────────────────────────────────────

## Faithful reproduction of the panel-owned branch of
## Editor._mount_annotation_dock_for_surface: resolve parent → create the REAL
## AnnotationDockPane inside it → column mode.
func _mount_dock_for(surface: Control) -> Node:
	var dock_parent := DockMountScript.resolve_dock_parent(surface)
	if dock_parent == null:
		return null
	var pane: Node = DockPaneScript.new()
	pane.name = "AnnotationDockPane"
	pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock_parent.add_child(pane)
	if pane.has_method("set_dock_mode"):
		pane.set_dock_mode(DockPaneScript.DockMode.RIGHT)
	return pane


func _test_panel_owned_mount_probe() -> void:
	print("\n-- panel-owned mount probe (real AnnotationDockPane) --")

	var surface := OptInSurface.new()
	get_root().add_child(surface)
	await process_frame

	var pane := _mount_dock_for(surface)
	await process_frame

	check("pane created", pane != null)
	if pane == null:
		surface.queue_free()
		return
	check("pane parented inside the panel's sidebar", pane.get_parent() == surface.sidebar)
	check("pane is inside the surface subtree", surface.is_ancestor_of(pane))
	check("pane in column mode (DockMode.RIGHT)",
		int(pane.get("dock_mode")) == DockPaneScript.DockMode.RIGHT)
	check("pane fills the sidebar column",
		pane.size_flags_vertical == Control.SIZE_EXPAND_FILL)

	surface.queue_free()


# ── 3. Reload rebuild probe ────────────────────────────────────────────────────

## Plugin reload frees the surface AND the pane inside it. The mount path's
## stale-reference guard (is_instance_valid → null → rebuild) must produce a
## fresh pane in the NEW surface instead of touching the freed one.
func _test_reload_rebuild_probe() -> void:
	print("\n-- reload rebuild probe --")

	var surface := OptInSurface.new()
	get_root().add_child(surface)
	await process_frame
	var pane := _mount_dock_for(surface)
	await process_frame
	check("initial mount ok", pane != null and is_instance_valid(pane))

	# Simulate plugin reload: the whole surface (with the pane inside) is freed.
	surface.free()
	check("pane freed with surface", not is_instance_valid(pane))

	# Editor's guard: a freed reference is dropped, then the mount recreates.
	var sidebar_ref: Node = pane
	if sidebar_ref != null and not is_instance_valid(sidebar_ref):
		sidebar_ref = null
	check("stale reference detected and dropped", sidebar_ref == null)

	var new_surface := OptInSurface.new()
	get_root().add_child(new_surface)
	await process_frame
	var new_pane := _mount_dock_for(new_surface)
	await process_frame
	check("remount creates a fresh pane in the new surface",
		new_pane != null and is_instance_valid(new_pane)
		and new_pane.get_parent() == new_surface.sidebar)

	new_surface.queue_free()
