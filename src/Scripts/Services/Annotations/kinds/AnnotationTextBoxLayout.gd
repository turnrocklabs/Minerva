class_name AnnotationTextBoxLayout
extends RefCounted
## One measured layout for wrapped annotation text. Box widths live in document
## units, so zoom changes glyph pixels but never changes line breaks.

const DEFAULT_WIDTH_EM := 14.0
const MIN_WIDTH_EM := 4.0
const _MEASURE_FONT_PX := 64


static func optional_size(container: Dictionary, key: String, font_size: float,
		scale: float = 1.0) -> Variant:
	var raw: Variant = container.get(key, null)
	var decoded: Variant = decode_size(raw)
	if not decoded is Vector2:
		return null
	var vector := decoded as Vector2
	return Vector2(maxf(vector.x, font_size * scale * MIN_WIDTH_EM),
		maxf(vector.y, font_size * scale))


static func decode_size(raw: Variant) -> Variant:
	var value := Vector2.ZERO
	if raw is Vector2:
		value = raw
	elif raw is Array and (raw as Array).size() >= 2 \
			and (raw[0] is int or raw[0] is float) and not raw[0] is bool \
			and (raw[1] is int or raw[1] is float) and not raw[1] is bool:
		value = Vector2(float(raw[0]), float(raw[1]))
	else:
		return null
	if not is_finite(value.x) or not is_finite(value.y) or value.x <= 0.0 or value.y <= 0.0:
		return null
	return value


static func default_size(font_size: float, scale: float = 1.0) -> Vector2:
	var glyph := maxf(font_size * scale, 0.01)
	return Vector2(glyph * DEFAULT_WIDTH_EM, glyph * 1.2)


static func layout(text: String, font_size: float, scale: float,
		requested_size: Variant = null) -> Dictionary:
	var glyph := maxf(font_size * scale, 0.01)
	var font := ThemeDB.fallback_font
	var metric_scale := glyph / float(_MEASURE_FONT_PX)
	var line_height := font.get_height(_MEASURE_FONT_PX) * metric_scale
	var ascent := font.get_ascent(_MEASURE_FONT_PX) * metric_scale
	var descent := font.get_descent(_MEASURE_FONT_PX) * metric_scale
	var width := INF
	if requested_size is Vector2:
		width = maxf((requested_size as Vector2).x, glyph * MIN_WIDTH_EM)
	var lines: Array[String] = []
	for paragraph in text.split("\n", true):
		if is_inf(width):
			lines.append(paragraph)
		else:
			_append_wrapped(lines, paragraph, width / metric_scale, font, _MEASURE_FONT_PX)
	if lines.is_empty():
		lines.append("")
	var natural_width := glyph
	for line in lines:
		natural_width = maxf(natural_width, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT,
			-1.0, _MEASURE_FONT_PX).x * metric_scale)
	var box_width := natural_width if is_inf(width) else width
	var content_height := maxf(line_height * lines.size(),
		ascent + line_height * (lines.size() - 1) + descent)
	var requested_height := (requested_size as Vector2).y if requested_size is Vector2 else content_height
	# Height grows to fit. Annotation text must never disappear behind a clipped
	# persisted box; width remains the user's reflow control.
	return {"lines": lines, "line_height": line_height, "ascent": ascent,
		"size": Vector2(box_width, maxf(requested_height, content_height))}


static func rotated_aabb(top_left: Vector2, size: Vector2, rotation: float) -> Rect2:
	if absf(rotation) < 0.0001:
		return Rect2(top_left, size)
	var basis := Transform2D(rotation, Vector2.ZERO)
	var points := [basis * Vector2.ZERO, basis * Vector2(size.x, 0.0),
		basis * Vector2(0.0, size.y), basis * size]
	var rect := Rect2(top_left + points[0], Vector2.ZERO)
	for index in range(1, points.size()):
		rect = rect.expand(top_left + points[index])
	return rect


static func resized(container: Dictionary, key: String, desired_width: float,
		text: String, font_size: float, scale: float = 1.0) -> Dictionary:
	var out := container.duplicate(true)
	var requested := Vector2(maxf(desired_width, font_size * scale * MIN_WIDTH_EM), 0.0)
	var result := layout(text, font_size, scale, requested)
	var size: Vector2 = result.size
	out[key] = [size.x, size.y]
	return out


static func _append_wrapped(lines: Array[String], paragraph: String, width: float,
		font: Font, font_size: int) -> void:
	if paragraph.is_empty():
		lines.append("")
		return
	var remainder := paragraph
	while not remainder.is_empty():
		if font.get_string_size(remainder, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= width:
			lines.append(remainder)
			return
		var cut := _fitting_prefix(remainder, width, font, font_size)
		var break_at := cut
		for index in range(cut - 1, 0, -1):
			if remainder[index] == " " or remainder[index] == "\t":
				break_at = index + 1
				break
		lines.append(remainder.substr(0, break_at))
		remainder = remainder.substr(break_at)


static func _fitting_prefix(text: String, width: float, font: Font, font_size: int) -> int:
	var low := 1
	var high := text.length()
	while low < high:
		var middle := (low + high + 1) >> 1
		if font.get_string_size(text.substr(0, middle), HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, font_size).x <= width:
			low = middle
		else:
			high = middle - 1
	return maxi(1, low)
