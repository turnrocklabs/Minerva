class_name BuiltinKinds
extends RefCounted
## Static helpers to register / deregister the core-owned built-in 2D annotation
## kinds with an AnnotationRegistry instance.
##
## Call BuiltinKinds.register_all(registry) at Minerva startup (integration task
## 019dc055beeb7e058247b579214a2f70 wires this into the autoload / SingletonObject).
## Call BuiltinKinds.deregister_all(registry) only when tearing down the registry
## (shutdown or test reset).
##
## Kinds registered (design §5):
##   2d_arrow           — line + arrowhead; optional text label
##   2d_text            — positioned text string
##   2d_region          — closed polygon with optional fill
##   2d_polyline        — open polyline with optional text label (plan-decision §8)
##   2d_highlight       — low-alpha filled rect
##   2d_measure_distance — dimension line with end ticks and auto distance label
##   2d_measure_angle   — two-arm angle annotation with arc sweep and label
##   2d_measure_radius  — circle outline, radial line, and auto radius label
##   callout            — leader line + label attached to core or plugin anchors
##
## Not registered here (separate tasks):
##   2d_ink_stroke      — post-MVP (task 019dc0ebf9d5797a82af41edd4c8c180)

## The ordered list of names for deregistration convenience.
const BUILTIN_KIND_NAMES: PackedStringArray = [
	"2d_arrow",
	"2d_text",
	"2d_region",
	"2d_polyline",
	"2d_highlight",
	"2d_measure_distance",
	"2d_measure_angle",
	"2d_measure_radius",
	"callout",
]

const BUILTIN_KIND_ALIASES := {
	"arrow": "2d_arrow",
	"text": "2d_text",
	"region": "2d_region",
	"polyline": "2d_polyline",
	"highlight": "2d_highlight",
	"measure_distance": "2d_measure_distance",
	"measure_angle": "2d_measure_angle",
	"measure_radius": "2d_measure_radius",
	"callout": "callout",
}


func get_kind(kind_name: String) -> AnnotationKind:
	match _canonical_kind_name(kind_name):
		"2d_arrow":
			return AnnotationArrow.new()
		"2d_text":
			return AnnotationText.new()
		"2d_region":
			return AnnotationRegion.new()
		"2d_polyline":
			return AnnotationPolyline.new()
		"2d_highlight":
			return AnnotationHighlight.new()
		"2d_measure_distance":
			return AnnotationMeasureDistance.new()
		"2d_measure_angle":
			return AnnotationMeasureAngle.new()
		"2d_measure_radius":
			return AnnotationMeasureRadius.new()
		"callout":
			return AnnotationCallout.new()
	return null


func _canonical_kind_name(kind_name: String) -> String:
	return str(BUILTIN_KIND_ALIASES.get(kind_name, kind_name))


## Register all built-in 2D kinds with the given registry.
## Each kind is a fresh instance; subsequent calls (e.g. after deregister_all)
## create new instances so tests can reset safely.
## Returns true if all registrations succeeded; false if any collided (logs warning).
static func register_all(registry: AnnotationRegistry) -> bool:
	var ok := true
	ok = registry.register_annotation_kind(AnnotationArrow.new())          and ok
	ok = registry.register_annotation_kind(AnnotationText.new())           and ok
	ok = registry.register_annotation_kind(AnnotationRegion.new())         and ok
	ok = registry.register_annotation_kind(AnnotationPolyline.new())       and ok
	ok = registry.register_annotation_kind(AnnotationHighlight.new())      and ok
	ok = registry.register_annotation_kind(AnnotationMeasureDistance.new()) and ok
	ok = registry.register_annotation_kind(AnnotationMeasureAngle.new())   and ok
	ok = registry.register_annotation_kind(AnnotationMeasureRadius.new())  and ok
	ok = registry.register_annotation_kind(AnnotationCallout.new())        and ok
	return ok


## Deregister all built-in kinds from the given registry.
## No-ops silently for kinds not present (idempotent).
static func deregister_all(registry: AnnotationRegistry) -> void:
	for kind_name in BUILTIN_KIND_NAMES:
		registry.deregister_annotation_kind(StringName(kind_name))
