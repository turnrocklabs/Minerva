class_name PassthroughTurnStatus
extends RefCounted
## W5 (chat-passthrough): live-status bookkeeping for one passthrough chat turn.
##
## A passthrough generate has NO LLM and emits ZERO tokens; while it is in
## flight the bound terminal's own agent is doing the work and printing its own
## mechanical status line (e.g. the working/"esc to interrupt" line). Core reads
## that PTY screen directly and relays it into the in-flight chat bubble so the
## turn LOOKS alive. This helper holds:
##   - the PURE screen-text -> compact-status heuristic (compact_status), and
##   - the per-turn poll bookkeeping (begin / mark_status / finish) so ChatPane
##     can stay thin and tests can assert the state machine headlessly.
##
## ChatPane owns the SceneTree timer and the session read; this object owns the
## STRING work and the in-flight/polling flags. No engine types are referenced
## so it is fully instantiable in a --script harness.

## Heuristic tuning. The agent's status chrome lives in the LAST few non-empty
## screen rows (box-drawing borders, the "esc to interrupt" line, a spinner).
const DEFAULT_MAX_LINES := 3
const DEFAULT_CAP := 160

## True between begin() and finish(): exactly one in-flight marker per turn.
var in_flight: bool = false

## True while the poll loop should keep running. Goes false the instant the
## generate resolves (success / error / cancel). ChatPane stops its timer when
## this clears; the flag is the headless-assertable "poll stopped" proof.
var polling: bool = false

## How the turn ended: "" while live, then "answer" / "question" / "cancelled"
## / "error". Lets a test assert the finalize disposition without UI.
var disposition: String = ""

## Last compact status pushed into the bubble (for idempotence + assertions).
var last_status: String = ""

## Count of distinct status mutations (a push that changed the text). Proves the
## relay MUTATES one node rather than appending new ones.
var status_updates: int = 0


## Begin a turn. Idempotent guard: re-begin without finish is a no-op so a
## double-send cannot spawn two poll loops on the same marker.
func begin() -> bool:
	if in_flight:
		return false
	in_flight = true
	polling = true
	disposition = ""
	last_status = ""
	status_updates = 0
	return true


## Push a freshly-read screen status. Returns the compact status that should be
## shown, or "" to leave the plain bubble untouched (empty / unchanged /
## no-session). Only counts as a mutation when the text actually changes.
func mark_status(screen_text: String) -> String:
	if not polling:
		return ""
	var compact := compact_status(screen_text)
	if compact.is_empty():
		# No usable status this tick - keep whatever the bubble shows. Do NOT
		# clear it (avoids flicker between agent redraws).
		return ""
	if compact == last_status:
		return ""
	last_status = compact
	status_updates += 1
	return compact


## Resolve the turn. Stops polling and records the disposition. Idempotent.
func finish(p_disposition: String) -> void:
	polling = false
	in_flight = false
	disposition = p_disposition


## PURE heuristic: collapse a terminal viewport dump into a single compact
## status line. Generic - no agent-specific parsing. Takes the last
## `max_lines` non-empty rows, single-line-collapses them (runs of whitespace ->
## one space, drops empty), joins with " ", and caps at `cap` chars (with an
## ellipsis when truncated). Empty / whitespace-only input -> "".
static func compact_status(screen_text: String, max_lines: int = DEFAULT_MAX_LINES,
		cap: int = DEFAULT_CAP) -> String:
	if screen_text == null:
		return ""
	var raw_lines := screen_text.split("\n")
	# Collect non-empty (post-strip) rows from the BOTTOM up.
	var picked: Array[String] = []
	for i in range(raw_lines.size() - 1, -1, -1):
		var line := _collapse_ws(raw_lines[i])
		if line.is_empty():
			continue
		picked.push_front(line)
		if picked.size() >= max_lines:
			break
	if picked.is_empty():
		return ""
	var joined := " ".join(picked)
	# Final collapse in case the join introduced double spaces at seams.
	joined = _collapse_ws(joined)
	if joined.length() > cap:
		# Reserve one char for the ellipsis so the result is exactly <= cap.
		joined = joined.substr(0, maxi(0, cap - 1)).strip_edges() + "…"
	return joined


## Collapse all runs of whitespace (incl. tabs / CR / NBSP) into single spaces
## and trim. Pure string work - codepoint checks so no exotic literal chars.
static func _collapse_ws(s: String) -> String:
	var out := ""
	var prev_space := false
	for i in s.length():
		var cp := s.unicode_at(i)
		# Treat space, tab, CR, LF, control chars and NBSP (0xA0) as whitespace.
		if cp <= 0x20 or cp == 0xA0:
			if not prev_space:
				out += " "
			prev_space = true
		else:
			out += String.chr(cp)
			prev_space = false
	return out.strip_edges()
