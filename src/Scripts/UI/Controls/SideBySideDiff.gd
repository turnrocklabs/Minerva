class_name SideBySideDiff
extends HSplitContainer
## Beyond Compare / Odd-style two-pane review diff (work item 019ea06a1413, Stage D).
##
## Read-only review view rendered from TextLineDiff.aligned_rows():
##   left  = BEFORE  (deletions tinted red, gaps dimmed)
##   right = AFTER   (additions tinted green, gaps dimmed)
## Rows align 1:1 across panes (gap rows on the side that lacks a line), and the
## two panes scroll together. This is a SEPARATE view — it does NOT touch the
## real document buffer, so annotations/refs on the real file are unaffected.
## (Inline annotation display in the right pane is a later iteration; T5.)

var _left: CodeEdit
var _right: CodeEdit
var _syncing := false

const COL_ADD := Color(0.25, 1.0, 0.25, 0.18)   # right additions (green)
const COL_DEL := Color(1.0, 0.30, 0.30, 0.18)   # left deletions (red)
const COL_GAP := Color(0.5, 0.5, 0.5, 0.10)      # alignment gap (dim)


func _init() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	_left = _make_pane()
	_right = _make_pane()
	add_child(_left)
	add_child(_right)


func _make_pane() -> CodeEdit:
	var ce := CodeEdit.new()
	ce.editable = false
	ce.gutters_draw_line_numbers = true
	ce.highlight_current_line = false
	ce.size_flags_horizontal = SIZE_EXPAND_FILL
	ce.size_flags_vertical = SIZE_EXPAND_FILL
	return ce


func _ready() -> void:
	# Synchronized vertical scroll (guarded against the echo).
	var lvs := _left.get_v_scroll_bar()
	var rvs := _right.get_v_scroll_bar()
	if lvs:
		lvs.value_changed.connect(_on_left_scroll)
	if rvs:
		rvs.value_changed.connect(_on_right_scroll)


func _on_left_scroll(v: float) -> void:
	if _syncing:
		return
	_syncing = true
	_right.scroll_vertical = int(v)
	_syncing = false


func _on_right_scroll(v: float) -> void:
	if _syncing:
		return
	_syncing = true
	_left.scroll_vertical = int(v)
	_syncing = false


## Render aligned rows from TextLineDiff.aligned_rows(). Both panes end with the
## same line count so rows line up.
func render_rows(rows: Array) -> void:
	var left_lines: PackedStringArray = PackedStringArray()
	var right_lines: PackedStringArray = PackedStringArray()
	for row in rows:
		var r := row as Dictionary
		match str(r.get("op", "equal")):
			"add":
				left_lines.append("")
				right_lines.append(str(r.get("right_text", "")))
			"del":
				left_lines.append(str(r.get("left_text", "")))
				right_lines.append("")
			_:  # equal or modify — both sides have a line
				left_lines.append(str(r.get("left_text", "")))
				right_lines.append(str(r.get("right_text", "")))
	_left.text = "\n".join(left_lines)
	_right.text = "\n".join(right_lines)

	for i in range(rows.size()):
		match str((rows[i] as Dictionary).get("op", "equal")):
			"add":
				_left.set_line_background_color(i, COL_GAP)
				_right.set_line_background_color(i, COL_ADD)
			"del":
				_left.set_line_background_color(i, COL_DEL)
				_right.set_line_background_color(i, COL_GAP)
			"modify":
				_left.set_line_background_color(i, COL_DEL)
				_right.set_line_background_color(i, COL_ADD)
