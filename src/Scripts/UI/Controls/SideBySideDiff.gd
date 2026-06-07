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
	# Horizontal sync too, so aligned lines stay aligned when scrolling sideways.
	var lhs := _left.get_h_scroll_bar()
	var rhs := _right.get_h_scroll_bar()
	if lhs:
		lhs.value_changed.connect(_on_left_hscroll)
	if rhs:
		rhs.value_changed.connect(_on_right_hscroll)


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


func _on_left_hscroll(v: float) -> void:
	if _syncing:
		return
	_syncing = true
	_right.scroll_horizontal = int(v)
	_syncing = false


func _on_right_hscroll(v: float) -> void:
	if _syncing:
		return
	_syncing = true
	_left.scroll_horizontal = int(v)
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

	# Two-level highlighting: whole-line tint (below) + intra-line "focus" on the
	# changed words (a brighter foreground via a per-line syntax highlighter).
	var lh := _WordHighlighter.new()
	var rh := _WordHighlighter.new()
	lh.hi = Color(1.0, 0.55, 0.55)   # changed words on the left (removed)
	rh.hi = Color(0.55, 1.0, 0.55)   # changed words on the right (added)
	lh.base = _left.get_theme_color("font_color", "CodeEdit")
	rh.base = _right.get_theme_color("font_color", "CodeEdit")

	for i in range(rows.size()):
		var r := rows[i] as Dictionary
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
				# Focus-highlight just the changed characters on each side.
				var cr := TextLineDiff.char_ranges(str(r.get("left_text", "")), str(r.get("right_text", "")))
				if not (cr["left"] as Array).is_empty():
					lh.spans[i] = cr["left"]
				if not (cr["right"] as Array).is_empty():
					rh.spans[i] = cr["right"]
	_left.syntax_highlighter = lh
	_right.syntax_highlighter = rh


## Per-line foreground highlighter: colors the changed-character columns of each
## modified line a brighter "focus" color over the line tint (Beyond Compare's
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
