extends RefCounted

## The single gate every byte passes on its way to one TerminalSession's PTY.
##
## Two kinds of traffic meet here. Ordinary writes (a person's keystrokes, an
## agent's raw text) go straight through. A WRITE TRANSACTION — a body, a
## pause, then an Enter — is admitted once and owns the PTY until it finishes:
## anything submitted while it is in flight is queued and released afterwards,
## in order and unchanged, so a keystroke can never land between the body and
## its Enter and be submitted with it.
##
## The pause is a scene-tree timer, never a sleep: the main thread keeps
## pumping the PTY while the transaction waits.
##
## Every admitted transaction gets an id and a record ({id, phase, outcome,
## ...}) that outlives it, so a caller that only saw the admission can still
## ask how it ended. Refusals never get an id: nothing was written.

## Emitted as an admitted transaction moves through its phases. Handlers run
## inside the write path, so a handler that submits input is queued like any
## other input.
signal transaction_phase(txn_id: int, phase: String)

## Emitted once per admitted transaction, after its queue has been released.
signal transaction_finished(txn_id: int, record: Dictionary)

# Phases, in order. FINISHED is terminal and always carries an outcome.
const PHASE_ADMITTED := "admitted"
const PHASE_BODY_WRITTEN := "body_written"
const PHASE_ENTER_WRITTEN := "enter_written"
const PHASE_FINISHED := "finished"

# Outcomes of an admitted transaction.
const OUTCOME_COMMITTED := "committed"
const OUTCOME_OVERFLOW := "aborted_queue_overflow"
const OUTCOME_SHELL_EXITED := "partial_shell_exited"

# Outcomes of a refusal (no id, no bytes).
const OUTCOME_REFUSED_TYPING := "refused_human_typing"
const OUTCOME_REFUSED_HARNESS := "refused_expect_harness"
const OUTCOME_REFUSED_BUSY := "refused_transaction_in_flight"
const OUTCOME_REFUSED_DEAD := "refused_session_not_writable"
const OUTCOME_REFUSED_EMPTY := "refused_empty_body"
const OUTCOME_REFUSED_COMPOSER := "refused_composer_not_empty"
const OUTCOME_REFUSED_PROCESS := "refused_expect_process"
const OUTCOME_REFUSED_WITHDRAWN := "refused_write_withdrawn"
const OUTCOME_REFUSED_PANE_MODE := "refused_pane_mode"

# How the expect_harness guard was resolved, as reported back to the caller.
const HARNESS_NOT_REQUESTED := "not_requested"
const HARNESS_CHECKED := "checked"
const HARNESS_SKIPPED := "skipped"

# How the composer guard was resolved, reported the same way.
const COMPOSER_NOT_REQUESTED := "not_requested"
const COMPOSER_CHECKED := "checked"
const COMPOSER_SKIPPED := "skipped"

# The agent container's tmux pane, as the pane-mode guard found it (see
# TerminalSession.pane_mode): reported back like the checks above.
const PANE_MODE_NOT_REQUESTED := "not_requested"
const PANE_MODE_NOT_CONTAINER := "not_container"
const PANE_MODE_LIVE := "live"
const PANE_MODE_ACTIVE := "in_mode"
const PANE_MODE_UNKNOWN := "unknown"

## Write tickets: a caller that may still withdraw a write it has handed on
## (a relay round trip, say) issues one, passes it with the write, and
## revokes it to withdraw. A write carrying a ticket that is revoked or was
## never issued is refused. Tickets live for this Minerva process.
static var _tickets: Dictionary = {}
static var _ticket_serial: int = 0


static func issue_ticket() -> String:
	_ticket_serial += 1
	var ticket: String = "wt-%d" % _ticket_serial
	_tickets[ticket] = true
	return ticket


static func revoke_ticket(ticket: String) -> void:
	_tickets.erase(ticket)


static func ticket_valid(ticket: String) -> bool:
	return _tickets.has(ticket)


## The phrase every composer refusal contains. A caller that only sees the
## message — the relay hands the host's error back as prose — tells this hold
## apart from a screen hold by this phrase.
const COMPOSER_HOLD_PHRASE := "holds unsent text"

## Where each harness draws its input box, as the glyphs that open the row at
## column 0. Claude Code renders `❯` everywhere but Windows, where the same box
## comes through ConPTY as ASCII `>`; in its shell mode (`!`) and memo mode
## (`#`) the row opens with that prefix instead. Codex renders `›` (U+203A).
## The chat glyphs are the host-side twin of the relay's prompt_box_regex
## (agent-relay profiles.rs): change one and change the other.
const COMPOSER_MARKERS := {
	"claude": ["❯", ">", "!", "#"],
	"codex": ["›"],
}

## The cell Claude Code draws after its marker: a no-break space, not U+0020.
const NBSP := 0x00A0

## The Unicode box-drawing block (U+2500-U+257F). A row whose visible
## characters all come from it carries no text — it is box chrome, or a rule a
## person pasted — so the region READS PAST it. It never ends the region.
const RULE_GLYPH_FIRST := 0x2500
const RULE_GLYPH_LAST := 0x257F

const DEFAULT_QUEUE_LIMIT := 64
const DEFAULT_PAUSE_MS := 150
const ENTER := "\r"

## Bound on input held back during a transaction. On overflow the human wins:
## the transaction is aborted before its Enter and everything queued — the
## overflowing entry included — goes to the PTY in arrival order. Once the
## Enter has gone out there is nothing to abort, so overflow past that point
## only releases the queue with the completion.
var queue_limit: int = DEFAULT_QUEUE_LIMIT

var _session: Node = null
var _next_txn_id: int = 1
# The in-flight transaction's record, or {} when nothing holds the PTY.
var _active: Dictionary = {}
var _queue: Array[String] = []
# txn_id -> record, kept after the transaction ends.
var _records: Dictionary = {}


## Binds the arbiter to its session. Called once, by the session itself.
func setup(session: Node) -> void:
	_session = session
	if _session.has_signal("shell_exited"):
		_session.shell_exited.connect(_on_shell_exited)


# ── Ordinary writes ────────────────────────────────────────────────────

## The entry every raw write uses. `human` only colours the record; both kinds
## of traffic queue identically, because ordering is what must be preserved.
## Returns {success, queued} plus, on an overflow, the transaction it aborted.
func submit(text: String, human: bool = false) -> Dictionary:
	if text.is_empty():
		return {"success": true, "queued": false, "bytes_sent": 0}
	if _active.is_empty():
		_write_through(text)
		return {"success": true, "queued": false, "bytes_sent": text.length()}
	_queue.append(text)
	if human:
		_active["queued_human"] = int(_active.get("queued_human", 0)) + 1
	# Past the Enter there is nothing left to protect: the body and its submit
	# have both gone out, so overflowing input is simply released with the rest
	# when the transaction completes, instead of "aborting" a transaction that
	# has already written everything it was going to write.
	if _queue.size() > queue_limit and str(_active["phase"]) != PHASE_ENTER_WRITTEN:
		var aborted: int = int(_active["id"])
		_finish(OUTCOME_OVERFLOW, "%d entries queued behind the transaction exceeded the bound of %d; the Enter was not sent" % [
			_queue.size(), queue_limit])
		return {"success": true, "queued": true, "released": true,
			"aborted_transaction": aborted, "outcome": OUTCOME_OVERFLOW}
	return {"success": true, "queued": true, "queue_depth": _queue.size(),
		"transaction": int(_active["id"])}


## How many entries are waiting behind the in-flight transaction.
func queue_depth() -> int:
	return _queue.size()


func is_transaction_active() -> bool:
	return not _active.is_empty()


## The record of an admitted transaction, or {} if that id never existed.
## The returned dictionary is the live record while the transaction runs.
func get_transaction(txn_id: int) -> Dictionary:
	return _records.get(txn_id, {})


# ── Write transactions ─────────────────────────────────────────────────

## Admit a guarded body + Enter, or refuse it. Options:
##   pause_ms                — delay between body and Enter (default 150)
##   enter                   — the submit bytes (default CR)
##   unless_typed_within_ms  — refuse if a person typed here that recently
##   expect_harness          — refuse unless that harness is in front; the
##                             check is SKIPPED, and said to be, where the
##                             platform cannot read the foreground at all
##   refuse_if_composer_holds_text — refuse if the harness's input box holds
##                             a line a person typed but never submitted
## Every guard is checked once, here: an admitted transaction is not
## re-guarded, and its body is written exactly once and never replayed.
## Returns {success:true, txn_id, phase, harness_check, composer_check, ...} on
## admission, or a refusal shaped like the write guard: {success:false,
## held:true, error}.
func begin_transaction(body: String, options: Dictionary = {}) -> Dictionary:
	if body.is_empty():
		return _refusal(OUTCOME_REFUSED_EMPTY, "a transaction body is required; nothing was written")
	if not _active.is_empty():
		return _refusal(OUTCOME_REFUSED_BUSY,
			"transaction %d still holds this terminal; nothing was written" % int(_active["id"]))
	if not _session_writable():
		# Deliberately without the "nothing was written" hold phrase: callers that
		# retry on a hold read that phrase, and a terminal whose shell is gone
		# will never accept a retry.
		return _refusal(OUTCOME_REFUSED_DEAD, "this terminal has exited; no write is possible")
	var tree: SceneTree = _session.get_tree()
	if tree == null:
		return _refusal(OUTCOME_REFUSED_DEAD,
			"this terminal is not in the scene tree, so the Enter cannot be timed; nothing was written")

	var guards: Dictionary = check_guards(options)
	if not bool(guards.get("success", false)):
		return guards
	var harness_check: String = str(guards.get("harness_check", HARNESS_NOT_REQUESTED))
	var composer_check: String = str(guards.get("composer_check", COMPOSER_NOT_REQUESTED))
	var pane_mode_check: String = str(guards.get("pane_mode_check", PANE_MODE_NOT_REQUESTED))

	var txn_id: int = _next_txn_id
	_next_txn_id += 1
	var pause_ms: int = maxi(0, int(options.get("pause_ms", DEFAULT_PAUSE_MS)))
	var record: Dictionary = {
		"id": txn_id,
		"phase": PHASE_ADMITTED,
		"outcome": "",
		"harness_check": harness_check,
		"composer_check": composer_check,
		"pane_mode_check": pane_mode_check,
		"pause_ms": pause_ms,
		"enter": str(options.get("enter", ENTER)),
		"body_bytes": body.length(),
		# Bytes of the body that actually reached the PTY: still 0 until the
		# write below, because a handler can end this transaction before it.
		"bytes_sent": 0,
		"queued_human": 0,
		"released": 0,
		"detail": "",
	}
	_records[txn_id] = record
	_evict_finished_records()
	_active = record
	transaction_phase.emit(txn_id, PHASE_ADMITTED)

	# A phase handler runs inside that emit and may submit enough input to
	# overflow the queue — which finishes this transaction — or even start
	# another one. Being the ACTIVE id is what makes the body safe to write:
	# written after a replacement was admitted it would interleave between
	# that transaction's body and its Enter, and written after an overflow it
	# would follow the keys that aborted it. So the id is checked, and when it
	# is no longer active nothing more is written or recorded.
	if not _is_active(txn_id):
		return _admission_receipt(record)

	_write_through(body)
	record["bytes_sent"] = body.length()
	record["phase"] = PHASE_BODY_WRITTEN
	transaction_phase.emit(txn_id, PHASE_BODY_WRITTEN)
	# The timer is armed whatever that emit did: _on_pause_elapsed checks the
	# same active id, so an aborted or replaced transaction gets no Enter.
	tree.create_timer(pause_ms / 1000.0).timeout.connect(_on_pause_elapsed.bind(txn_id))
	return _admission_receipt(record)


## The caller's copy of a record, read off the record itself rather than off
## the phase the admission last set — a handler may already have ended it.
func _admission_receipt(record: Dictionary) -> Dictionary:
	var receipt: Dictionary = {"success": true, "txn_id": int(record["id"]),
		"phase": str(record["phase"]), "harness_check": str(record["harness_check"]),
		"composer_check": str(record["composer_check"]),
		"pane_mode_check": str(record["pane_mode_check"]),
		"pause_ms": int(record["pause_ms"]), "bytes_sent": int(record["bytes_sent"])}
	if str(record["phase"]) == PHASE_FINISHED:
		receipt["outcome"] = str(record["outcome"])
	return receipt


## Whether that transaction is the one still holding the PTY. Every step that
## writes bytes or closes a transaction asks this first, because each signal
## emitted along the way can end this transaction or admit its successor.
func _is_active(txn_id: int) -> bool:
	return not _active.is_empty() and int(_active["id"]) == txn_id


## The admission guards, decided in one place so a raw write and a
## transaction refuse on identical evidence and from one clock. Options:
##   unless_typed_within_ms  — refuse if a person typed here that recently,
##                             measured on the monotonic stamp so a wall-clock
##                             step cannot open or close the window. Such a
##                             write is a message nobody typed, so it is also
##                             refused while a person has an agent container's
##                             tmux pane in a mode, where the bytes would drive
##                             tmux (see TerminalSession.pane_mode). Refused
##                             only on a report of that mode; a container that
##                             sends none is written to, and pane_mode_check
##                             says "unknown".
##                             A report follows the change by a PTY read and
##                             a frame. A mode entered from this terminal is
##                             keyed here, so a window longer than that lag
##                             (notify's is seconds) covers it; a mode entered
##                             from inside the pane is not covered until the
##                             report arrives.
##   expect_harness          — refuse unless that harness is in front; the
##                             check is SKIPPED, and said to be, where the
##                             platform cannot read the foreground at all
##   refuse_if_composer_holds_text — refuse if the harness's input box holds
##                             text a person typed and has not submitted (see
##                             _composer_verdict); SKIPPED when no marker is
##                             known for whatever is in front
##   expect_process          — refuse unless the foreground process group is
##                             this one (the harness session meant, not another
##                             of the same kind); refused too when unreadable
##   write_ticket            — refuse unless this ticket is still issued; not
##                             held (held:false, and its message avoids the
##                             hold phrase callers match): it stays withdrawn
## Returns {success:true, harness_check, composer_check, pane_mode_check} when
## the write may go ahead, or a refusal {success:false, held:true, outcome, error} — carrying
## the checks that had already run when it refused, because a write stopped by
## an earlier guard never reached the later ones.
func check_guards(options: Dictionary) -> Dictionary:
	var ticket: String = str(options.get("write_ticket", ""))
	if not ticket.is_empty() and not ticket_valid(ticket):
		return {"success": false, "held": false, "outcome": OUTCOME_REFUSED_WITHDRAWN,
			"error": "the sender withdrew this write before it could be made, so it was not made"}
	var typed_window: int = int(options.get("unless_typed_within_ms", 0))
	if typed_window > 0:
		var stamp: int = int(_session.last_input_ticks_ms)
		if stamp > 0:
			var typed_ago: int = Time.get_ticks_msec() - stamp
			if typed_ago < typed_window:
				return _refusal(OUTCOME_REFUSED_TYPING,
					"a person typed in this terminal %d ms ago; nothing was written" % typed_ago)

	var pane_mode_check: String = PANE_MODE_NOT_REQUESTED
	if typed_window > 0 and _session.has_method("pane_mode"):
		pane_mode_check = _session.pane_mode()
		if pane_mode_check == PANE_MODE_ACTIVE:
			var in_mode: Dictionary = _refusal(OUTCOME_REFUSED_PANE_MODE,
				"a person has this terminal's tmux pane in scrollback or another mode; nothing was written")
			in_mode["pane_mode_check"] = pane_mode_check
			return in_mode

	var harness_check: String = HARNESS_NOT_REQUESTED
	var expected: String = str(options.get("expect_harness", ""))
	if not expected.is_empty():
		if not _session.foreground_supported():
			harness_check = HARNESS_SKIPPED
		else:
			var live: Dictionary = _session.get_foreground_process()
			var actual: String = _session.harness_of(live)
			if actual != expected:
				var refusal: Dictionary = _refusal(OUTCOME_REFUSED_HARNESS,
					"the foreground of this terminal is %s, not %s; nothing was written" % [
						str(live.get("name", "unreadable")) if actual.is_empty() else actual, expected])
				refusal["harness_check"] = HARNESS_CHECKED
				refusal["pane_mode_check"] = pane_mode_check
				return refusal
			harness_check = HARNESS_CHECKED

	var expected_process: int = int(options.get("expect_process", 0))
	if expected_process > 0:
		var live_process: int = int(_session.get_foreground_process().get("pid", 0)) \
			if _session.foreground_supported() else 0
		if live_process != expected_process:
			var replaced: Dictionary = _refusal(OUTCOME_REFUSED_PROCESS,
				"the foreground process of this terminal is %s, not the expected one; nothing was written" % (
					"unreadable" if live_process == 0 else "another"))
			replaced["harness_check"] = harness_check
			replaced["pane_mode_check"] = pane_mode_check
			return replaced

	var composer_check: String = COMPOSER_NOT_REQUESTED
	if bool(options.get("refuse_if_composer_holds_text", false)):
		var markers: Array = _composer_markers()
		var verdict: Dictionary = {} if markers.is_empty() else _composer_verdict(markers)
		if not bool(verdict.get("readable", false)):
			composer_check = COMPOSER_SKIPPED
		else:
			composer_check = COMPOSER_CHECKED
			if bool(verdict.get("holds", false)):
				var held: Dictionary = _refusal(OUTCOME_REFUSED_COMPOSER,
					"the composer of '%s' %s ('%s'); nothing was written" % [
						_session_label(), COMPOSER_HOLD_PHRASE, str(verdict.get("row", ""))])
				held["harness_check"] = harness_check
				held["composer_check"] = COMPOSER_CHECKED
				held["pane_mode_check"] = pane_mode_check
				return held
	return {"success": true, "harness_check": harness_check, "composer_check": composer_check,
		"pane_mode_check": pane_mode_check}


## The glyphs that open the composer row: the ones the harness in front draws.
## An unreadable foreground, or one that is not a harness this table knows,
## yields none — and the guard is then skipped rather than guessed at.
func _composer_markers() -> Array:
	if _session == null or not _session.has_method("foreground_supported") \
			or not _session.foreground_supported():
		return []
	var harness: String = _session.harness_of(_session.get_foreground_process())
	return Array(COMPOSER_MARKERS.get(harness, []))


## Whether the harness's input box holds text a person typed and left
## unsubmitted. The composer REGION is fixed, not inferred:
##   TOP    — the nearest row AT OR ABOVE the cursor row (get_cursor()["y"],
##            a viewport row) whose text starts at column 0 with a marker glyph
##            followed by a space, or is that glyph alone. Both harnesses
##            INDENT every continuation row, so a marker at column 0 is never a
##            wrapped draft line and a marker typed inside a draft cannot be
##            mistaken for the composer row.
##   BOTTOM — the bottom of the viewport. Nothing ends the region early: not a
##            border, not a blank row, not a pasted rule.
## A row whose visible characters are all box-drawing glyphs is skipped rather
## than stopped at: it carries no text either way.
##
## CONSEQUENCE, by design: whatever the harness draws BELOW the composer — its
## footer, model line or status row — is inside the region, so it is read by
## the same cell rule as the box. Refusing loudly beats guessing where the box
## ends, and the refusal quotes the row it tripped on, so a wrong hold is
## readable off the receipt.
##
## Row text alone cannot decide: both harnesses draw an EMPTY box with a
## placeholder inside it (codex's "Use /skills …", Claude Code's "Try …"), and
## an extracted row cannot tell that from a typed line. The cell style can.
## Measured on Claude Code 2.1 and Codex 0.155 (a PTY capture of each): a
## placeholder is drawn FAINT (SGR 2); the footer, model line, status rows,
## slash and @ popups are drawn in a COLOUR (an RGB or palette foreground);
## and what a person types — a draft, its wrapped rows, a slash command, a
## collapsed "[Pasted text …]" chip, the command after a shell-mode `!` — is
## drawn PLAIN: the default foreground and not faint. So a plain, non-space
## cell in the region, the marker glyph and the space after it aside, is
## unsent text; faint and coloured cells are chrome.
##
## No row shape is exempt. A chooser or permission screen opens its SELECTED
## option with the same marker ("❯ 1. Yes, proceed"); drawn plain it reads as
## occupied here, which is the right ACTION — nothing may be typed into such a
## screen either — even though the refusal names the composer. Drawn in colour
## it passes THIS guard: this is a composer guard, not a dialog guard. The
## notify path runs the relay's send gate, which classifies dialogs from the
## screen text; a guarded raw write has only the guards it asked for. The
## alternative, a heuristic that exempts "chooser-looking" rows, misreads a
## person's own numbered or aligned draft as a chooser and submits it.
##
## Returns {readable, holds} and, when it holds, {row} — the offending row's
## text, trimmed, for the refusal to quote. readable is false where no marker
## row sits at or above the cursor (an unknown harness screen, a harness
## mid-repaint), where the cursor cannot be read, or where the cells and their
## attributes cannot be had (no extension node, a build whose cell dictionary
## carries no "faint"); the caller then SKIPS the guard.
func _composer_verdict(markers: Array) -> Dictionary:
	if _session == null or not _session.has_method("get_cell") \
			or not _session.has_method("extract_row_text") \
			or not _session.has_method("get_cursor"):
		return {"readable": false, "holds": false}
	var rows: int = int(_session.get_rows()) if _session.has_method("get_rows") else 0
	var cursor: Dictionary = _session.get_cursor()
	if rows <= 0 or not cursor.has("y"):
		return {"readable": false, "holds": false}
	var cursor_row: int = clampi(int(cursor["y"]), 0, rows - 1)
	for row in range(cursor_row, -1, -1):
		var marker: String = _marker_of(str(_session.extract_row_text(row)), markers)
		if marker.is_empty():
			continue
		return _region_verdict(row, marker.length(), rows)
	return {"readable": false, "holds": false}


## The marker *text* opens the composer with, or "". Column 0 and then either a
## space (Claude Code's is a no-break space) or the end of the row: an indented
## marker belongs to the draft.
func _marker_of(text: String, markers: Array) -> String:
	for candidate: String in markers:
		if not text.begins_with(candidate):
			continue
		if text.length() == candidate.length():
			return candidate
		var after: int = text.unicode_at(candidate.length())
		if after == 0x20 or after == NBSP:
			return candidate
	return ""


## Every row of the region, marker row first, down to the foot of the viewport.
## Rows made only of box-drawing glyphs are skipped; the rest are read for a
## plain cell, the marker glyph and the space after it excepted.
func _region_verdict(marker_row: int, marker_length: int, rows: int) -> Dictionary:
	for row in range(marker_row, rows):
		var text: String = str(_session.extract_row_text(row))
		var stripped: String = text.strip_edges()
		# A rule of box-drawing glyphs is chrome only when the harness drew it
		# from column 0; the same glyphs on an INDENTED row are inside a draft
		# (continuation rows are indented) and count as text like any other.
		if stripped.is_empty() or (_is_rule_row(stripped) and not text.begins_with(" ")):
			continue
		var verdict: Dictionary = _row_verdict(row, marker_length + 1 if row == marker_row else 0, text)
		if not bool(verdict["readable"]):
			return verdict
		if bool(verdict["holds"]):
			verdict["row"] = stripped.left(60)
			return verdict
	return {"readable": true, "holds": false}


## Whether any cell of *row* from *from_col* on is PLAIN text: a non-space
## glyph drawn neither faint nor in a colour — the mark of text a person typed
## rather than of a placeholder or a status row. One cell per extracted
## character, so the string index IS the column.
func _row_verdict(row: int, from_col: int, text: String) -> Dictionary:
	for col in range(from_col, text.length()):
		var cell: Dictionary = _session.get_cell(col, row)
		if not cell.has("faint"):
			# This build's cells carry no attributes: the placeholder and a
			# typed line are indistinguishable, so nothing is claimed.
			return {"readable": false, "holds": false}
		var code: int = int(cell.get("codepoint", 0))
		if code <= 32 or code == NBSP or bool(cell["faint"]):
			continue
		if cell.has("fg") or cell.has("fg_palette"):
			continue
		return {"readable": true, "holds": true}
	return {"readable": true, "holds": false}


## A row carrying no text: every visible character is a box-drawing glyph, so
## it is chrome or a pasted rule. Such a row is skipped, never stopped at.
func _is_rule_row(stripped: String) -> bool:
	for index in range(stripped.length()):
		var code: int = stripped.unicode_at(index)
		if code < RULE_GLYPH_FIRST or code > RULE_GLYPH_LAST:
			return false
	return true


## The terminal's name, for a refusal a person reads.
func _session_label() -> String:
	if _session != null and "session_name" in _session:
		return str(_session.session_name)
	return "this terminal"


## The admission a RAW write takes: the same guards, plus the one thing a
## guarded raw write cannot survive. Its guards are true at this instant only,
## and a write submitted while a transaction holds the PTY is released after
## that transaction's pause — by then the harness may have exited and the
## person may have started typing, with neither re-checked. So a write that
## ASKED for a guard is refused while a transaction is in flight, exactly as a
## transaction would be, and the sender retries. A write with no guards carries
## no such promise and queues like any other input.
func check_raw_write(options: Dictionary) -> Dictionary:
	if not options.is_empty() and not _active.is_empty():
		return _refusal(OUTCOME_REFUSED_BUSY,
			"transaction %d still holds this terminal; nothing was written" % int(_active["id"]))
	return check_guards(options)


## The Enter half. Runs once, and only for the transaction that is still in
## flight: an aborted or already-finished id falls through here.
func _on_pause_elapsed(txn_id: int) -> void:
	if not _is_active(txn_id):
		return
	if not _session_writable():
		_finish(OUTCOME_SHELL_EXITED,
			"the terminal was no longer writable when the Enter was due; no Enter was sent")
		return
	_write_through(str(_active["enter"]))
	_active["phase"] = PHASE_ENTER_WRITTEN
	transaction_phase.emit(txn_id, PHASE_ENTER_WRITTEN)
	# A handler of that phase, or of the finish it triggers, can end this
	# transaction and admit another. Completion is therefore specific to this
	# id: otherwise _finish would either close a successor before its Enter or
	# run on no transaction at all.
	if _is_active(txn_id):
		_finish(OUTCOME_COMMITTED, "")


func _on_shell_exited(_exit_code: int) -> void:
	if _active.is_empty():
		return
	_finish(OUTCOME_SHELL_EXITED, "the shell exited while the transaction was in flight; no Enter was sent")


## Closes the in-flight transaction with an outcome and releases everything
## queued behind it. The record is detached first so released input writes
## through instead of queueing itself again.
func _finish(outcome: String, detail: String) -> void:
	var record: Dictionary = _active
	_active = {}
	record["outcome"] = outcome
	record["detail"] = detail
	record["phase"] = PHASE_FINISHED
	record["released"] = _queue.size()
	var pending: Array[String] = _queue
	_queue = []
	for text in pending:
		_write_through(text)
	transaction_phase.emit(int(record["id"]), PHASE_FINISHED)
	transaction_finished.emit(int(record["id"]), record)


## Finished records are kept for callers that saw only the admission, but
## not forever: the oldest finished ones go once the store passes its bound.
## The active record is never evicted.
const RECORDS_KEPT := 32

func _evict_finished_records() -> void:
	while _records.size() > RECORDS_KEPT:
		var oldest_finished: int = 0
		for id in _records:
			if str(_records[id].get("phase", "")) == PHASE_FINISHED:
				oldest_finished = int(id)
				break
		if oldest_finished == 0:
			return
		_records.erase(oldest_finished)


## The session is still there and its PTY still has a child.
func _session_writable() -> bool:
	return _session != null and is_instance_valid(_session) \
		and _session.has_method("is_alive") and _session.is_alive()


func _write_through(text: String) -> void:
	if _session != null and is_instance_valid(_session) and _session.has_method("write_pty"):
		_session.write_pty(text)


func _refusal(outcome: String, why: String) -> Dictionary:
	return {"success": false, "held": true, "outcome": outcome, "error": why}
