## EditorCodeEdit.gd – Complete Lint‑Clean Version
## Supports exact + fuzzy unified‑diff patching in Godot CodeEdit.

class_name EditorCodeEdit
extends CodeEdit

# ------------------------------------------------------------------
# Saved snapshot
# ------------------------------------------------------------------
var saved_content: String = ""

# ------------------------------------------------------------------
# Fuzzy‑matching configuration
# ------------------------------------------------------------------
const MAX_CONTEXT_FUZZ: int       = 2      # context lines allowed to differ
const INITIAL_SEARCH_RADIUS: int  = 20     # ± window start
const MAX_SEARCH_RADIUS: int      = 100    # ± window cap
const MIN_CONFIDENCE_SCORE: float = 0.60   # reject matches below this
const WHITESPACE_TOLERANCE: bool  = false  # ignore leading/trailing whitespace

# ------------------------------------------------------------------
# Preview state
# ------------------------------------------------------------------
var _applied_hunks: Array = []
var _pending_hunks: Array = []
var _preview_original_text: String = ""
var _preview_highlighted: Array = []
var _raw_diff: String = ""
# ------------------------------------------------------------------
# Godot lifecycle
# ------------------------------------------------------------------
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

# ==================================================================
# PUBLIC API – apply diff permanently
# ==================================================================
func apply_preview() -> void:
	clear_diff_preview()
	self.apply_diff(_raw_diff)

func apply_diff(diff: String) -> void:
	var hunks: Array = _parse_diff(diff)
	var lines: Array  = _text_to_lines(text)

	hunks.sort_custom(func(a, b) -> bool:
		return int(a["old_start"]) < int(b["old_start"])
	)

	var cumulative_offset: int = 0
	for h in hunks:
		var h2 = h.duplicate(true)
		h2["old_start"] = int(h["old_start"]) + cumulative_offset

		var res := _apply_hunk_fuzzy(lines, h2, true)
		print("apply_diff: hunk@%d → %s" % [h["old_start"]+1, res])
		if res.get("success", false):
			cumulative_offset += int(res.get("lines_added",0)) - int(res.get("lines_removed",0))
		else:
			push_warning("Hunk @%d failed: %s" % [int(h["old_start"])+1, res.get("message","")])

	text = "\n".join(lines)
	saved_content = text

# ==================================================================
# PUBLIC API – preview diff with highlights
# ==================================================================
func preview_diff(diff: String) -> void:
	_raw_diff = diff
	clear_diff_preview()
	_preview_original_text = text

	var doc_lines: Array = _text_to_lines(text)
	var hunks: Array     = _parse_diff(diff)
	var additions: Array = []
	var deletions: Array = []

	for h in hunks:
		var loc := _find_hunk_location(doc_lines, h)
		var conf := float(loc["confidence"])
		var uniq := bool(loc["unique"])
		var pos  := int(loc["position"])

		if conf < MIN_CONFIDENCE_SCORE or not uniq:
			_pending_hunks.append(h)
			continue
		
		var sim := _apply_hunk_fuzzy(doc_lines, h, false)
		if not sim.get("success", false):
			_pending_hunks.append(h)
			continue

		var body := h["body"] as Array
		var idx := pos
		for e in body:
			var t := str(e["type"])
			var c := str(e["content"])
			if t == " ":
				idx += 1
			elif t == "-":
				deletions.append(idx)
				idx += 1
			elif t == "+":
				doc_lines.insert(idx, c)
				additions.append(idx)
				idx += 1

	text = "\n".join(doc_lines)
	for i in additions: _highlight_line(i, Color(0.25,1,0.25,0.35))
	for i in deletions: _highlight_line(i, Color(1,0.25,0.25,0.35))

	if _pending_hunks.size() > 0:
		push_warning("AI Diff Preview: %d hunk(s) need review" % _pending_hunks.size())

func clear_diff_preview() -> void:
	if _preview_original_text == "":
		return
	text = _preview_original_text
	_preview_original_text = ""
	for ln in _preview_highlighted:
		if ln < get_line_count():
			set_line_background_color(ln, Color(0,0,0,0))
	_preview_highlighted.clear()
	_applied_hunks.clear()
	_pending_hunks.clear()

# ==================================================================
# DIFF PARSER
# ==================================================================
func _parse_diff(diff: String) -> Array:
	var hunks: Array = []
	var lines := diff.split("\n")
	var re := RegEx.new()
	re.compile("@@ -([0-9]+),?([0-9]*) \\+([0-9]+),?([0-9]*) @@")
	var i: int = 0
	while i < lines.size():
		var l := lines[i]
		if l.begins_with("@@"):
			var m := re.search(l)
			if m:
				var h := {
					"old_start": int(m.get_string(1))-1,
					"old_len"  : (1 if m.get_string(2)=="" else int(m.get_string(2))),
					"new_start": int(m.get_string(3))-1,
					"new_len"  : (1 if m.get_string(4)=="" else int(m.get_string(4))),
					"body"     : []
				}
				i += 1
				while i < lines.size() and not lines[i].begins_with("@@"):
					var bl := lines[i]
					if bl != "":
						var op := bl.substr(0,1)
						var ct := bl.substr(1)
						if op in [" ","-","+"]:
							(h["body"] as Array).append({"type":op, "content":ct})
					i += 1
				_heal_hunk_context(h)
				hunks.append(h)
				continue
		i += 1
	return hunks

func _heal_hunk_context(h: Dictionary) -> void:
	var ctx: int = 0
	var chg: bool = false
	for e in h["body"]:
		if e["type"] == " ": ctx += 1
		else: chg = true
	h["context_lines"] = ctx
	h["low_context"]   = (ctx < 3 and chg)

# ==================================================================
# HUNK LOCATION (fuzzy even for low‐context)
# ==================================================================
func _find_hunk_location(doc: Array, h: Dictionary) -> Dictionary:
	var exp := int(h["old_start"])
	var ctx := int(h.get("context_lines", 0))

	# Always do a limited fuzzy search ±INITIAL_SEARCH_RADIUS
	var patt: Array = []
	var pts: Array = []
	for e in h["body"]:
		var t := str(e["type"])
		if t in [" ", "-"]:
			patt.append(_normalize_line(str(e["content"])))
			pts.append(t)

	var best_p := -1
	var best_c := 0.0
	var ct := 0
	var rad := INITIAL_SEARCH_RADIUS

	while rad <= MAX_SEARCH_RADIUS:
		var start_idx: int = max(0, exp - rad)
		var end_idx:int = min(doc.size() - patt.size(), exp + rad)
		for pos in range(start_idx, end_idx + 1):
			var sc := _calculate_match_score(doc, pos, patt, pts, exp)
			if sc > best_c:
				best_c = sc
				best_p = pos
				ct = 1
			elif abs(sc - best_c) < 0.001 and sc > 0.5:
				ct += 1
		if best_c >= 0.8:
			break
		rad = min(rad * 2, MAX_SEARCH_RADIUS)
	var uniq := (ct == 1)

	# Fallback to header if no decent match
	if best_p < 0:
		best_p = exp
		best_c = 0.0
		uniq = false

	return {
		"position":   best_p,
		"confidence": best_c,
		"unique":     uniq
	}

func _calculate_match_score(doc: Array, pos:int, patt:Array, pts:Array, exp:int) -> float:
	if pos<0 or pos+patt.size()>doc.size(): return 0.0
	var m: float = 0.0
	var w: float = 0.0
	var tot:int = patt.size()
	for i in range(tot):
		var dl := _normalize_line(doc[pos+i])
		var pl = patt[i]
		if pl == dl:
			m += 1.0
			w += 1.2 if (pts[i]=="-") else 1.0
		elif _fuzzy_match(pl, dl):
			m += 0.7
			w += 0.8 if (pts[i]=="-") else 0.7
	if tot==0: return 0.0
	var base := m/float(tot)
	var weighted := w/(float(tot)*1.2)
	var dist = abs(pos-exp)
	var pen := (1.0 if dist==0 else clampf(1.0 - float(dist)/(MAX_SEARCH_RADIUS*2), 0.5, 1.0))
	return (base*0.5 + weighted*0.5) * pen

# ******************************************************************
# APPLY (or SIMULATE) A SINGLE HUNK – delete only '-' lines
# ******************************************************************
func _apply_hunk_fuzzy(doc: Array, h: Dictionary, permanent: bool) -> Dictionary:
	var loc  := _find_hunk_location(doc, h)
	var conf := float(loc["confidence"])
	var pos  := int(loc["position"])

	if conf < MIN_CONFIDENCE_SCORE:
		return {"success": false, "message": "Low confidence: %.2f" % conf}
	if pos < 0:
		return {"success": false, "message": "Location not found"}
	if not permanent:
		return {"success": true, "position": pos, "confidence": conf}

	# Build replacement lines and count deletions
	var original_count: int = 0
	var added_count:    int = 0
	var repl: Array = []
	for e in h["body"]:
		var t := str(e["type"])
		var c := str(e["content"])
		if t == "+":
			repl.append(c)
			added_count += 1
		elif t == "-":
			original_count += 1
		elif t == " ":
			# keep context lines intact
			repl.append(c)
		# note: context lines are not counted for deletion

	# Remove only the "-" lines at the found position
	var removed := 0
	var scan_pos := pos
	while removed < original_count and scan_pos < doc.size():
		if _normalize_line(doc[scan_pos]) == _normalize_line(h["body"][removed]["content"]):
			doc.remove_at(scan_pos)
			removed += 1
		else:
			scan_pos += 1

	# Insert all replacement lines
	for i in range(repl.size()):
		doc.insert(pos + i, repl[i])

	return {
		"success":      true,
		"position":     pos,
		"confidence":   conf,
		"lines_added":  added_count,
		"lines_removed": original_count
	}
# ------------------------------------------------------------------
# Utilities
# ------------------------------------------------------------------
func _normalize_line(s:String) -> String:
	return s.strip_edges() if WHITESPACE_TOLERANCE else s

func _fuzzy_match(a:String, b:String) -> bool:
	if a == b: return true
	if WHITESPACE_TOLERANCE and a.replace(" ","") == b.replace(" ",""): return true
	return false

func _text_to_lines(s:String) -> Array:
	return s.split("\n")

func _highlight_line(idx:int, col:Color) -> void:
	if idx<0 or idx>=get_line_count(): return
	set_line_background_color(idx, col)
	if not _preview_highlighted.has(idx):
		_preview_highlighted.append(idx)

func get_pending_hunks() -> Array:
	return _pending_hunks.duplicate()

func apply_pending_hunk_by_index(i:int) -> bool:
	if i<0 or i>=_pending_hunks.size(): return false
	var h = _pending_hunks[i]
	var lines := _text_to_lines(text)
	var res := _apply_hunk_fuzzy(lines, h, true)
	if res.get("success", false):
		text = "\n".join(lines)
		_pending_hunks.remove_at(i)
		_applied_hunks.append(h)
		return true
	push_warning("Manual apply failed: %s"%res.get("message",""))
	return false
