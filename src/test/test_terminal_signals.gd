extends SceneTree
## Wide headless test of signal-versus-byte in a Minerva terminal: the PTY
## keeps the kernel's default line discipline, so ISIG decides whether the
## 0x03 a view writes for Ctrl-C interrupts the foreground command or is
## delivered to it as data.
##
## Run: godot --headless --path src --script test/test_terminal_signals.gd
##
## Everything here is real: a TerminalSession over a forkpty'd shell (the
## built extension), the registry MCP terminal_list reads, and a python child
## that puts its own stdin in raw mode. No termios state is inspected — the
## oracles are what the processes DO.
##
## ORACLES
##   - interrupt: on a session whose command is written the instant it exists,
##     while `sleep 30` runs, one 0x03 ends it within a few seconds, the sleep
##     process is gone (kill -0 fails on its pid) and the shell runs the next
##     command at a fresh prompt — the 30 s never elapses;
##   - passthrough: a child that cleared ISIG for itself (python tty.setraw)
##     receives that same 0x03 as a byte and stays alive, and an arrow key
##     arrives as the three bytes 1b 5b 41; "q" ends it and the shell is back.
##
## A shell EXECUTED its command only when the screen carries something the
## command text does not: every probe here is an arithmetic expansion, so
## `echo INTERRUPT-$((40+2))` proves itself by the "INTERRUPT-42" that only the
## shell can produce. Matching the token the test typed would match its echo.

const PROBE_SRC := """import os, sys, tty
tty.setraw(0)
sys.stdout.write("PROBEREADY\\r\\n")
sys.stdout.flush()
while True:
	b = os.read(0, 1)
	if not b:
		break
	if b == b"q":
		sys.stdout.write("PROBEDONE\\r\\n")
		sys.stdout.flush()
		break
	sys.stdout.write("GOT %02x\\r\\n" % b[0])
	sys.stdout.flush()
"""

const CTRL_C := ""

var _pass: int = 0
var _fail: int = 0
var _registry = null


func _init() -> void:
	print("=== terminal signals (real PTY) ===\n")
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


## True while the OS still has a process with this pid.
func _pid_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	var out: Array = []
	return OS.execute("kill", ["-0", str(pid)], out, true) == 0


## Every byte the raw-mode probe reported, in order.
func _probe_bytes(session) -> Array:
	var out: Array = []
	for line in session.get_plain_text().split("\n"):
		var text: String = line.strip_edges()
		if text.begins_with("GOT "):
			out.append(text.substr(4).strip_edges().hex_to_int())
	return out


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

	await _test_interrupt()
	await _test_raw_mode_passthrough()


# ── Oracle 1: Ctrl-C interrupts the foreground command ─────────────────

func _test_interrupt() -> void:
	var session = _registry.create_session("signals-interrupt", 80, 24)
	if session == null or not session.started or not session.terminal_available:
		print("SKIP: PTY unavailable for the interrupt oracle")
		return

	# The command goes out the instant the session exists — no settling wait
	# before it, so this run also covers the window between the fork and the
	# first byte. One sample cannot establish that no race exists there; what
	# it shows is that on this run the modes were already the child's.
	var submitted_at: int = Time.get_ticks_msec()
	session.write_input("sleep 30\r")
	var sleeping: bool = await _wait_until(func() -> bool:
		return str(session.get_foreground_process().get("name", "")) == "sleep")
	check("sleep is in the foreground", sleeping, str(session.get_foreground_process()))
	if not sleeping:
		_registry.close_session(session.terminal_id)
		return
	var sleep_pid: int = int(session.get_foreground_process().get("pid", 0))

	var started_ms: int = Time.get_ticks_msec()
	session.write_input(CTRL_C)
	# A scheduling bound, not a measurement: a signal delivery and one poll
	# need nothing like the three seconds allowed, and the sleep's own 30 s is
	# 10x outside that bound.
	var interrupted: bool = await _wait_until(func() -> bool:
		return str(session.get_foreground_process().get("name", "")) != "sleep", 3000)
	check("one 0x03 ends the sleep within a few seconds (a scheduling bound, far below the 30 s)", interrupted,
		"%d ms, foreground %s" % [Time.get_ticks_msec() - started_ms,
			str(session.get_foreground_process())])
	var reaped: bool = await _wait_until(func() -> bool: return not _pid_alive(sleep_pid), 2000)
	check("the sleep process itself is gone", reaped, "pid %d" % sleep_pid)
	# Timed from the SUBMISSION of `sleep 30`, not from the moment the sleep
	# was seen in front: a run slow enough to watch the sleep expire on its
	# own cannot credit that to the interrupt.
	check("the whole interrupt leg took far less than the sleep itself",
		Time.get_ticks_msec() - submitted_at < 25000,
		"%d ms since submission" % (Time.get_ticks_msec() - submitted_at))

	# A fresh prompt: the shell runs the next line, so it is interactive again
	# rather than still blocked or dead. The shell is also back in the
	# foreground on its own evidence, which the screen cannot fake.
	var shell_name: String = str(session.get_foreground_process().get("name", ""))
	check("the shell itself is the foreground again", shell_name != "sleep" and shell_name != "",
		str(session.get_foreground_process()))
	session.write_input("echo INTERRUPT-$((40+2))\r")
	var prompted: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("INTERRUPT-42") != -1, 5000)
	check("the shell draws a fresh prompt and runs the next command", prompted,
		session.read_viewport_text().right(300))
	check("the 30 s sleep never elapsed", Time.get_ticks_msec() - started_ms < 20000)
	_registry.close_session(session.terminal_id)


# ── Oracle 2: a raw-mode child gets the same byte as data ──────────────

func _test_raw_mode_passthrough() -> void:
	var probe_rel := "user://terminal_signals_probe.py"
	var f := FileAccess.open(probe_rel, FileAccess.WRITE)
	if f == null:
		check("raw-mode probe written", false, str(FileAccess.get_open_error()))
		return
	f.store_string(PROBE_SRC)
	f.close()
	var probe_path: String = ProjectSettings.globalize_path(probe_rel)

	var session = _registry.create_session("signals-raw", 80, 24)
	if session == null or not session.started or not session.terminal_available:
		print("SKIP: PTY unavailable for the raw-mode oracle")
		return

	session.write_input("python3 -u '%s'\r" % probe_path)
	var ready: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("PROBEREADY") != -1)
	check("the raw-mode probe is running", ready, session.read_viewport_text().right(300))
	if not ready:
		_registry.close_session(session.terminal_id)
		return
	var probe_pid: int = int(session.get_foreground_process().get("pid", 0))

	# ISIG is the probe's to clear: the host writes the same bytes either way.
	session.write_input(CTRL_C)
	session.write_input("[A")
	var want: Array = [0x03, 0x1b, 0x5b, 0x41]
	var got: bool = await _wait_until(func() -> bool: return _probe_bytes(session) == want, 5000)
	check("0x03 and ESC [ A arrive as bytes, in order", got,
		"got %s want %s" % [str(_probe_bytes(session)), str(want)])
	check("the probe survived its own Ctrl-C", _pid_alive(probe_pid), "pid %d" % probe_pid)

	session.write_input("q")
	var done: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("PROBEDONE") != -1, 5000)
	check("the probe exits on q", done, session.read_viewport_text().right(300))
	var shell_back: bool = await _wait_until(func() -> bool:
		var name: String = str(session.get_foreground_process().get("name", ""))
		return name != "" and name != "python3", 5000)
	check("the shell is the foreground once the probe exits", shell_back,
		str(session.get_foreground_process()))
	session.write_input("echo RAW-$((7*3))\r")
	var back: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("RAW-21") != -1, 5000)
	check("and it runs the next command afterwards", back,
		session.read_viewport_text().right(300))
	_registry.close_session(session.terminal_id)
