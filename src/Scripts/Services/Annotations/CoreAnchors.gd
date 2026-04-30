class_name CoreAnchors
extends RefCounted
## Built-in anchor resolvers for base annotation kinds.


const CORE_PLUGIN := "core"


func register_all(registry: Object) -> void:
	if registry == null:
		return
	registry.register(CORE_PLUGIN, "text.range", get_resolver_for("text.range"))
	registry.register(CORE_PLUGIN, "text.selection", get_resolver_for("text.selection"))
	registry.register(CORE_PLUGIN, "graphics.region", get_resolver_for("graphics.region"))
	registry.register(CORE_PLUGIN, "graphics.layer", get_resolver_for("graphics.layer"))


func get_resolver_for(anchor_type: String) -> Object:
	match anchor_type:
		"text.range":
			return _TextRangeResolver.new("text range")
		"text.selection":
			return _TextRangeResolver.new("text selection")
		"graphics.region":
			return _GraphicsRegionResolver.new()
		"graphics.layer":
			return _GraphicsLayerResolver.new()
	return null


class _BaseResolver extends RefCounted:
	func repair(_anchor: Dictionary, _host: Object) -> Variant:
		return null

	func _require_snapshot(anchor: Dictionary, errors: Array) -> Dictionary:
		if not anchor.has("snapshot"):
			errors.append("snapshot is required")
			return {}
		if not anchor["snapshot"] is Dictionary:
			errors.append("snapshot must be a Dictionary")
			return {}
		return anchor["snapshot"]


class _TextRangeResolver extends _BaseResolver:
	var _label: String

	func _init(label: String = "text range") -> void:
		_label = label

	func validate(anchor: Dictionary) -> Array:
		var errors: Array = []
		var id: Variant = anchor.get("id", null)
		if not id is Dictionary:
			errors.append("%s id must be {start:int, end:int}" % _label)
			return errors

		var id_dict: Dictionary = id
		if not id_dict.has("start"):
			errors.append("%s id.start is required" % _label)
		elif not id_dict["start"] is int:
			errors.append("%s id.start must be an int" % _label)

		if not id_dict.has("end"):
			errors.append("%s id.end is required" % _label)
		elif not id_dict["end"] is int:
			errors.append("%s id.end must be an int" % _label)

		return errors

	func summary(anchor: Dictionary, _host: Object) -> String:
		var id: Variant = anchor.get("id", {})
		if id is Dictionary:
			return "%s %s-%s" % [_label, str(id.get("start", "?")), str(id.get("end", "?"))]
		return "%s unknown" % _label


class _GraphicsRegionResolver extends _BaseResolver:
	func validate(anchor: Dictionary) -> Array:
		var errors: Array = []
		var snapshot := _require_snapshot(anchor, errors)
		if snapshot.is_empty() and not anchor.has("snapshot"):
			return errors

		if not snapshot.has("rect"):
			errors.append("graphics.region snapshot.rect is required")
		elif not snapshot["rect"] is Array:
			errors.append("graphics.region snapshot.rect must be an Array")
		elif (snapshot["rect"] as Array).size() != 4:
			errors.append("graphics.region snapshot.rect must have 4 numbers")
		return errors

	func summary(anchor: Dictionary, _host: Object) -> String:
		var rect: Variant = anchor.get("snapshot", {}).get("rect", null)
		if rect is Array and (rect as Array).size() == 4:
			return "graphics region %s,%s %sx%s" % [str(rect[0]), str(rect[1]), str(rect[2]), str(rect[3])]
		return "graphics region %s" % str(anchor.get("id", "unknown"))


class _GraphicsLayerResolver extends _BaseResolver:
	func validate(anchor: Dictionary) -> Array:
		var errors: Array = []
		if not anchor.has("id"):
			errors.append("graphics.layer id is required")
		_require_snapshot(anchor, errors)
		return errors

	func summary(anchor: Dictionary, _host: Object) -> String:
		return "graphics layer %s" % str(anchor.get("id", "unknown"))
