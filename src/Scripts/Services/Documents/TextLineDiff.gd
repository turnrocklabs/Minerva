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
