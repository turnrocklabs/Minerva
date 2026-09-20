extends SceneTree
## Wide headless test of the terminal input arbiter: the single gate every
## byte takes to a TerminalSession's PTY, and the guarded write transaction
## (body → pause → Enter) that owns that gate while it runs.
##
## Run: godot --headless --path src --script test/test_terminal_input_arbiter.gd
##
## The oracle is the PTY itself. A real python child puts the slave side in
## raw mode and hex-dumps every byte it reads, one per line, so the test reads
## back exactly what reached the terminal and in what order — echo, line
## discipline and buffering cannot forge it.
##
## ORACLES
##   - interleaving: a human "x\r" injected at the body-written phase lands
##     AFTER the transaction's Enter, and every byte appears exactly once;
##   - overflow: past the queue bound the human wins — no Enter is dumped, the
##     outcome names the overflow (in the admission return too, because the
##     overflow finished the transaction before it returned), and every
##     injected key is dumped in order;
##   - admission: a transaction inside the typing window and one whose
##     expect_harness does not match are refused before any byte is written,
##     and where the platform cannot read the foreground the result SAYS the
##     harness check was skipped;
##   - lifecycle: a transaction whose session dies under it writes no Enter and
##     says why — the shell exiting during the pause ends it partial, a session
##     freed before the timer fires leaves the callback harmless — and a second
##     transaction started while one is in flight is refused without bytes;
##   - reentrancy: a signal handler that overflows the queue, or starts another
##     transaction, cannot make the arbiter write the wrong bytes — an overflow
##     at the admitted phase leaves the body unwritten, an overflow after the
##     Enter does not "abort" what already committed, and a transaction started
##     from a finish handler is not completed by its predecessor.

const ARBITER_PATH := "res://Scripts/Services/Terminal/TerminalInputArbiter.gd"
const DUMP_SCRIPT := """import os, sys, tty
tty.setraw(0)
sys.stdout.write("DUMPREADY\\r\\n")
sys.stdout.flush()
while True:
	b = os.read(0, 1)
	if not b:
		break
	sys.stdout.write("HEX %02x\\r\\n" % b[0])
	sys.stdout.flush()
"""

var _pass: int = 0
var _fail: int = 0
var _registry = null
var _dump_path: String = ""
# Receipts the phase handlers collected, read back by the oracles.
var _injected: Array[Dictionary] = []


func _init() -> void:
	print("=== terminal input arbiter (real PTY) ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _wait_until(predicate: Callable, timeout_ms: int = 15000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(0.05).timeout
	return bool(predicate.call())


func _sleep_ms(ms: int) -> void:
	await create_timer(ms / 1000.0).timeout


## Every byte the dumping child read, in order.
func _dumped(session) -> Array:
	var out: Array = []
	for line in session.get_plain_text().split("\n"):
		var text: String = line.strip_edges()
		if text.begins_with("HEX "):
			out.append(text.substr(4).strip_edges().hex_to_int())
	return out


func _bytes_of(text: String) -> Array:
	var out: Array = []
	for b in text.to_utf8_buffer():
		out.append(int(b))
	return out


## A session running the hex dumper, or null when the PTY is unavailable.
func _dumping_session(name: String):
	var session = _registry.create_session(name, 80, 24)
	if session == null or not session.started or not session.terminal_available:
		return null
	session.write_input("python3 -u %s\r" % _dump_path)
	var ready: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("DUMPREADY") != -1)
	if not ready:
		check("%s: hex dumper started" % name, false, session.read_viewport_text().right(300))
		return null
	return session


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return
	_registry = so.get_terminal_session_registry()
	check("terminal session registry available", _registry != null)
	if _registry == null:
		return

	_dump_path = ProjectSettings.globalize_path("user://terminal_arbiter_dump.py")
	var f := FileAccess.open("user://terminal_arbiter_dump.py", FileAccess.WRITE)
	if f == null:
		check("dump script written", false, str(FileAccess.get_open_error()))
		return
	f.store_string(DUMP_SCRIPT)
	f.close()

	await _test_interleaving()
	await _test_overflow()
	await _test_admission()
	await _test_admitted_phase_overflow()
	await _test_reentrant_completion()
	await _test_lifecycle()


# ── Oracle 1: a human keystroke cannot split a transaction ─────────────

func _test_interleaving() -> void:
	var session = await _dumping_session("arbiter-interleave")
	if session == null:
		print("SKIP: PTY unavailable for the interleaving oracle")
		return
	var arbiter = session.get_input_arbiter()
	check("session exposes its arbiter", arbiter != null)
	if arbiter == null:
		return

	# Synchronise on the PHASE, not on a clock: the keystroke is injected the
	# instant the body has reached the PTY and the Enter is still pending.
	_injected = []
	arbiter.transaction_phase.connect(func(_id: int, phase: String) -> void:
		if phase == arbiter.PHASE_BODY_WRITTEN and _injected.is_empty():
			_injected.append(session.write_human_input("x\r")))

	var body := "echo hi"
	var admitted: Dictionary = session.begin_write_transaction(body, {"pause_ms": 200})
	check("transaction admitted", bool(admitted.get("success", false)), str(admitted))
	check("admission reports an id and the body-written phase, with no outcome yet",
		int(admitted.get("txn_id", 0)) > 0
			and str(admitted.get("phase", "")) == arbiter.PHASE_BODY_WRITTEN
			and not admitted.has("outcome"),
		str(admitted))
	check("input arriving mid-transaction is queued, not written",
		_injected.size() == 1 and bool(_injected[0].get("queued", false)), str(_injected))

	var txn_id: int = int(admitted.get("txn_id", 0))
	var committed: bool = await _wait_until(func() -> bool:
		return str(arbiter.get_transaction(txn_id).get("outcome", "")) == arbiter.OUTCOME_COMMITTED)
	check("transaction commits", committed, str(arbiter.get_transaction(txn_id)))

	var expected: Array = _bytes_of(body) + [0x0d] + _bytes_of("x") + [0x0d]
	var landed: bool = await _wait_until(func() -> bool:
		return _dumped(session).size() >= expected.size())
	check("every byte reached the PTY", landed, str(_dumped(session)))
	check("body, Enter, then the human key — each exactly once, in order",
		_dumped(session) == expected,
		"got %s want %s" % [str(_dumped(session)), str(expected)])
	_registry.close_session(session.terminal_id)


# ── Oracle 2: past the bound the human wins ────────────────────────────

func _test_overflow() -> void:
	var session = await _dumping_session("arbiter-overflow")
	if session == null:
		print("SKIP: PTY unavailable for the overflow oracle")
		return
	var arbiter = session.get_input_arbiter()
	arbiter.queue_limit = 3

	_injected = []
	arbiter.transaction_phase.connect(func(_id: int, phase: String) -> void:
		if phase == arbiter.PHASE_BODY_WRITTEN and _injected.is_empty():
			for key in ["a", "b", "c", "d"]:
				_injected.append(session.write_human_input(key)))

	var body := "zz"
	var admitted: Dictionary = session.begin_write_transaction(body, {"pause_ms": 200})
	var txn_id: int = int(admitted.get("txn_id", 0))
	check("overflow: transaction admitted", bool(admitted.get("success", false)), str(admitted))
	# The overflow happened inside the phase handler, so the transaction was
	# already over when begin returned: the admission must say so rather than
	# report a body-written transaction that nothing will ever commit.
	check("the admission reports the transaction it has already finished",
		str(admitted.get("phase", "")) == arbiter.PHASE_FINISHED
			and str(admitted.get("outcome", "")) == arbiter.OUTCOME_OVERFLOW,
		str(admitted))
	check("the key past the bound releases the queue",
		_injected.size() == 4 and bool(_injected[3].get("released", false)), str(_injected))

	var record: Dictionary = arbiter.get_transaction(txn_id)
	check("the outcome names the overflow",
		str(record.get("outcome", "")) == arbiter.OUTCOME_OVERFLOW, str(record))
	check("the transaction is finished, not in flight",
		str(record.get("phase", "")) == arbiter.PHASE_FINISHED and not arbiter.is_transaction_active(),
		str(record))

	# Outlive the pause: the Enter must never arrive, not merely arrive late.
	await _sleep_ms(600)
	var expected: Array = _bytes_of(body) + _bytes_of("abcd")
	check("no Enter was sent and every key landed in order",
		_dumped(session) == expected,
		"got %s want %s" % [str(_dumped(session)), str(expected)])
	_registry.close_session(session.terminal_id)


# ── Oracle 3: admission guards refuse before any byte ──────────────────

func _test_admission() -> void:
	var session = _registry.create_session("arbiter-admission", 80, 24)
	if session == null or not session.started or not session.terminal_available:
		print("SKIP: PTY unavailable for the admission oracle")
		return
	var arbiter = session.get_input_arbiter()

	check("no human stamp before any human input", session.last_input_ticks_ms == 0)
	session.note_human_input()
	check("a keystroke stamps both the monotonic and the wall clock",
		session.last_input_ticks_ms > 0 and session.last_input_ms > 0,
		"%d / %d" % [session.last_input_ticks_ms, session.last_input_ms])

	var typing: Dictionary = session.begin_write_transaction(
		"echo nope-typing", {"unless_typed_within_ms": 10000})
	check("a transaction inside the typing window is refused",
		not bool(typing.get("success", true)) and bool(typing.get("held", false))
			and str(typing.get("outcome", "")) == arbiter.OUTCOME_REFUSED_TYPING, str(typing))

	var harness: Dictionary = session.begin_write_transaction(
		"echo nope-harness", {"expect_harness": "claude"})
	if session.foreground_supported():
		check("expect_harness against a bare shell is refused",
			not bool(harness.get("success", true)) and bool(harness.get("held", false))
				and str(harness.get("outcome", "")) == arbiter.OUTCOME_REFUSED_HARNESS, str(harness))
		check("the refusal says the check really ran",
			str(harness.get("harness_check", "")) == arbiter.HARNESS_CHECKED, str(harness))
	else:
		check("without foreground support the harness check is skipped",
			bool(harness.get("success", false))
				and str(harness.get("harness_check", "")) == arbiter.HARNESS_SKIPPED, str(harness))

	# A refusal writes nothing: the shell would echo anything that reached it.
	# Only the typing refusal is unconditional — where the foreground cannot be
	# read the harness transaction was ADMITTED, so its body must have landed.
	await _sleep_ms(300)
	var screen: String = session.get_plain_text()
	check("a refused transaction wrote no bytes", screen.find("nope-typing") == -1,
		screen.right(300))
	if session.foreground_supported():
		check("the harness-refused transaction wrote no bytes either",
			screen.find("nope-harness") == -1, screen.right(300))
	else:
		check("the skipped-check transaction reached the shell instead",
			screen.find("nope-harness") != -1, screen.right(300))
	_registry.close_session(session.terminal_id)

	# The skip must be observable on THIS platform too: a session standing in
	# for one whose foreground cannot be read at all (ConPTY). The arbiter
	# under test is the real one; only the platform answer is substituted.
	var blind := _BlindSession.new()
	root.add_child(blind)
	var blind_arbiter = load(ARBITER_PATH).new()
	blind_arbiter.setup(blind)
	var skipped: Dictionary = blind_arbiter.begin_transaction(
		"echo blind", {"pause_ms": 50, "expect_harness": "claude"})
	check("where the foreground cannot be read the result says the check was skipped",
		bool(skipped.get("success", false))
			and str(skipped.get("harness_check", "")) == blind_arbiter.HARNESS_SKIPPED, str(skipped))
	var done: bool = await _wait_until(func() -> bool:
		return str(blind_arbiter.get_transaction(int(skipped.get("txn_id", 0))).get("outcome", "")) != "")
	check("the skipped-check transaction still commits body then Enter",
		done and blind.written == ["echo blind", "\r"], str(blind.written))
	blind.queue_free()


# ── Oracle 4: an overflow at the admitted phase ────────────────────────
# The queue can overflow before the body has been written at all: the handler
# of the ADMITTED phase is inside the write path. The body must then never go
# out — writing it would put agent text after the keys that aborted it, with
# no Enter ever coming to submit it.

func _test_admitted_phase_overflow() -> void:
	var blind := _BlindSession.new()
	root.add_child(blind)
	var arbiter = load(ARBITER_PATH).new()
	arbiter.setup(blind)
	arbiter.queue_limit = 1

	var fired: Array[bool] = [false]
	arbiter.transaction_phase.connect(func(_id: int, phase: String) -> void:
		if phase == arbiter.PHASE_ADMITTED and not fired[0]:
			fired[0] = true
			arbiter.submit("k", true)
			arbiter.submit("j", true))

	var admitted: Dictionary = arbiter.begin_transaction("echo body", {"pause_ms": 30})
	check("an overflow at the admitted phase ends the transaction before its body",
		str(admitted.get("phase", "")) == arbiter.PHASE_FINISHED
			and str(admitted.get("outcome", "")) == arbiter.OUTCOME_OVERFLOW
			and int(admitted.get("bytes_sent", -1)) == 0, str(admitted))
	# Outlive the pause: the body must never appear, not merely appear late.
	await _sleep_ms(200)
	check("only the keys that aborted it reached the PTY",
		blind.written == ["k", "j"], str(blind.written))
	blind.queue_free()


# ── Oracle 5: completion belongs to one transaction ────────────────────
# The ENTER_WRITTEN handler overflows the queue and the finish handler starts a
# replacement — both inside the completion path. The first transaction has
# already written everything, so it commits; the replacement must keep its own
# Enter rather than be completed by its predecessor.

func _test_reentrant_completion() -> void:
	var blind := _BlindSession.new()
	root.add_child(blind)
	var arbiter = load(ARBITER_PATH).new()
	arbiter.setup(blind)
	arbiter.queue_limit = 1

	# Only the FIRST transaction's Enter is overflowed; the replacement runs
	# clean so the byte order below has one meaning.
	var first: Dictionary = {"id": 0}
	arbiter.transaction_phase.connect(func(id: int, phase: String) -> void:
		if phase == arbiter.PHASE_ENTER_WRITTEN and id == int(first["id"]):
			arbiter.submit("q", true)
			arbiter.submit("r", true))
	var second: Dictionary = {"id": 0}
	arbiter.transaction_finished.connect(func(_id: int, _record: Dictionary) -> void:
		if int(second["id"]) == 0:
			second["id"] = int(arbiter.begin_transaction(
				"second", {"pause_ms": 30}).get("txn_id", 0)))

	first["id"] = arbiter._next_txn_id
	var first_id: int = int(arbiter.begin_transaction("first", {"pause_ms": 30}).get("txn_id", 0))
	var done: bool = await _wait_until(func() -> bool:
		return int(second["id"]) > 0 \
			and str(arbiter.get_transaction(int(second["id"])).get("outcome", "")) != "")
	check("input overflowing after the Enter does not abort what already committed",
		str(arbiter.get_transaction(first_id).get("outcome", "")) == arbiter.OUTCOME_COMMITTED,
		str(arbiter.get_transaction(first_id)))
	check("the transaction started from the finish handler commits on its own Enter",
		done and str(arbiter.get_transaction(int(second["id"])).get("outcome", ""))
			== arbiter.OUTCOME_COMMITTED,
		str(arbiter.get_transaction(int(second["id"]))))
	check("body, Enter, the released keys, then the replacement and its Enter",
		blind.written == ["first", "\r", "q", "r", "second", "\r"], str(blind.written))
	blind.queue_free()


# ── Oracle 6: how a transaction ends when its session does ─────────────
# Three short lifecycles, each read on the same two questions: what outcome the
# record carries, and what more — if anything — reached the PTY afterwards.

func _test_lifecycle() -> void:
	# (a) The shell exits while the transaction is paused: the Enter comes due
	# on a terminal that can no longer take it, so it is never written.
	var dying := _BlindSession.new()
	root.add_child(dying)
	var dying_arbiter = load(ARBITER_PATH).new()
	dying_arbiter.setup(dying)
	var dying_id: int = int(dying_arbiter.begin_transaction(
		"echo dying", {"pause_ms": 60}).get("txn_id", 0))
	dying.alive = false
	var exited: bool = await _wait_until(func() -> bool:
		return str(dying_arbiter.get_transaction(dying_id).get("outcome", "")) != "")
	# Outlive the pause: a late Enter would be as wrong as a prompt one.
	await _sleep_ms(200)
	check("a shell that exits during the pause ends the transaction without its Enter",
		exited
			and str(dying_arbiter.get_transaction(dying_id).get("outcome", ""))
				== dying_arbiter.OUTCOME_SHELL_EXITED
			and dying.written == ["echo dying"],
		"%s / %s" % [str(dying_arbiter.get_transaction(dying_id)), str(dying.written)])
	dying.queue_free()

	# (b) The session is freed before the timer fires. The timer callback still
	# runs, on a session that is gone: it must write nothing and not crash.
	# The log is held by the TEST, so it survives the session it belonged to.
	var log: Array[String] = []
	var freed := _BlindSession.new()
	freed.written = log
	root.add_child(freed)
	var freed_arbiter = load(ARBITER_PATH).new()
	freed_arbiter.setup(freed)
	var freed_id: int = int(freed_arbiter.begin_transaction(
		"echo freed", {"pause_ms": 60}).get("txn_id", 0))
	freed.free()
	await _sleep_ms(250)
	check("a session freed before the timer fires takes no Enter and no crash",
		str(freed_arbiter.get_transaction(freed_id).get("outcome", ""))
				== freed_arbiter.OUTCOME_SHELL_EXITED
			and log == ["echo freed"],
		"%s / %s" % [str(freed_arbiter.get_transaction(freed_id)), str(log)])

	# (c) A second transaction while one is in flight: refused with no id and no
	# bytes, and the one holding the PTY finishes exactly as it would have.
	var busy := _BlindSession.new()
	root.add_child(busy)
	var busy_arbiter = load(ARBITER_PATH).new()
	busy_arbiter.setup(busy)
	var first_id: int = int(busy_arbiter.begin_transaction(
		"first", {"pause_ms": 80}).get("txn_id", 0))
	var refused: Dictionary = busy_arbiter.begin_transaction("second", {"pause_ms": 80})
	check("a second transaction while one is in flight is refused, with no id",
		not bool(refused.get("success", true)) and bool(refused.get("held", false))
			and str(refused.get("outcome", "")) == busy_arbiter.OUTCOME_REFUSED_BUSY
			and not refused.has("txn_id"), str(refused))
	var committed: bool = await _wait_until(func() -> bool:
		return str(busy_arbiter.get_transaction(first_id).get("outcome", "")) != "")
	await _sleep_ms(150)
	check("the refusal wrote nothing and the first transaction commits untouched",
		committed
			and str(busy_arbiter.get_transaction(first_id).get("outcome", ""))
				== busy_arbiter.OUTCOME_COMMITTED
			and busy.written == ["first", "\r"],
		"%s / %s" % [str(busy_arbiter.get_transaction(first_id)), str(busy.written)])
	busy.queue_free()


## Stands in for a platform that cannot report the PTY's foreground process.
## `written` may be replaced with a log the test keeps its own reference to, so
## what the PTY saw outlives the session; `alive` is the PTY's child, which a
## test turns off to make the shell exit under a transaction.
class _BlindSession extends Node:
	var last_input_ticks_ms: int = 0
	var written: Array[String] = []
	var alive: bool = true

	func is_alive() -> bool:
		return alive

	func foreground_supported() -> bool:
		return false

	func get_foreground_process() -> Dictionary:
		return {}

	static func harness_of(_process: Dictionary) -> String:
		return ""

	func write_pty(text: String) -> void:
		written.append(text)
