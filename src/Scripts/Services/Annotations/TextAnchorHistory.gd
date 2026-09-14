class_name TextAnchorHistory
extends RefCounted
## Keeps text-anchor positions on the same history graph as CodeEdit. Checkpoints
## contain anchors only; comment bodies and lifecycle remain owned by the host.

var _states: Array[Dictionary] = []
var _current := -1
var _epoch := 0
var _current_hash := ""
var _group_base_text := ""


func reset(text: String, version: int, anchors: Dictionary) -> void:
	_epoch += 1
	_states = [_state(text, version, anchors, [])]
	_current = 0
	_current_hash = _fingerprint(text)
	_group_base_text = ""


func record_anchor_state(text: String, version: int, anchors: Dictionary) -> void:
	if _current < 0:
		reset(text, version, anchors)
		return
	var current: Dictionary = _states[_current]
	if int(current.get("version", -1)) == version and str(current.get("hash", "")) == _fingerprint(text):
		current["anchors"] = anchors.duplicate(true)
		_states[_current] = current


## Returns anchor snapshots for the new text. Existing history endpoints restore
## exact positions; a divergent edit drops its abandoned redo branch.
func transition(old_text: String, new_text: String, version: int,
		anchors: Dictionary) -> Dictionary:
	if _current < 0 or _current_hash != _fingerprint(old_text):
		reset(old_text, version, anchors)
	record_anchor_state(old_text, int(_states[_current].get("version", version)), anchors)
	var target := _find_state(version, new_text)
	if target >= 0:
		var restored := _restore_to(target, anchors)
		_current = target
		_current_hash = _fingerprint(new_text)
		_group_base_text = ""
		return restored
	if _current + 1 < _states.size():
		_states.resize(_current + 1)
	var hunks := _diff_hunks(old_text, new_text)
	var moved := _apply_hunks_to_anchors(anchors, hunks, false)
	if _current >= 0 and int(_states[_current].get("version", -1)) == version \
			and _current > 0 and not _group_base_text.is_empty():
		var grouped_hunks := _diff_hunks(_group_base_text, new_text)
		_states[_current] = _state(new_text, version, moved, grouped_hunks)
	else:
		_group_base_text = old_text
		_states.append(_state(new_text, version, moved, hunks))
		_current = _states.size() - 1
	_current_hash = _fingerprint(new_text)
	_prune_expired_versions()
	return moved


func _restore_to(target: int, live: Dictionary) -> Dictionary:
	var checkpoint: Dictionary = (_states[target] as Dictionary).get("anchors", {})
	var restored := {}
	# An annotation created or retargeted after the checkpoint must not disappear
	# or regain its earlier anchor. Move that current generation over the same
	# text transitions instead.
	for annotation_id in live:
		var current_anchor: Dictionary = live[annotation_id]
		var prior: Variant = checkpoint.get(annotation_id, null)
		if prior is Dictionary and int((prior as Dictionary).get("generation", -1)) == int(current_anchor.get("generation", -2)):
			restored[annotation_id] = (prior as Dictionary).duplicate(true)
			continue
		var one := {annotation_id: current_anchor.duplicate(true)}
		if target < _current:
			for index in range(_current, target, -1):
				one = _apply_hunks_to_anchors(one, (_states[index] as Dictionary).get("hunks", []), true)
		else:
			for index in range(_current + 1, target + 1):
				one = _apply_hunks_to_anchors(one, (_states[index] as Dictionary).get("hunks", []), false)
		restored[annotation_id] = one[annotation_id]
	return restored


func _find_state(version: int, text: String) -> int:
	var wanted_hash := _fingerprint(text)
	for index in range(_states.size() - 1, -1, -1):
		var state: Dictionary = _states[index]
		if int(state.get("version", -1)) == version and str(state.get("hash", "")) == wanted_hash:
			return index
	return -1


func _state(text: String, version: int, anchors: Dictionary, hunks: Array) -> Dictionary:
	return {"epoch": _epoch, "version": version, "hash": _fingerprint(text),
		"anchors": anchors.duplicate(true), "hunks": hunks.duplicate(true)}


static func _fingerprint(text: String) -> String:
	return text.sha256_text()


func _prune_expired_versions() -> void:
	# Match TextEdit's configured operation window; grouped edits occupy one
	# state rather than one per keypress.
	var undo_limit := maxi(1, int(ProjectSettings.get_setting(
		"gui/common/text_edit_undo_stack_max_size", 1024)))
	while _states.size() > undo_limit + 1:
		_states.pop_front()
		_current -= 1


func _apply_hunks_to_anchors(anchors: Dictionary, hunks: Array, reverse: bool) -> Dictionary:
	var out := anchors.duplicate(true)
	var ordered := hunks.duplicate(true)
	if reverse:
		ordered.reverse()
	for hunk_v in ordered:
		var hunk: Dictionary = hunk_v
		# new_start is the hunk's position after every preceding hunk, which is
		# the coordinate space occupied while applying forward or reverse.
		var start := int(hunk.get("new_start", 0))
		var old_length := int(hunk.get("new_end" if reverse else "old_end", start)) \
			- int(hunk.get("new_start" if reverse else "old_start", start))
		var replacement_length := int(hunk.get("old_end" if reverse else "new_end", start)) \
			- int(hunk.get("old_start" if reverse else "new_start", start))
		var old_end := start + old_length
		var replacement_end := start + replacement_length
		for annotation_id in out:
			var record: Dictionary = out[annotation_id]
			record = _move_record(record, start, old_end, replacement_end,
				bool(hunk.get("conservative", false)))
			out[annotation_id] = record
	return out


static func _move_record(record: Dictionary, change_start: int, old_end: int,
		new_end: int, conservative: bool = false) -> Dictionary:
	var out := record.duplicate(true)
	var start := int(out.get("start", 0))
	var end := int(out.get("end", start))
	var delta := new_end - old_end
	if old_end <= start:
		start += delta
		end += delta
	elif change_start >= end:
		pass
	elif conservative:
		start = change_start
		end = change_start
		out["tracking_state"] = "tracking_unavailable"
	elif change_start <= start and old_end >= end:
		start = change_start
		end = new_end
		out["tracking_state"] = "text_removed" if end <= start else ""
	elif change_start <= start:
		start = new_end
		end += delta
	elif old_end >= end:
		end = new_end
	else:
		end += delta
	out["start"] = maxi(0, start)
	out["end"] = maxi(int(out["start"]), end)
	if int(out["end"]) > int(out["start"]):
		out["tracking_state"] = ""
	return out


## Myers produces ordered disjoint edit hunks, so separated multicaret edits do
## not collapse untouched text (or anchors within it) into one replacement.
static func _diff_hunks(before: String, after: String) -> Array:
	if before == after:
		return []
	var prefix := 0
	while prefix < before.length() and prefix < after.length() and before[prefix] == after[prefix]:
		prefix += 1
	var suffix := 0
	while suffix < before.length() - prefix and suffix < after.length() - prefix \
			and before[before.length() - suffix - 1] == after[after.length() - suffix - 1]:
		suffix += 1
	var old_middle := before.substr(prefix, before.length() - prefix - suffix)
	var new_middle := after.substr(prefix, after.length() - prefix - suffix)
	var n := old_middle.length()
	var m := new_middle.length()
	# Pathological whole-document replacements fail safe as one replacement;
	# ordinary typing and separated multicaret edits remain exact.
	if n + m > 16384:
		var partitioned := _partition_large_change(old_middle, new_middle, prefix)
		if not partitioned.is_empty():
			return partitioned
		return [{"old_start": prefix, "old_end": prefix + n,
			"new_start": prefix, "new_end": prefix + m, "conservative": true}]
	var frontier := {1: 0}
	var trace: Array = []
	var distance := 0
	var found := false
	for d in range(n + m + 1):
		if d > 1024:
			return [{"old_start": prefix, "old_end": prefix + n,
				"new_start": prefix, "new_end": prefix + m, "conservative": true}]
		trace.append(frontier.duplicate())
		for k in range(-d, d + 1, 2):
			var forward_x: int
			if k == -d or (k != d and int(frontier.get(k - 1, -1)) < int(frontier.get(k + 1, -1))):
				forward_x = int(frontier.get(k + 1, 0))
			else:
				forward_x = int(frontier.get(k - 1, 0)) + 1
			var forward_y := forward_x - k
			while forward_x < n and forward_y < m and old_middle[forward_x] == new_middle[forward_y]:
				forward_x += 1
				forward_y += 1
			frontier[k] = forward_x
			if forward_x >= n and forward_y >= m:
				distance = d
				found = true
				break
		if found:
			break
	var operations: Array = []
	var backtrack_x := n
	var backtrack_y := m
	for d in range(distance, 0, -1):
		var previous: Dictionary = trace[d]
		var k := backtrack_x - backtrack_y
		var previous_k: int
		if k == -d or (k != d and int(previous.get(k - 1, -1)) < int(previous.get(k + 1, -1))):
			previous_k = k + 1
		else:
			previous_k = k - 1
		var previous_x := int(previous.get(previous_k, 0))
		var previous_y := previous_x - previous_k
		while backtrack_x > previous_x and backtrack_y > previous_y:
			operations.append("equal")
			backtrack_x -= 1
			backtrack_y -= 1
		if backtrack_x == previous_x:
			operations.append("insert")
			backtrack_y -= 1
		else:
			operations.append("delete")
			backtrack_x -= 1
	while backtrack_x > 0 and backtrack_y > 0:
		operations.append("equal")
		backtrack_x -= 1
		backtrack_y -= 1
	operations.reverse()
	var hunks := _operations_to_hunks(operations)
	for hunk in hunks:
		(hunk as Dictionary)["old_start"] = int((hunk as Dictionary)["old_start"]) + prefix
		(hunk as Dictionary)["old_end"] = int((hunk as Dictionary)["old_end"]) + prefix
		(hunk as Dictionary)["new_start"] = int((hunk as Dictionary)["new_start"]) + prefix
		(hunk as Dictionary)["new_end"] = int((hunk as Dictionary)["new_end"]) + prefix
	return hunks


static func _partition_large_change(before: String, after: String, offset: int) -> Array:
	# A shared unique block divides distant small edits without retaining or
	# walking the untouched middle. Ambiguous/replaced regions remain fail-safe.
	const BLOCK := 128
	if before.length() < BLOCK or after.length() < BLOCK:
		return []
	for fraction in [0.5, 0.25, 0.75]:
		var after_pos := clampi(int(after.length() * float(fraction)) - (BLOCK >> 1),
			0, after.length() - BLOCK)
		var marker := after.substr(after_pos, BLOCK)
		var before_pos := before.find(marker)
		if before_pos < 0 or before.find(marker, before_pos + 1) >= 0 \
				or after.find(marker) != after_pos or after.find(marker, after_pos + 1) >= 0:
			continue
		var left := _diff_hunks(before.substr(0, before_pos), after.substr(0, after_pos))
		var right := _diff_hunks(before.substr(before_pos + BLOCK), after.substr(after_pos + BLOCK))
		_shift_hunks(left, offset, offset)
		_shift_hunks(right, offset + before_pos + BLOCK, offset + after_pos + BLOCK)
		left.append_array(right)
		return left
	return []


static func _shift_hunks(hunks: Array, old_offset: int, new_offset: int) -> void:
	for value in hunks:
		var hunk: Dictionary = value
		hunk["old_start"] = int(hunk.get("old_start", 0)) + old_offset
		hunk["old_end"] = int(hunk.get("old_end", 0)) + old_offset
		hunk["new_start"] = int(hunk.get("new_start", 0)) + new_offset
		hunk["new_end"] = int(hunk.get("new_end", 0)) + new_offset


static func _operations_to_hunks(operations: Array) -> Array:
	var hunks: Array = []
	var old_pos := 0
	var new_pos := 0
	var active: Dictionary = {}
	for operation in operations:
		if operation == "equal":
			if not active.is_empty():
				active["old_end"] = old_pos
				active["new_end"] = new_pos
				hunks.append(active)
				active = {}
			old_pos += 1
			new_pos += 1
		else:
			if active.is_empty():
				active = {"old_start": old_pos, "new_start": new_pos}
			if operation == "delete":
				old_pos += 1
			else:
				new_pos += 1
	if not active.is_empty():
		active["old_end"] = old_pos
		active["new_end"] = new_pos
		hunks.append(active)
	return hunks
