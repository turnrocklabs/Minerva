class_name AnnotationDockMount
extends RefCounted
## Panel-owned annotation-dock placement: the duck-typed contract and its
## resolver (PCB UI redesign round A).
##
## A plugin surface may expose
##     get_annotation_dock_parent() -> Control
## to claim ownership of WHERE the platform AnnotationDockPane is mounted —
## e.g. inside the panel's own responsive right sidebar — mirroring the
## get_annotation_overlay_parent() precedent for the overlay. When a surface
## opts in, Editor bypasses its width-driven RIGHT/BOTTOM dock reparenting
## entirely; the panel owns the dock's responsive behavior from then on.
##
## Lives in a dependency-free leaf file (not Editor.gd) so the contract is
## headless-testable and reusable by any future panel host.


## Returns the panel-provided dock parent, or null when the surface doesn't
## opt in. Any non-Control or freed return value is treated as "no opt-in"
## (fail-safe to platform placement, never a crash).
static func resolve_dock_parent(surface: Object) -> Control:
	# The mount path can run deferred — the surface itself may be freed by then.
	if surface == null or not is_instance_valid(surface):
		return null
	if not surface.has_method("get_annotation_dock_parent"):
		return null
	var preferred: Variant = surface.call("get_annotation_dock_parent")
	# Freed-instance guard must run BEFORE any `is` check — `x is Control` on a
	# previously freed instance is a runtime error, not false.
	if typeof(preferred) != TYPE_OBJECT or not is_instance_valid(preferred):
		return null
	if preferred is Control:
		return preferred as Control
	return null
