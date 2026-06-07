class_name SideBySideDiff
extends VBoxContainer
## Beyond Compare / Odd-style two-pane review diff (work item 019ea06a1413).
##
## A toolbar ("change i/N" + ▲▼) over two read-only panes rendered from
## TextLineDiff.aligned_rows():
##   left  = BEFORE (deletions red), right = AFTER (additions green)
## with: 1:1 row alignment (dim gap rows), two-level highlighting (whole-line
## tint + changed-word focus color), real per-side line numbers (gaps blank),
## and synchronized vertical + horizontal scroll. A SEPARATE view — it does NOT
## touch the real document buffer, so annotations/refs on the real file are safe.

var _left: CodeEdit
var _right: CodeEdit
var _label: Label
var _syncing := false
var _hunks: Array = []   # row indices that start a change hunk
var _cur_hunk := -1

const COL_ADD := Color(0.25, 1.0, 0.25, 0.18)
const COL_DEL := Color(1.0, 0.30, 0.30, 0.18)
const COL_GAP := Color(0.5, 0.5, 0.5, 0.10)
const _GUT := 0   # custom line-number gutter


func _init() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL

	var bar := HBoxContainer.new()
	var prev := Button.new()
	prev.text = "▲"
	prev.tooltip_text = "Previous change"
	prev.pressed.connect(prev_change)
	var next := Button.new()
	next.text = "▼"
	next.tooltip_text = "Next change"
	next.pressed.connect(next_change)
	_label = Label.new()
	_label.text = "no changes"
	bar.add_child(prev)
	bar.add_child(next)
	bar.add_child(_label)
	add_child(bar)

	var split := HSplitContainer.new()
	split.size_flags_horizontal = SIZE_EXPAND_FILL
	split.size_flags_vertical = SIZE_EXPAND_FILL
	_left = _make_pane()
	_right = _make_pane()
	split.add_child(_left)
	split.add_child(_right)
	add_child(split)


func _make_pane() -> CodeEdit:
	var ce := CodeEdit.new()
	ce.editable = false
	ce.gutters_draw_line_numbers = false   # we draw real per-side numbers instead
	ce.highlight_current_line = false
	ce.size_flags_horizontal = SIZE_EXPAND_FILL
	ce.size_flags_vertical = SIZE_EXPAND_FILL
	ce.add_gutter(_GUT)
	ce.set_gutter_type(_GUT, TextEdit.GUTTER_TYPE_STRING)
	ce.set_gutter_draw(_GUT, true)
	ce.set_gutter_width(_GUT, 56)
	return ce


func _ready() -> void:
	_connect_scroll(_left.get_v_scroll_bar(), _on_left_scroll)
	_connect_scroll(_right.get_v_scroll_bar(), _on_right_scroll)
	_connect_scroll(_left.get_h_scroll_bar(), _on_left_hscroll)
	_connect_scroll(_right.get_h_scroll_bar(), _on_right_hscroll)


func _connect_scroll(bar: Object, cb: Callable) -> void:
	if bar:
		bar.value_changed.connect(cb)


func _on_left_scroll(v: float) -> void:
	_mirror(func(): _right.scroll_vertical = int(v))

func _on_right_scroll(v: float) -> void:
	_mirror(func(): _left.scroll_vertical = int(v))

func _on_left_hscroll(v: float) -> void:
	_mirror(func(): _right.scroll_horizontal = int(v))

func _on_right_hscroll(v: float) -> void:
	_mirror(func(): _left.scroll_horizontal = int(v))

func _mirror(action: Callable) -> void:
	if _syncing:
		return
	_syncing = true
	action.call()
	_syncing = false


## Render aligned rows from TextLineDiff.aligned_rows(). Both panes end with the
## same line count so rows line up.
func render_rows(rows: Array) -> void:
	var left_lines := PackedStringArray()
	var right_lines := PackedStringArray()
	for row in rows:
		var r := row as Dictionary
		match str(r.get("op", "equal")):
			"add":
				left_lines.append("")
				right_lines.append(str(r.get("right_text", "")))
			"del":
				left_lines.append(str(r.get("left_text", "")))
				right_lines.append("")
			_:
				left_lines.append(str(r.get("left_text", "")))
				right_lines.append(str(r.get("right_text", "")))
	_left.text = "\n".join(left_lines)
	_right.text = "\n".join(right_lines)

	var lh := _WordHighlighter.new()
	var rh := _WordHighlighter.new()
	lh.hi = Color(1.0, 0.55, 0.55)
	rh.hi = Color(0.55, 1.0, 0.55)
	lh.base = _left.get_theme_color("font_color", "CodeEdit")
	rh.base = _right.get_theme_color("font_color", "CodeEdit")

	for i in range(rows.size()):
		var r := rows[i] as Dictionary
		# Real per-side line numbers; blank on the gap side.
		var ll := int(r.get("left_line", -1))
		var rl := int(r.get("right_line", -1))
		_left.set_line_gutter_text(i, _GUT, str(ll + 1) if ll >= 0 else "")
		_right.set_line_gutter_text(i, _GUT, str(rl + 1) if rl >= 0 else "")
		match str(r.get("op", "equal")):
			"add":
				_left.set_line_background_color(i, COL_GAP)
				_right.set_line_background_color(i, COL_ADD)
			"del":
				_left.set_line_background_color(i, COL_DEL)
				_right.set_line_background_color(i, COL_GAP)
			"modify":
				_left.set_line_background_color(i, COL_DEL)
				_right.set_line_background_color(i, COL_ADD)
				var cr := TextLineDiff.char_ranges(str(r.get("left_text", "")), str(r.get("right_text", "")))
				if not (cr["left"] as Array).is_empty():
					lh.spans[i] = cr["left"]
				if not (cr["right"] as Array).is_empty():
					rh.spans[i] = cr["right"]
	_left.syntax_highlighter = lh
	_right.syntax_highlighter = rh

	_compute_hunks(rows)


## Change hunks = contiguous runs of non-equal rows. Stores the start row of each.
func _compute_hunks(rows: Array) -> void:
	_hunks.clear()
	var in_hunk := false
	for i in range(rows.size()):
		var is_change := str((rows[i] as Dictionary).get("op", "equal")) != "equal"
		if is_change and not in_hunk:
			_hunks.append(i)
		in_hunk = is_change
	_cur_hunk = -1
	_update_label()


func _update_label() -> void:
	if _hunks.is_empty():
		_label.text = "no changes"
	elif _cur_hunk < 0:
		_label.text = "%d changes" % _hunks.size()
	else:
		_label.text = "change %d/%d" % [_cur_hunk + 1, _hunks.size()]


func next_change() -> void:
	_goto_hunk(1)

func prev_change() -> void:
	_goto_hunk(-1)

func _goto_hunk(dir: int) -> void:
	if _hunks.is_empty():
		return
	_cur_hunk = wrapi(_cur_hunk + dir, 0, _hunks.size())
	var row: int = int(_hunks[_cur_hunk])
	# Move caret + select the hunk line on both panes so the jump is VISIBLE even
	# when the content fits without scrolling (read-only selection still renders).
	for ce: CodeEdit in [_left, _right]:
		if row < ce.get_line_count():
			ce.set_caret_line(row)
			ce.set_caret_column(0)
			ce.select(row, 0, row, ce.get_line(row).length())
			ce.center_viewport_to_caret()
	_update_label()


## Per-line foreground highlighter: tints the changed-character columns of each
## modified line a brighter focus color over the line tint (Beyond Compare's
## word-level layer). spans: line_index -> Array of [start, end] column ranges.
class _WordHighlighter extends SyntaxHighlighter:
	var spans: Dictionary = {}
	var hi: Color = Color(1, 1, 0)
	var base: Color = Color(0.85, 0.85, 0.85)

	func _get_line_syntax_highlighting(line: int) -> Dictionary:
		var out: Dictionary = {}
		if not spans.has(line):
			return out
		out[0] = {"color": base}
		for r in spans[line]:
			out[int(r[0])] = {"color": hi}
			out[int(r[1])] = {"color": base}
		return out
