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

# How the expect_harness guard was resolved, as reported back to the caller.
const HARNESS_NOT_REQUESTED := "not_requested"
const HARNESS_CHECKED := "checked"
const HARNESS_SKIPPED := "skipped"

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
## Both guards are checked once, here: an admitted transaction is not
## re-guarded, and its body is written exactly once and never replayed.
## Returns {success:true, txn_id, phase, harness_check, ...} on admission, or
## a refusal shaped like the write guard: {success:false, held:true, error}.
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

	var txn_id: int = _next_txn_id
	_next_txn_id += 1
	var pause_ms: int = maxi(0, int(options.get("pause_ms", DEFAULT_PAUSE_MS)))
	var record: Dictionary = {
		"id": txn_id,
		"phase": PHASE_ADMITTED,
		"outcome": "",
		"harness_check": harness_check,
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
		"pause_ms": int(record["pause_ms"]), "bytes_sent": int(record["bytes_sent"])}
	if str(record["phase"]) == PHASE_FINISHED:
		receipt["outcome"] = str(record["outcome"])
	return receipt


## Whether that transaction is the one still holding the PTY. Every step that
## writes bytes or closes a transaction asks this first, because each signal
## emitted along the way can end this transaction or admit its successor.
func _is_active(txn_id: int) -> bool:
	return not _active.is_empty() and int(_active["id"]) == txn_id


## The two admission guards, decided in one place so a raw write and a
## transaction refuse on identical evidence and from one clock. Options:
##   unless_typed_within_ms  — refuse if a person typed here that recently,
##                             measured on the monotonic stamp so a wall-clock
##                             step cannot open or close the window
##   expect_harness          — refuse unless that harness is in front; the
##                             check is SKIPPED, and said to be, where the
##                             platform cannot read the foreground at all
## Returns {success:true, harness_check} when the write may go ahead, or a
## refusal {success:false, held:true, outcome, error} — carrying harness_check
## only when the harness check is the thing that refused, because a write
## stopped by the typing guard never reached it.
func check_guards(options: Dictionary) -> Dictionary:
	var typed_window: int = int(options.get("unless_typed_within_ms", 0))
	if typed_window > 0:
		var stamp: int = int(_session.last_input_ticks_ms)
		if stamp > 0:
			var typed_ago: int = Time.get_ticks_msec() - stamp
			if typed_ago < typed_window:
				return _refusal(OUTCOME_REFUSED_TYPING,
					"a person typed in this terminal %d ms ago; nothing was written" % typed_ago)

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
				return refusal
			harness_check = HARNESS_CHECKED
	return {"success": true, "harness_check": harness_check}


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
