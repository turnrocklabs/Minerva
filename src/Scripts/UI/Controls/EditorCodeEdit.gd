class_name EditorCodeEdit
extends CodeEdit

## Content of the saved version of this code edit.[br]
## Every time the editor content is saved, this should be updated.
var saved_content: String


func _ready() -> void:
	size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
	caret_blink = true
	caret_multiple = false
	highlight_all_occurrences = true
	highlight_current_line = true
	gutters_draw_line_numbers = true
	gutters_zero_pad_line_numbers = true
	autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	name = "CodeEdit"
	line_folding = true
