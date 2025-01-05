class_name TerminalOutputLabel
extends Control

var font: Font = ThemeDB.fallback_font
var font_size: int = ThemeDB.fallback_font_size
var line_height: float
var char_width: float


func _ready() -> void:
	
	# Get metrics using get_char_size for 'M' which is typically the widest character
	var char_metrics = font.get_char_size("M".unicode_at(0), font_size)
	line_height = font.get_height(font_size)  # Use get_height for proper line height
	char_width = char_metrics.x
	
	print("Line height: ", line_height)
	print("Char width: ", char_width)

	queue_redraw()


var content: PackedStringArray


func add_text(text: String, at: Vector2i) -> void:
	
	if at.x > content.size():
		for i in range(at.x - content.size()):
			content.append("")
	
	var line = content[at.x-1]

	if at.y > line.length():
		line = line.rpad(at.y)

	line[at.y-1] = text

	content[at.x-1] = line

	queue_redraw()


func _draw() -> void:
	
	var pos = Vector2(0, line_height)  # Start at first line

	for line in content:
		draw_string(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		pos.y += line_height
