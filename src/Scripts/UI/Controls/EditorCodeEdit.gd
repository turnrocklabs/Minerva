## EditorCodeEdit.gd – Robust dual-buffer diff preview + apply
## Works with exact or fuzzy unified-diff hunks.

class_name EditorCodeEdit
extends CodeEdit


# ──────────────────────────────────────────────────────────────────
# Saved snapshot
# ──────────────────────────────────────────────────────────────────
var saved_content: String = ""


# ──────────────────────────────────────────────────────────────────
# Fuzzy-matching configuration
# ──────────────────────────────────────────────────────────────────
const MAX_CONTEXT_FUZZ     := 2      # context lines allowed to differ
const INITIAL_SEARCH_RADIUS:= 20     # ± window start
const MAX_SEARCH_RADIUS    := 100    # ± window cap
const MIN_CONFIDENCE_SCORE := 0.60   # reject matches below this
const WHITESPACE_TOLERANCE := false  # ignore leading/trailing whitespace


# ──────────────────────────────────────────────────────────────────
# Preview state
# ──────────────────────────────────────────────────────────────────
var _preview_original_text := ""
var _last_preview_text     := ""      # Patched file committed in Apply
var _raw_diff              := ""
var _preview_highlighted   : Array = []
var _pending_hunks         : Array = []
var _applied_hunks         : Array = []


# ──────────────────────────────────────────────────────────────────
# Godot lifecycle
# ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	size_flags_vertical           = SizeFlags.SIZE_EXPAND_FILL
	caret_blink                   = true
	highlight_all_occurrences     = true
	highlight_current_line        = true
	gutters_draw_line_numbers     = true
	gutters_zero_pad_line_numbers = true
	autowrap_mode                 = TextServer.AUTOWRAP_ARBITRARY
	wrap_mode                     = TextEdit.LINE_WRAPPING_BOUNDARY
	line_folding                  = true
	editable                      = true



# ══════════════════════════════════════════════════════════════════
# PUBLIC API – Apply preview permanently
# ══════════════════════════════════════════════════════════════════
func apply_preview() -> void:
	var combined_text = _text_to_lines(text)
	var output_buffer: Array[String] = []
	var line_count := len(combined_text)
	for idex in range(line_count):
		var bg_color = get_line_background_color(idex)
		if bg_color[0] != 1.0:
			output_buffer.append(combined_text[idex])
	var new_text_content := "\n".join(output_buffer)
	text = new_text_content
	
	# Reset all diff-related state to initial conditions
	_reset_diff_state()

func _reset_diff_state() -> void:
	# Clear all highlights
	for ln in _preview_highlighted:
		if ln < get_line_count():
			set_line_background_color(ln, Color(0, 0, 0, 0))
	
	# Reset all state variables to empty/initial values
	_preview_original_text = ""
	_last_preview_text = ""
	_raw_diff = ""
	_preview_highlighted.clear()
	_pending_hunks.clear()
	_applied_hunks.clear()

# ══════════════════════════════════════════════════════════════════
# PUBLIC API – Preview diff with highlights   (dual-buffer approach)
# ══════════════════════════════════════════════════════════════════
func preview_diff(diff: String) -> void:
	_raw_diff = diff
	clear_diff_preview()
	_preview_original_text = text

	var view_lines  := _text_to_lines(text)   # What the user will SEE
	var patch_lines := _text_to_lines(text)   # What will be COMMITTED
	var hunks       := _parse_diff(diff)
	var additions   := []
	var deletions   := []

	for h in hunks:
		# 1️⃣ Locate hunk once
		var loc := _find_hunk_location(view_lines, h)
		if not loc["unique"] or float(loc["confidence"]) < MIN_CONFIDENCE_SCORE:
			_pending_hunks.append(h)
			continue
		var pos := int(loc["position"])

		# 2️⃣ Apply permanently to patch_lines (true deletion + insertion)
		_apply_hunk_at_pos(patch_lines, h, pos)

		# 3️⃣ Simulate on view_lines (keep deletions, colour them)
		var idx := pos
		for e in h["body"]:
			var t := str(e["type"])
			var c := str(e["content"])
			match t:
				" ":
					idx += 1                      # context
				"-":
					deletions.append(idx)         # mark red, keep line
					idx += 1
				"+":
					view_lines.insert(idx, c)     # show green
					additions.append(idx)
					idx += 1

	# 4️⃣ Cache & display
	_last_preview_text = "\n".join(patch_lines)
	text               = "\n".join(view_lines)

	for i in additions:
		_highlight_line(i, Color(0.25, 1, 0.25, 0.35))
	for i in deletions:
		_highlight_line(i, Color(1, 0.25, 0.25, 0.35))

	if _pending_hunks.size() > 0:
		push_warning("AI Diff Preview: %d hunk(s) need review" %
					 _pending_hunks.size())



# ══════════════════════════════════════════════════════════════════
# PUBLIC API – Apply diff programmatically (no preview)
# ══════════════════════════════════════════════════════════════════
func apply_diff(diff: String) -> void:
	var lines  := _text_to_lines(text)
	for h in _parse_diff(diff):
		var loc := _find_hunk_location(lines, h)
		if float(loc["confidence"]) < MIN_CONFIDENCE_SCORE or not loc["unique"]:
			push_warning("Hunk skipped (low confidence)")
			continue
		_apply_hunk_at_pos(lines, h, int(loc["position"]))
	text = "\n".join(lines)
	saved_content = text



# ══════════════════════════════════════════════════════════════════
# Preview-cleanup helpers
# ══════════════════════════════════════════════════════════════════
func _clear_preview_highlights() -> void:
	for ln in _preview_highlighted:
		if ln < get_line_count():
			set_line_background_color(ln, Color(0, 0, 0, 0))
	_preview_highlighted.clear()
	_applied_hunks.clear()
	_pending_hunks.clear()
	_preview_original_text = ""
	_last_preview_text     = ""

func clear_diff_preview() -> void:
	if _preview_original_text != "":
		text = _preview_original_text
	_clear_preview_highlights()



# ══════════════════════════════════════════════════════════════════
# DIFF PARSER
# ══════════════════════════════════════════════════════════════════
func _parse_diff(diff: String) -> Array:
	var hunks : Array = []
	var lines := diff.split("\n")

	var re := RegEx.new()
	re.compile("@@ -([0-9]+),?([0-9]*) \\+([0-9]+),?([0-9]*) @@")

	var i := 0
	while i < lines.size():
		if lines[i].begins_with("@@"):
			var m := re.search(lines[i])
			if m:
				var h := {
					"old_start": int(m.get_string(1)) - 1,
					"old_len"  : (1 if m.get_string(2) == "" else int(m.get_string(2))),
					"new_start": int(m.get_string(3)) - 1,
					"new_len"  : (1 if m.get_string(4) == "" else int(m.get_string(4))),
					"body"     : []
				}
				i += 1
				while i < lines.size() and not lines[i].begins_with("@@"):
					var op := lines[i].substr(0, 1)
					var ct := lines[i].substr(1)
					if op in [" ", "-", "+"]:
						(h["body"] as Array).append({"type": op, "content": ct})
					i += 1
				hunks.append(h)
				continue
		i += 1
	return hunks



# ══════════════════════════════════════════════════════════════════
# HUNK LOCATION (fuzzy even for low-context)
# ══════════════════════════════════════════════════════════════════
func _find_hunk_location(doc: Array, h: Dictionary) -> Dictionary:
	var exp := int(h["old_start"])
	var patt:Array = []
	var pts :Array = []
	for e in h["body"]:
		if e["type"] in [" ", "-"]:
			patt.append(_normalize_line(e["content"]))
			pts.append(e["type"])

	var best_p := -1
	var best_c := 0.0
	var candidates := 0
	var rad := INITIAL_SEARCH_RADIUS

	while rad <= MAX_SEARCH_RADIUS:
		var start_idx:int = max(0, exp - rad)
		var end_idx:int = min(doc.size() - patt.size(), exp + rad)
		for pos in range(start_idx, end_idx + 1):
			var sc := _calculate_match_score(doc, pos, patt, pts, exp)
			if sc > best_c:
				best_c = sc
				best_p = pos
				candidates = 1
			elif abs(sc - best_c) < 0.001 and sc > 0.5:
				candidates += 1
		if best_c >= 0.8:
			break
		rad = min(rad * 2, MAX_SEARCH_RADIUS)

	if best_p == -1:
		best_p = exp     # fallback
		best_c = 0.0
		candidates = 1

	return {
		"position"  : best_p,
		"confidence": best_c,
		"unique"    : candidates == 1
	}

func _calculate_match_score(doc:Array, pos:int, patt:Array, pts:Array, exp:int) -> float:
	if pos < 0 or pos + patt.size() > doc.size():
		return 0.0
	var exact := 0.0
	var fuzzy := 0.0
	for i in range(patt.size()):
		var dl := _normalize_line(doc[pos + i])
		var pl = patt[i]
		if pl == dl:
			exact += 1.0
			fuzzy += 1.0 if pts[i] == "-" else 0.8
		elif _fuzzy_match(pl, dl):
			fuzzy += 0.7
	var base   := exact / patt.size()
	var weight := fuzzy / (patt.size() * 1.0)
	var dist   = abs(pos - exp)
	var pen    := (1.0 if dist == 0 else clampf(1.0 - float(dist) / (MAX_SEARCH_RADIUS * 2), 0.5, 1.0))
	return (base * 0.5 + weight * 0.5) * pen



# ══════════════════════════════════════════════════════════════════
# Apply one hunk at a **known** position (no extra search)
# ══════════════════════════════════════════════════════════════════
func _apply_hunk_at_pos(doc: Array, h: Dictionary, pos: int) -> void:
	# Walk through the hunk exactly in the order it appears
	var idx := pos                                # current position in `doc`

	for e in h["body"]:
		var t = e["type"]
		var c = e["content"]

		match t:
			" ":                                   # context
				idx += 1

			"-":                                   # deletion
				# If the expected line is exactly at idx, remove it.
				# Otherwise scan forward (helps with whitespace or duplicate lines).
				var k := idx
				while k < doc.size():
					if _normalize_line(doc[k]) == _normalize_line(c):
						doc.remove_at(k)
						break
					k += 1
				# Do NOT advance idx – the next original line
				# is now at the same index after the removal.

			"+":                                   # insertion
				doc.insert(idx, c)
				idx += 1                            # advance past the inserted line



# ══════════════════════════════════════════════════════════════════
# Utilities
# ══════════════════════════════════════════════════════════════════
func _normalize_line(s:String) -> String:
	return s.strip_edges() if WHITESPACE_TOLERANCE else s

func _fuzzy_match(a:String, b:String) -> bool:
	if a == b:
		return true
	if WHITESPACE_TOLERANCE and a.strip_edges() == b.strip_edges():
		return true
	return false

func _text_to_lines(s:String) -> Array:
	return s.split("\n")

func _highlight_line(idx:int, col:Color) -> void:
	if idx < 0 or idx >= get_line_count():
		return
	set_line_background_color(idx, col)
	if !_preview_highlighted.has(idx):
		_preview_highlighted.append(idx)



# ══════════════════════════════════════════════════════════════════
# Accessors for manual review tools
# ══════════════════════════════════════════════════════════════════
func get_pending_hunks() -> Array:
	return _pending_hunks.duplicate()

func apply_pending_hunk_by_index(i:int) -> bool:
	if i < 0 or i >= _pending_hunks.size():
		return false
	var h = _pending_hunks[i]
	var lines := _text_to_lines(text)
	var loc  := _find_hunk_location(lines, h)
	if not loc["unique"] or float(loc["confidence"]) < MIN_CONFIDENCE_SCORE:
		push_warning("Manual apply skipped (low confidence)")
		return false
	_apply_hunk_at_pos(lines, h, int(loc["position"]))
	text = "\n".join(lines)
	_pending_hunks.remove_at(i)
	_applied_hunks.append(h)
	return true
