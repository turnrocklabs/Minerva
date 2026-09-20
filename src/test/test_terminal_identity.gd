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
##   - terminal_list carries last_input_ms and the foreground process, and a
##     human keystroke stamp moves last_input_ms to now.

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
			and str(guarded.get("error", "")).contains("nothing was written"), str(guarded))
	var wrong_harness: Dictionary = tools._terminal_write(
		{"terminal_id": tid, "text": "echo agent\r", "raw": true, "expect_harness": "codex"})
	check("a write that expects a harness is held while the shell is in front",
		not wrong_harness.get("success", true) and bool(wrong_harness.get("held", false)),
		str(wrong_harness))
	var unguarded: Dictionary = tools._terminal_write(
		{"terminal_id": tid, "text": "echo GUARD-OFF\r", "raw": true})
	check("an unguarded write goes through", unguarded.get("success", false), str(unguarded))
	var echoed: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("GUARD-OFF") != -1)
	check("and reaches the shell", echoed)

	registry.close_session(tid)


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
	check("a pager opened on a file named codex is nobody",
		session.harness_of({"name": "less", "argv": ["less", "codex"]}) == "")
	check("node running something else is nobody",
		session.harness_of({"name": "node", "argv": ["node", "server.js"]}) == "")
	check("the shell is nobody", session.harness_of({"name": "bash", "argv": ["/bin/bash", "--norc"]}) == "")
	check("no process is nobody", session.harness_of({}) == "")


func _entry_for(tools, tid: String) -> Dictionary:
	for e: Dictionary in tools._terminal_list({}).get("terminals", []):
		if str(e.get("id", "")) == tid:
			return e
	return {}
