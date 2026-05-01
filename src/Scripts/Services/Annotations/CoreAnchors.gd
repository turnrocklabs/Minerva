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
	registry.register(CORE_PLUGIN, "canvas.point", get_resolver_for("canvas.point"))


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
		"canvas.point":
			return _CanvasPointResolver.new()
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


## Substrate-owned anchor for free positions on the overlay canvas.
## id: {x: float, y: float} in canvas-space pixels.
## Used by arrow/callout/text endpoints when the position is not bound to any
## host-resolved domain element.
class _CanvasPointResolver extends _BaseResolver:
	func validate(anchor: Dictionary) -> Array:
		var errors: Array = []
		var id: Variant = anchor.get("id", null)
		if not id is Dictionary:
			errors.append("canvas.point id must be {x:number, y:number}")
			return errors
		var id_dict: Dictionary = id
		if not id_dict.has("x"):
			errors.append("canvas.point id.x is required")
		elif not (id_dict["x"] is float or id_dict["x"] is int):
			errors.append("canvas.point id.x must be a number")
		if not id_dict.has("y"):
			errors.append("canvas.point id.y is required")
		elif not (id_dict["y"] is float or id_dict["y"] is int):
			errors.append("canvas.point id.y must be a number")
		return errors

	func summary(anchor: Dictionary, _host: Object) -> String:
		var id: Variant = anchor.get("id", {})
		if id is Dictionary:
			return "canvas point %s,%s" % [str((id as Dictionary).get("x", "?")), str((id as Dictionary).get("y", "?"))]
		return "canvas point unknown"

	## Resolve to a screen position from the anchor id payload.
	## Substrate-owned: every host can resolve canvas.point without registering
	## a host-local Callable.
	static func position_from(anchor: Dictionary) -> Vector2:
		var id: Variant = anchor.get("id", null)
		if id is Dictionary:
			var d: Dictionary = id
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		return Vector2.ZERO


## Build a well-formed core/canvas.point anchor at (x, y) in canvas space.
## Helper used by arrow/callout/text kinds when authoring free endpoints.
static func make_canvas_point(x: float, y: float) -> Dictionary:
	return {
		"plugin": CORE_PLUGIN,
		"type": "canvas.point",
		"id": {"x": x, "y": y},
		"snapshot": {"position": [x, y]},
	}
