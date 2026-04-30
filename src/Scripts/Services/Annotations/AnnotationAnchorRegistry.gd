class_name AnnotationAnchorRegistry
extends RefCounted
## Registry for v2 annotation anchor types.
##
## Core anchors support base annotations that make sense across editors.
## Plugin anchors extend the same substrate with domain-specific validation,
## summaries, and repair hooks without teaching the substrate PCB/CAD semantics.

class AnchorResolver extends RefCounted:
	func validate(_anchor: Dictionary) -> Array:
		return []

	func summary(_anchor: Dictionary, _host: Object) -> String:
		return ""

	func repair(_anchor: Dictionary, _host: Object) -> Variant:
		return null


var _resolvers: Dictionary = {}


func register(plugin: String, anchor_type: String, resolver: Object) -> bool:
	if plugin.strip_edges().is_empty():
		push_warning("[AnnotationAnchorRegistry] Cannot register anchor with empty plugin")
		return false
	if anchor_type.strip_edges().is_empty():
		push_warning("[AnnotationAnchorRegistry] Cannot register anchor with empty type")
		return false
	if resolver == null:
		push_warning("[AnnotationAnchorRegistry] Cannot register null resolver")
		return false

	var key := _key(plugin, anchor_type)
	if _resolvers.has(key):
		push_warning("[AnnotationAnchorRegistry] Duplicate anchor registration rejected: %s/%s" % [plugin, anchor_type])
		return false

	_resolvers[key] = resolver
	return true


func unregister(plugin: String, anchor_type: String) -> void:
	_resolvers.erase(_key(plugin, anchor_type))


func get_resolver(plugin: String, anchor_type: String) -> Object:
	return _resolvers.get(_key(plugin, anchor_type), null)


func validate_anchor(anchor: Dictionary) -> Array:
	var base_errors := _validate_common_shape(anchor)
	if not base_errors.is_empty():
		return base_errors

	var plugin := str(anchor["plugin"])
	var anchor_type := str(anchor["type"])
	var resolver := get_resolver(plugin, anchor_type)
	if resolver == null:
		return ["unknown anchor type: %s/%s" % [plugin, anchor_type]]
	if not resolver.has_method("validate"):
		return ["anchor resolver missing validate: %s/%s" % [plugin, anchor_type]]

	var errors: Variant = resolver.validate(anchor)
	if errors is Array:
		return errors
	return ["anchor resolver validate returned non-array: %s/%s" % [plugin, anchor_type]]


func summary(anchor: Dictionary, host: Object) -> String:
	var plugin := str(anchor.get("plugin", ""))
	var anchor_type := str(anchor.get("type", ""))
	var resolver := get_resolver(plugin, anchor_type)
	if resolver != null and resolver.has_method("summary"):
		var value: Variant = resolver.summary(anchor, host)
		if value is String and not (value as String).is_empty():
			return value
	return _fallback_summary(anchor)


func repair(anchor: Dictionary, host: Object) -> Variant:
	var resolver := get_resolver(str(anchor.get("plugin", "")), str(anchor.get("type", "")))
	if resolver != null and resolver.has_method("repair"):
		return resolver.repair(anchor, host)
	return null


func known_anchors_for(plugin: String) -> Array:
	var result: Array = []
	var prefix := "%s/" % plugin
	for key in _resolvers.keys():
		var key_str := str(key)
		if key_str.begins_with(prefix):
			result.append(key_str.substr(prefix.length()))
	result.sort()
	return result


func count() -> int:
	return _resolvers.size()


func _validate_common_shape(anchor: Dictionary) -> Array:
	var errors: Array = []
	if not anchor.has("plugin"):
		errors.append("anchor.plugin is required")
	elif not anchor["plugin"] is String or (anchor["plugin"] as String).is_empty():
		errors.append("anchor.plugin must be a non-empty String")

	if not anchor.has("type"):
		errors.append("anchor.type is required")
	elif not anchor["type"] is String or (anchor["type"] as String).is_empty():
		errors.append("anchor.type must be a non-empty String")

	if not anchor.has("id"):
		errors.append("anchor.id is required")

	if not anchor.has("snapshot"):
		errors.append("anchor.snapshot is required")
	elif not anchor["snapshot"] is Dictionary:
		errors.append("anchor.snapshot must be a Dictionary")

	return errors


func _fallback_summary(anchor: Dictionary) -> String:
	return "%s.%s:%s" % [
		str(anchor.get("plugin", "")),
		str(anchor.get("type", "")),
		str(anchor.get("id", ""))
	]


func _key(plugin: String, anchor_type: String) -> String:
	return "%s/%s" % [plugin, anchor_type]
