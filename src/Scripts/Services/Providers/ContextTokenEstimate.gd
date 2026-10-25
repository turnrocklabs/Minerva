class_name ContextTokenEstimate
extends RefCounted
## Cheap input estimate over plain prompt values. Never encodes image pixels.

const IMAGE_TOKENS: int = 1500


static func tokens(value: Variant) -> int:
	if value is Image:
		return IMAGE_TOKENS
	if value is Dictionary:
		var object: Dictionary = value
		if _is_image(object):
			return IMAGE_TOKENS
		var total := 2
		for key: Variant in object:
			total += tokens(str(key)) + tokens(object[key]) + 1
		return total
	if value is Array:
		var values: Array = value
		var total := 1
		for part: Variant in values:
			total += tokens(part) + 1
		return total
	if value is String:
		var text_value: String = value
		return IMAGE_TOKENS if text_value.begins_with("data:image/") else ceili(text_value.length() / 4.0)
	return ceili(str(value).length() / 4.0)


static func _is_image(object: Dictionary) -> bool:
	var kind := str(object.get("type", ""))
	if kind in ["image_url", "input_image"] or (kind == "image" and object.has("source")):
		return true
	var inline_value: Variant = object.get("inline_data", object.get("inlineData"))
	if inline_value is Dictionary:
		var inline_data: Dictionary = inline_value
		return str(inline_data.get("mime_type", inline_data.get("mimeType", ""))).begins_with("image/")
	return false


## Ledger values stay complete text/JSON; image pixels are explicitly omitted.
static func archive_value(value: Variant) -> Variant:
	if value is Image:
		return "[image omitted]"
	if value is String:
		var text_value: String = value
		return "[image omitted]" if text_value.begins_with("data:image/") else text_value
	if value is Array:
		var source: Array = value
		var result: Array = []
		for part: Variant in source:
			result.append(archive_value(part))
		return result
	if value is Dictionary:
		var source: Dictionary = value
		if _is_image(source):
			return {"image": "omitted"}
		var result: Dictionary = {}
		for key: Variant in source:
			result[key] = archive_value(source[key])
		return result
	return value
