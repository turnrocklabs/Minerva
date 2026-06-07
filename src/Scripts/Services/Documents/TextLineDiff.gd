class_name TextLineDiff
extends RefCounted
## Line-level diff between two text snapshots, GDScript-only (work item
## 019ea01719a2 — the change-journal backbone). Core has no line-diff today: the
## codetools worker uses Python difflib and the old panel used JS lcsDiff. The
## change journal and the native review render share THIS one.
##
## diff(before, after) -> {
##   added:   PackedInt32Array  # line indices in AFTER that are new (green)
##   removed: Array[{after_index:int, text:String}]  # deleted lines + where they
##            sat in AFTER coords (for red "ghost" rows in the review render)
##   adds:int, dels:int
## }
##
## Strategy: trim the common prefix + suffix (localized edits => tiny middle),
## then LCS only the differing middle. Keeps the O(n*m) table small in the common
## case and bounds cost on big files.


static func diff(before: String, after: String) -> Dictionary:
	var a := before.split("\n")
	var b := after.split("\n")
	var n := a.size()
	var m := b.size()

	# Common prefix.
	var p := 0
	while p < n and p < m and a[p] == b[p]:
		p += 1
	# Common suffix (not crossing the prefix).
	var s := 0
	while s < (n - p) and s < (m - p) and a[n - 1 - s] == b[m - 1 - s]:
		s += 1

	var mid_a := a.slice(p, n - s)
	var mid_b := b.slice(p, m - s)

	var added := PackedInt32Array()
	var removed: Array = []

	# LCS over the differing middle, then backtrack into an edit script mapped to
	# AFTER coordinates (bi starts at the prefix length).
	var ops := _lcs_ops(mid_a, mid_b)
	var bi := p
	for op in ops:
		match op[0]:
			"equal":
				bi += 1
			"add":
				added.append(bi)
				bi += 1
			"del":
				removed.append({"after_index": bi, "text": op[1]})

	return {
		"added": added,
		"removed": removed,
		"adds": added.size(),
		"dels": removed.size(),
	}


## Intra-line CHANGED character spans for a modified line pair (Beyond Compare's
## word-level focus highlight). Trims the common prefix + suffix; the differing
## middle on each side is the changed span. Returns {left:[[start,end]], right:
## [[start,end]]} (half-open columns); empty array when a side has no change.
## v1 = one span per side (the common case: a single localized edit). A
## multi-span char-LCS is a possible refinement.
static func char_ranges(a: String, b: String) -> Dictionary:
	var p := 0
	while p < a.length() and p < b.length() and a[p] == b[p]:
		p += 1
	var s := 0
	while s < (a.length() - p) and s < (b.length() - p) and a[a.length() - 1 - s] == b[b.length() - 1 - s]:
		s += 1
	var left: Array = []
	var right: Array = []
	if a.length() - s > p:
		left.append([p, a.length() - s])
	if b.length() - s > p:
		right.append([p, b.length() - s])
	return {"left": left, "right": right}


## Aligned rows for a SIDE-BY-SIDE (Beyond Compare-style) view: one row per
## visual line, pairing changed lines left/right. Each row is:
##   {op: "equal"|"add"|"del"|"modify",
##    left_line:int,  left_text:String,    # left_line == -1 => gap (no before line)
##    right_line:int, right_text:String}   # right_line == -1 => gap (no after line)
## add  -> left gap, right new (green). del -> left old (red), right gap.
## modify -> a deleted line paired with an added line (changed line, both panes).
## Line numbers are 0-based into before (left) / after (right).
static func aligned_rows(before: String, after: String) -> Array:
	var a := before.split("\n")
	var b := after.split("\n")
	var ops := _lcs_ops(a, b)
	var rows: Array = []
	var pend_del: Array = []
	var pend_add: Array = []
	var li := 0
	var ri := 0
	for op in ops:
		match op[0]:
			"equal":
				_flush_block(pend_del, pend_add, rows)
				rows.append({"op": "equal", "left_line": li, "left_text": a[li], "right_line": ri, "right_text": b[ri]})
				li += 1
				ri += 1
			"del":
				pend_del.append({"line": li, "text": a[li]})
				li += 1
			"add":
				pend_add.append({"line": ri, "text": b[ri]})
				ri += 1
	_flush_block(pend_del, pend_add, rows)
	return rows


## Flush a buffered change block: zip pending deletions with pending additions
## into paired "modify" rows; surplus on either side becomes "del"/"add" rows.
static func _flush_block(pend_del: Array, pend_add: Array, rows: Array) -> void:
	var n := maxi(pend_del.size(), pend_add.size())
	for k in range(n):
		var has_left := k < pend_del.size()
		var has_right := k < pend_add.size()
		var row := {
			"left_line": int(pend_del[k]["line"]) if has_left else -1,
			"left_text": str(pend_del[k]["text"]) if has_left else "",
			"right_line": int(pend_add[k]["line"]) if has_right else -1,
			"right_text": str(pend_add[k]["text"]) if has_right else "",
		}
		if has_left and has_right:
			row["op"] = "modify"
		elif has_right:
			row["op"] = "add"
		else:
			row["op"] = "del"
		rows.append(row)
	pend_del.clear()
	pend_add.clear()


## Edit script for two line arrays via LCS. Returns ordered ops:
## ["equal"], ["add", <b line>], ["del", <a line>].
static func _lcs_ops(a: PackedStringArray, b: PackedStringArray) -> Array:
	var n := a.size()
	var m := b.size()
	if n == 0 and m == 0:
		return []
	if n == 0:
		var only_adds: Array = []
		for line in b:
			only_adds.append(["add", line])
		return only_adds
	if m == 0:
		var only_dels: Array = []
		for line in a:
			only_dels.append(["del", line])
		return only_dels

	# LCS length table ((n+1) x (m+1)).
	var dp: Array = []
	for i in range(n + 1):
		var row := PackedInt32Array()
		row.resize(m + 1)
		dp.append(row)
	for i in range(n - 1, -1, -1):
		var dpi: PackedInt32Array = dp[i]
		var dpi1: PackedInt32Array = dp[i + 1]
		for j in range(m - 1, -1, -1):
			if a[i] == b[j]:
				dpi[j] = dpi1[j + 1] + 1
			else:
				dpi[j] = maxi(dpi1[j], dpi[j + 1])

	# Backtrack into an ordered edit script.
	var ops: Array = []
	var i := 0
	var j := 0
	while i < n and j < m:
		if a[i] == b[j]:
			ops.append(["equal"])
			i += 1
			j += 1
		elif int((dp[i + 1] as PackedInt32Array)[j]) >= int((dp[i] as PackedInt32Array)[j + 1]):
			ops.append(["del", a[i]])
			i += 1
		else:
			ops.append(["add", b[j]])
			j += 1
	while i < n:
		ops.append(["del", a[i]])
		i += 1
	while j < m:
		ops.append(["add", b[j]])
		j += 1
	return ops
