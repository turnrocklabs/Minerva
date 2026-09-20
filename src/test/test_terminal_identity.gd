extends SceneTree
## Wide headless test of terminal identity: what a program inside a Minerva
## terminal can learn about its own tab, and what the host can learn about
## the program in the foreground of any tab.
##
## Run: godot --headless --path src --script test/test_terminal_identity.gd
##
## Everything here is real: a TerminalSession over a forkpty'd shell (the
## built extension), the registry that MCP terminal_list reads, and the
## listing itself. The shell is whatever $SHELL is, rc-less by design.
##
## ORACLES
##   - the shell prints $MINERVA_TERMINAL_ID equal to the session's own id and
##     $MINERVA_TERMINAL_NAME equal to the tab name it was created with;
##   - while `sleep 3` runs, get_foreground_process names "sleep", and once
##     it exits the shell is back in front;
##   - node run on a script named `codex` — the npm-harness shape, whose main
##     thread node may rename to "MainThread" — is classified as codex from its
##     executable and argv;
##   - terminal_list carries last_input_ms and the foreground process, and a
##     human keystroke stamp moves last_input_ms to now;
##   - a terminal_write with then_enter_after_ms puts the body on the screen
##     and only the Enter makes the shell run it, and the same write refused by
##     expect_harness echoes nothing at all;
##   - where the foreground cannot be read, the write receipt says the harness
##     check was skipped rather than passing it silently;
##   - a raw write carries the arbiter's receipt: an unqueued write says so, and
##     a refusal names the guard that held it;
##   - while a transaction holds the terminal a GUARDED raw write is refused
##     (its guards would be stale by the time a queued write was released) and
##     an unguarded one is queued and lands after the transaction;
##   - no script outside TerminalSession writes the extension node directly.

const TERMINAL_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"
const TAB_NAME := "identity-tab"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== terminal identity (real PTY) ===\n")
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
		await create_timer(0.1).timeout
	return bool(predicate.call())


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return
	var registry = so.get_terminal_session_registry()
	check("terminal session registry available", registry != null)
	if registry == null:
		return

	var session = registry.create_session(TAB_NAME, 80, 24)
	check("session started", session != null and session.started)
	if session == null or not session.started or not session.terminal_available:
		print("SKIP: PTY unavailable (forkpty failed)")
		return
	var tid: String = str(session.terminal_id)

	_test_harness_of(session)

	# ── the child knows its own address ──────────────────────────────────
	# Two variables printed on one line, so a stale prompt cannot fake it.
	session.write_input("printf 'ID=%s NAME=%s\\n' \"$MINERVA_TERMINAL_ID\" \"$MINERVA_TERMINAL_NAME\"\r")
	var expected := "ID=%s NAME=%s" % [tid, TAB_NAME]
	var printed: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find(expected) != -1)
	check("shell sees MINERVA_TERMINAL_ID and MINERVA_TERMINAL_NAME", printed,
		session.read_viewport_text().right(300))

	# ── the host knows who is in front ───────────────────────────────────
	var at_prompt: Dictionary = session.get_foreground_process()
	check("foreground at the prompt is a process", int(at_prompt.get("pid", 0)) > 0, str(at_prompt))
	check("the shell is not a harness", session.harness_name() == "", str(at_prompt))

	session.write_input("sleep 3\r")
	var sleeping: bool = await _wait_until(func() -> bool:
		return str(session.get_foreground_process().get("name", "")) == "sleep")
	check("foreground names the running command", sleeping, str(session.get_foreground_process()))
	check("argv carries the arguments as separate words",
		Array(session.get_foreground_process().get("argv", [])) == ["sleep", "3"],
		str(session.get_foreground_process()))

	# The command ends on its own: Ctrl-C is not a signal in these PTYs (the
	# line discipline runs with ISIG off), so it would not end the wait.
	var back: bool = await _wait_until(func() -> bool:
		return str(session.get_foreground_process().get("name", "")) != "sleep")
	check("when it exits the shell is back in front", back, str(session.get_foreground_process()))

	await _test_npm_harness_foreground(session)

	# ── the listing carries it, and a human stamp moves ──────────────────
	var tools = load(TERMINAL_TOOLS_PATH).new()
	var entry: Dictionary = _entry_for(tools, tid)
	check("listing has the session", not entry.is_empty())
	check("listing reports last_input_ms 0 before any human input",
		entry.has("last_input_ms") and int(entry["last_input_ms"]) == 0, str(entry))
	check("listing names the foreground process",
		not str(entry.get("foreground_process", "")).is_empty(), str(entry))
	check("listing has no harness for a bare shell", not entry.has("harness"), str(entry))

	var before := int(Time.get_unix_time_from_system() * 1000.0)
	session.note_human_input()
	entry = _entry_for(tools, tid)
	check("a human keystroke stamps last_input_ms to now",
		int(entry.get("last_input_ms", 0)) >= before, str(entry))

	# ── the write-time guard refuses agent text while a person types ─────
	var guarded: Dictionary = tools._terminal_write(
		{"terminal_id": tid, "text": "echo agent\r", "raw": true, "unless_typed_within_ms": 5000})
	check("a guarded write right after a keystroke is held, nothing sent",
		not guarded.get("success", true) and bool(guarded.get("held", false))
			and str(guarded.get("outcome", "")) == "refused_human_typing"
			and str(guarded.get("error", "")).contains("nothing was written"), str(guarded))
	# Only where the foreground can be read is there a harness to disagree with:
	# elsewhere the check is skipped and the write goes through, saying so.
	var wrong_harness: Dictionary = tools._terminal_write(
		{"terminal_id": tid, "text": "echo agent\r", "raw": true, "expect_harness": "codex"})
	if session.foreground_supported():
		check("a write that expects a harness is held while the shell is in front",
			not wrong_harness.get("success", true) and bool(wrong_harness.get("held", false)),
			str(wrong_harness))
	else:
		check("where the foreground cannot be read that write says the check was skipped",
			wrong_harness.get("success", false)
				and str(wrong_harness.get("harness_check", "")) == "skipped", str(wrong_harness))
	var unguarded: Dictionary = tools._terminal_write(
		{"terminal_id": tid, "text": "echo GUARD-OFF\r", "raw": true})
	check("an unguarded write goes through, and its receipt says it was not queued",
		unguarded.get("success", false) and unguarded.has("queued")
			and not bool(unguarded.get("queued", true)), str(unguarded))
	var echoed: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("GUARD-OFF") != -1)
	check("and reaches the shell", echoed)

	# ── one write transaction: body, pause, Enter ────────────────────────
	# The echoed body shows the format string (TXN-%s); only the Enter can
	# make the shell run it and print TXN-OK.
	var txn: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "printf 'TXN-%s\\n' OK", "raw": true, "then_enter_after_ms": 800})
	check("a then_enter write is admitted as a transaction",
		txn.get("success", false) and int(txn.get("txn_id", 0)) > 0, str(txn))
	check("an unasked harness check is reported as not requested",
		str(txn.get("harness_check", "")) == "not_requested", str(txn))
	await create_timer(0.2).timeout
	var mid: String = session.get_plain_text()
	check("the body is on the screen before the Enter", mid.find("TXN-%s") != -1, mid.right(200))
	check("but the shell has not run it yet", mid.find("TXN-OK") == -1, mid.right(200))
	var committed: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("TXN-OK") != -1)
	check("the Enter lands and the shell runs the body", committed,
		session.read_viewport_text().right(300))

	# A transaction the harness guard refuses writes nothing at all — not even
	# the body, which a raw write would already have echoed.
	var refused: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "printf 'NOPE-%s\\n' SENT", "raw": true,
		"then_enter_after_ms": 50, "expect_harness": "codex"})
	if session.foreground_supported():
		check("a then_enter write is held while the wrong process is in front",
			not refused.get("success", true) and bool(refused.get("held", false)),
			str(refused))
		check("and the refusal says the harness check really ran",
			str(refused.get("harness_check", "")) == "checked", str(refused))
		await create_timer(0.4).timeout
		check("a refused transaction echoes nothing",
			session.get_plain_text().find("NOPE") == -1,
			session.read_viewport_text().right(300))
	else:
		check("where the foreground cannot be read the transaction is admitted, skipped",
			refused.get("success", false)
				and str(refused.get("harness_check", "")) == "skipped", str(refused))
		var skipped_ran: bool = await _wait_until(func() -> bool:
			return session.get_plain_text().find("NOPE-SENT") != -1)
		check("and it still commits body then Enter", skipped_ran,
			session.read_viewport_text().right(300))

	# ── a guarded raw write is refused, never queued ─────────────────────
	# The guards a raw write asks for are true at the moment of the call only.
	# Queued behind a transaction it would reach the shell after the pause with
	# nothing re-checked, so it is refused and the sender retries. An unguarded
	# write carries no such promise and still queues.
	var holder: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "printf 'HOLD-%s\\n' OK", "raw": true, "then_enter_after_ms": 400})
	check("a transaction is admitted and holds the terminal",
		holder.get("success", false) and int(holder.get("txn_id", 0)) > 0, str(holder))
	var busy: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "echo GUARDED-BUSY\r", "raw": true, "unless_typed_within_ms": 1})
	check("a guarded raw write is held while a transaction is in flight",
		not busy.get("success", true) and bool(busy.get("held", false))
			and str(busy.get("outcome", "")) == "refused_transaction_in_flight", str(busy))
	var queued: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "echo QUEUED-OK\r", "raw": true})
	check("an unguarded raw write is queued behind it instead",
		queued.get("success", false) and bool(queued.get("queued", false)), str(queued))
	var released: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("QUEUED-OK") != -1)
	check("the queued write reaches the shell once the transaction ends", released,
		session.read_viewport_text().right(300))
	check("and the refused one never did",
		session.get_plain_text().find("GUARDED-BUSY") == -1,
		session.read_viewport_text().right(300))

	registry.close_session(tid)

	await _test_harness_check_skipped()
	_test_no_direct_pty_writes()


## Where the platform cannot read the PTY's foreground (ConPTY), the guard
## cannot run — and the receipt must say so instead of passing silently. The
## session, its arbiter and the tool module are real; only the platform answer
## is substituted.
func _test_harness_check_skipped() -> void:
	var blind = _BlindSession.new("blind-tab")
	root.add_child(blind)
	if not blind.terminal_available or not blind.start(80, 24):
		print("SKIP: PTY unavailable for the blind-foreground oracle")
		blind.queue_free()
		return
	var tools = _make_script(BLIND_TOOLS_SRC).new()
	tools.blind_session = blind

	var raw: Dictionary = tools._terminal_write(
		{"text": "echo BLIND-RAW\r", "raw": true, "expect_harness": "claude"})
	check("a raw write says the harness check was skipped, not passed",
		raw.get("success", false) and str(raw.get("harness_check", "")) == "skipped", str(raw))
	var raw_ran: bool = await _wait_until(func() -> bool:
		return blind.get_plain_text().find("BLIND-RAW") != -1)
	check("and the text still reaches the shell", raw_ran, blind.read_viewport_text().right(200))

	var txn: Dictionary = tools._terminal_write({"text": "printf 'BLIND-%s\\n' TXN",
		"raw": true, "then_enter_after_ms": 100, "expect_harness": "claude"})
	check("a transaction says the same", txn.get("success", false)
		and str(txn.get("harness_check", "")) == "skipped", str(txn))
	var txn_ran: bool = await _wait_until(func() -> bool:
		return blind.get_plain_text().find("BLIND-TXN") != -1)
	check("and it still commits body then Enter", txn_ran, blind.read_viewport_text().right(200))

	blind.close()
	blind.queue_free()


## The PTY has ONE writer: the session. Source inspection, because the rule is
## about what the tree contains, not about what one run happened to execute.
func _test_no_direct_pty_writes() -> void:
	var offenders: PackedStringArray = []
	_scan_for_direct_writes("res://Scripts", offenders)
	check("no host code writes the terminal extension node directly",
		offenders.is_empty(), ", ".join(offenders))


func _scan_for_direct_writes(dir_path: String, offenders: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_scan_for_direct_writes(dir_path.path_join(sub), offenders)
	for file_name in dir.get_files():
		if not file_name.ends_with(".gd"):
			continue
		var path: String = dir_path.path_join(file_name)
		if path.ends_with("Terminal/TerminalSession.gd"):
			continue
		if FileAccess.get_file_as_string(path).contains("terminal.write_input("):
			offenders.append(path)


## A real session on a platform that cannot report the PTY's foreground.
class _BlindSession extends "res://Scripts/Services/Terminal/TerminalSession.gd":
	func foreground_supported() -> bool:
		return false


## The real tool module, pointed at one session instead of the registry.
## Built at runtime: a static inner class extending the module would pull it
## into this script's compilation, which happens before the autoloads it
## references are registered.
const BLIND_TOOLS_SRC := """
extends "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"
var blind_session = null

func _resolve_session(_terminal_id: String = ""):
	return blind_session
"""


func _make_script(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	return script


## Pure classification of what the foreground process is.
func _test_harness_of(session) -> void:
	check("claude binary is claude", session.harness_of({"name": "claude", "argv": ["claude"]}) == "claude")
	check("codex binary is codex", session.harness_of({"name": "codex", "argv": ["codex", "--yolo"]}) == "codex")
	check("node running the claude-code package is claude",
		session.harness_of({"name": "node",
			"argv": ["node", "/home/u/.nvm/versions/node/v22/lib/node_modules/@anthropic-ai/claude-code/cli.js"]}) == "claude")
	check("node running the npm codex package is codex",
		session.harness_of({"name": "node",
			"argv": ["node", "/home/u/.nvm/versions/node/v24/lib/node_modules/@openai/codex/bin/codex.js"]}) == "codex")
	check("an interpreter running a script named codex, even under a path with a space, is codex",
		session.harness_of({"name": "python3", "argv": ["/usr/bin/python3", "/home/u/my tools/codex"]}) == "codex")
	# An npm-installed harness: node renames its main thread to "MainThread",
	# so only the executable and argv name the program.
	check("npm Codex behind a renamed main thread is codex",
		session.harness_of({"name": "MainThread",
			"exe": "/home/u/.nvm/versions/node/v24/bin/node",
			"argv": ["node", "/home/u/.nvm/versions/node/v24/bin/codex", "--yolo"]}) == "codex")
	# A launcher symlink whose target is named by version: the executable's
	# basename says nothing, argv[0] says claude.
	check("native Claude Code behind a versioned launcher is claude",
		session.harness_of({"name": "claude",
			"exe": "/home/u/.local/share/claude/versions/2.1.278",
			"argv": ["claude", "--dangerously-skip-permissions"]}) == "claude")
	check("with no argv the program comes from the executable",
		session.harness_of({"name": "MainThread", "exe": "/usr/local/bin/codex", "argv": []}) == "codex")
	# The binary decides: a process that only CLAIMS a harness name in argv[0]
	# is what its executable says it is, and a native harness that rewrote its
	# own title is still what its executable says it is.
	check("exec -a codex sleep is sleep, not a harness",
		session.harness_of({"name": "codex", "exe": "/usr/bin/sleep",
			"argv": ["codex", "30"]}) == "")
	check("a native codex launched through a symlink to its release filename is codex",
		session.harness_of({"name": "codex", "exe": "/opt/codex/codex-x86_64-unknown-linux-gnu",
			"argv": ["codex", "--yolo"]}) == "codex")
	check("a binary merely starting with the name is nobody",
		session.harness_of({"name": "codexpert", "exe": "/usr/bin/codexpert",
			"argv": ["codexpert"]}) == "")
	check("a native codex that retitled its argv is still codex",
		session.harness_of({"name": "codex", "exe": "/opt/codex/bin/codex",
			"argv": ["codex worker: idle"]}) == "codex")
	check("a pager opened on a file named codex is nobody",
		session.harness_of({"name": "less", "argv": ["less", "codex"]}) == "")
	check("node running something else is nobody",
		session.harness_of({"name": "node", "argv": ["node", "server.js"]}) == "")
	check("the shell is nobody", session.harness_of({"name": "bash", "argv": ["/bin/bash", "--norc"]}) == "")
	check("no process is nobody", session.harness_of({}) == "")


## An interpreter-shaped regression fixture on a real PTY: node run on a
## script named `codex`, the shape of an npm-installed harness, classified
## from the executable and argv rather than the thread name. The script exits
## on any stdin line, because these PTYs run with ISIG off and cannot be
## interrupted with Ctrl-C.
const NODE_HARNESS_SRC := """
process.stdin.on('data', () => process.exit(0));
setTimeout(() => process.exit(0), 30000);
"""


func _test_npm_harness_foreground(session) -> void:
	var node_path: Array = []
	if OS.execute("which", ["node"], node_path) != 0:
		print("SKIP: node not on PATH — the npm-harness oracle is the table row")
		return
	var dir_path: String = "user://terminal_identity_oracle"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var script_path: String = ProjectSettings.globalize_path(dir_path.path_join("codex"))
	var f := FileAccess.open(script_path, FileAccess.WRITE)
	if f == null:
		check("the npm-harness script could be written", false, script_path)
		return
	f.store_string(NODE_HARNESS_SRC)
	f.close()

	session.write_input("node '%s'\r" % script_path)
	# Readiness is observed from argv — a fact the classifier under test does
	# not produce — so a wrong classification cannot also hide the fixture.
	var running: bool = await _wait_until(func() -> bool:
		var argv: Array = Array(session.get_foreground_process().get("argv", []))
		return argv.size() == 2 and str(argv[1]) == script_path)
	var process: Dictionary = session.get_foreground_process()
	check("an npm-shaped harness is in the foreground", running, str(process))
	# Whether this node renames its main thread is the runtime's business
	# (newer ones report "MainThread" on Linux, older ones "node", macOS the
	# process name); the classification below must not depend on it, and the
	# renamed shape itself is pinned by the table row.
	check("the executable names the interpreter",
		str(process.get("exe_name", "")) == "node"
			and str(process.get("exe", "")).ends_with("/node"), str(process))
	check("argv carries the interpreter and the script",
		Array(process.get("argv", [])) == ["node", script_path], str(process))
	check("and the host calls it codex", session.harness_of(process) == "codex", str(process))
	var listed: Dictionary = _entry_for(load(TERMINAL_TOOLS_PATH).new(), str(session.terminal_id))
	check("the listing names the program, not the thread, and the harness",
		str(listed.get("foreground_process", "")) == "node"
			and str(listed.get("harness", "")) == "codex", str(listed))

	session.write_input("\r")
	var gone: bool = await _wait_until(func() -> bool:
		return session.harness_name() == "")
	check("when it ends the shell is back in front", gone,
		str(session.get_foreground_process()))


func _entry_for(tools, tid: String) -> Dictionary:
	for e: Dictionary in tools._terminal_list({}).get("terminals", []):
		if str(e.get("id", "")) == tid:
			return e
	return {}
