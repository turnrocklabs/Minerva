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
##   - the composer guard reads CELL STYLES, not row text: the same input box
##     painted with a faint placeholder lets a guarded write through and
##     painted plain refuses it as unsent human text, with nothing written;
##     a box whose first line is empty is judged on the rows below it, blank
##     rows included, the same way; no row shape is exempt, so a lone numbered
##     line, a numbered two-item draft and a chooser's plain option block all
##     read as occupied; the region runs from the marker row above the cursor
##     through the cursor row, so a pasted box-drawing rule is read past and an
##     indented marker glyph is draft text; a row inside the region drawn faint
##     or in colour is chrome; below the cursor a blank row ends the region
##     once a faint placeholder has shown the box empty, so a plain footer
##     under an empty box does not hold the write, while a draft below a blank
##     row under the cursor still does; a
##     Claude-named harness is read with its own markers: the no-break space
##     after `❯` still opens an empty box, and a shell-mode `!` or memo-mode
##     `#` row is a draft; with no harness in front there is no marker row to
##     find and the receipt says the check was skipped;
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

	# The command is left to end on its own here; interrupting it is the
	# signal suite's oracle (test_terminal_signals.gd).
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

	await _test_composer_guard(session, tools)

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
## on any stdin line, which is what this fixture needs: the classification is
## the oracle here, not how the program is ended.
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


## A harness that paints an input box on demand and nothing else, so the
## screen the composer guard reads is exactly what the test asked for. It is
## run twice: under the name `codex` and under the name `claude` — node is the
## npm-harness shape, so the host classifies the foreground from the script's
## name and derives the marker itself.
## `dim` is an EMPTY box — the placeholder both harnesses draw inside one,
## faint (SGR 2); `plain` is the same row plain, which is what a line a person
## typed looks like.
##
## `numbered`, `draft` and `chooser` are the shapes a text-only heuristic trips
## over: a lone numbered line, a two-item numbered draft, and a permission
## screen's plain option block. All three are occupied as far as the guard is
## concerned — a person's draft must not be submitted, and nothing may be typed
## into a chooser either.
##
## `wrapped`, `wrapped_dim` and `spaced` are boxes whose first line is empty
## and whose text is on a row below — what a multi-line prompt looks like.
## `spaced` puts a blank row in between, which does not end the composer.
##
## `ruled` is a draft with a box-drawing rule pasted into it: the rule carries
## no text and is read past, so the plain row under it still holds. `quoted`
## puts the marker glyph itself inside the draft, indented — the region's top is
## the real marker row above it, at column 0. `footer_dim`, `footer_colour`
## and `footer_palette` are an empty box with a status row two rows below it
## and the cursor left under the block, so the row is inside the region and
## its style decides: faint or in colour (the real codex draws its model line
## in truecolor and its slash popup in a bold palette colour, and the real
## Claude Code its status rows in truecolor) the box is empty. `footer_plain`
## puts the cursor back in the box, where a real harness is assumed to keep
## it (not measured), and draws the footer plain: the placeholder shows the box
## is empty, so the blank row under the cursor ends the region and the footer
## is not read. `cursor_above` is a
## draft whose first line is empty, with the cursor moved up onto it and the
## text below a blank row: no placeholder shows, so that blank row does not
## end the region and the draft holds.
##
## `claude_dim`, `bang` and `memo` are the Claude Code shapes: `❯` followed by
## a NO-BREAK space and a faint placeholder is an empty box; a shell-mode row
## opens with a coloured `!` and a plain command; a memo row opens with `#`.
##
## Every block ends with a blank row (`footer_plain` and `cursor_above` then
## move the cursor back into the box) and is drawn from column 0 after erasing
## what lies below the cursor, so one scenario's rows are never read as part
## of another's.
##
## Input arrives in whatever chunks the PTY delivers, and one chunk can carry
## several newline-delimited commands, so stdin is buffered and split rather
## than read one command per data event.
const COMPOSER_HARNESS_SRC := """
const ROWS = {
  dim: "\\u001b[2m\\u203a Try \\"/status\\"\\u001b[0m\\r\\n\\r\\n",
  plain: "\\u203a the sentence I have not sent yet\\r\\n\\r\\n",
  chooser: "\\u203a 1. Yes, proceed\\r\\n  2. No, tell me what to do instead\\r\\n\\r\\n",
  numbered: "\\u203a 1. Review this change\\r\\n\\r\\n",
  draft: "\\u203a 1. Review this change\\r\\n  2. Check the tests\\r\\n\\r\\n",
  wrapped: "\\u203a\\r\\n  the second line of what I typed\\r\\n\\r\\n",
  wrapped_dim: "\\u203a\\r\\n\\u001b[2m  Press Enter to send\\u001b[0m\\r\\n\\r\\n",
  spaced: "\\u203a\\r\\n\\r\\n  after a blank row I kept typing\\r\\n\\r\\n",
  ruled: "\\u203a\\r\\n" + "\\u2550".repeat(60) + "\\r\\n  text under a pasted rule\\r\\n\\r\\n",
  quoted: "\\u203a\\r\\n  \\u203a quoted line I pasted\\r\\n\\r\\n",
  ruleonly: "\\u203a\\r\\n  \\u2550\\u2550\\u2550\\u2550\\u2550\\u2550\\u2550\\u2550\\r\\n\\r\\n",
  footer_dim: "\\u001b[2m\\u203a Try \\"/status\\"\\u001b[0m\\r\\n\\r\\n\\u001b[2m  gpt-5.5 faint-footer\\u001b[0m\\r\\n\\r\\n",
  footer_colour: "\\u001b[2m\\u203a Try \\"/status\\"\\u001b[0m\\r\\n\\r\\n  \\u001b[38;2;246;226;183mgpt-5.5 colour-footer\\u001b[0m\\r\\n\\r\\n",
  footer_plain: "\\u001b[2m\\u203a Try \\"/status\\"\\u001b[0m\\r\\n\\r\\n  gpt-5.5 plain-footer\\r\\n\\r\\n\\u001b[4A\\u001b[3G",
  cursor_above: "\\u203a\\r\\n\\r\\n  a draft line below the cursor\\r\\n\\r\\n\\u001b[4A\\u001b[2G",
  footer_palette: "\\u001b[2m\\u203a Try \\"/status\\"\\u001b[0m\\r\\n\\r\\n  \\u001b[1m\\u001b[38;5;6m/status palette-footer\\u001b[0m\\r\\n\\r\\n",
  claude_dim: "\\u276f\\u00a0\\u001b[2mTry \\"fix typecheck errors\\"\\u001b[22m\\r\\n\\r\\n",
  bang: "\\u001b[38;2;253;93;177m!\\u00a0\\u001b[39mecho hi from shell mode\\r\\n\\r\\n",
  memo: "# memo text I have not sent\\r\\n\\r\\n",
};
// A real harness owns the terminal in raw mode with echo off; without this
// the PTY echoes the test's typed command onto the row the marker lands on,
// pushing the marker off column 0.
if (process.stdin.isTTY) { process.stdin.setRawMode(true); }
process.stdout.write("COMPOSER-READY\\r\\n");
let pending = "";
process.stdin.on('data', (d) => {
  pending += d.toString();
  let cut;
  while ((cut = pending.search(/[\\r\\n]/)) !== -1) {
    const key = pending.slice(0, cut).trim();
    pending = pending.slice(cut + 1);
    if (key === 'quit') { process.exit(0); }
    if (ROWS[key]) { process.stdout.write("\\r\\u001b[J" + ROWS[key]); }
    else if (key) { process.stdout.write("RECV:" + key + "\\r\\n"); }
  }
});
setTimeout(() => process.exit(0), 120000);
"""


## The composer guard: an input box holding a line a person typed and did not
## submit refuses the write, and the SAME row drawn faint does not. Row text is
## identical in shape either way — only the cell attribute separates them, so
## a guard that read text alone would fail one of these two legs. The region it
## reads runs from the marker row nearest above the cursor down through the
## cursor row, so a blank row inside a draft and a pasted rule are inside it;
## below the cursor a blank row ends it only after the placeholder has shown the
## box empty, so a footer under an empty box is not read and a draft below the
## cursor is. No row shape buys an exemption.
func _test_composer_guard(session, tools) -> void:
	var tid: String = str(session.terminal_id)
	# With a bare shell in front there is no harness whose box to look for, and
	# the receipt has to SAY the check was skipped rather than pass it silently.
	var no_harness: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "echo COMPOSER-SKIPPED\r", "raw": true, "unless_composer_holds_text": true})
	check("with no harness in front the composer check is skipped, not passed",
		no_harness.get("success", false)
			and str(no_harness.get("composer_check", "")) == "skipped", str(no_harness))

	if not session.foreground_supported():
		print("SKIP: this platform cannot read the foreground — no harness to derive a marker from")
		return
	var node_path: Array = []
	if OS.execute("which", ["node"], node_path) != 0:
		print("SKIP: node not on PATH — the composer oracle needs a codex-named harness")
		return
	if not await _start_composer_harness(session, "codex"):
		return

	# An EMPTY box: its placeholder is faint, and nothing a person types is.
	session.write_input("dim\r")
	var dim_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("/status") != -1)
	check("the harness painted its empty box", dim_up, session.read_viewport_text().right(300))
	var through: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-PASSED\r", "raw": true, "unless_composer_holds_text": true})
	check("a faint placeholder is an EMPTY composer, and the guarded write goes through",
		through.get("success", false)
			and str(through.get("composer_check", "")) == "checked", str(through))
	var landed: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("COMPOSER-PASSED") != -1)
	check("and its bytes reached the PTY", landed, session.read_viewport_text().right(300))

	# The same row plain: a finished line nobody submitted.
	session.write_input("plain\r")
	var plain_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("have not sent yet") != -1)
	check("the harness painted a box holding an unsent line", plain_up,
		session.read_viewport_text().right(300))
	var held: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-REFUSED\r", "raw": true, "unless_composer_holds_text": true})
	check("a raw write into an occupied composer is held, and names the guard",
		not held.get("success", true) and bool(held.get("held", false))
			and str(held.get("outcome", "")) == "refused_composer_not_empty"
			and str(held.get("composer_check", "")) == "checked"
			and str(held.get("error", "")).contains("holds unsent text"), str(held))
	var txn: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-TXN", "raw": true, "then_enter_after_ms": 50,
		"unless_composer_holds_text": true})
	check("and so is a transaction, refused on the same evidence",
		not txn.get("success", true) and bool(txn.get("held", false))
			and str(txn.get("outcome", "")) == "refused_composer_not_empty"
			and not txn.has("txn_id"), str(txn))
	await create_timer(0.4).timeout
	var screen: String = session.get_plain_text()
	check("neither refusal put a byte on the screen",
		screen.find("COMPOSER-REFUSED") == -1 and screen.find("COMPOSER-TXN") == -1,
		session.read_viewport_text().right(300))

	# A box whose FIRST line is empty still holds what a person typed on the
	# row below it: reading the marker row alone would call this box empty.
	session.write_input("wrapped\r")
	var wrapped_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("the second line of what I typed") != -1)
	check("the harness painted a box whose text starts on the next row", wrapped_up,
		session.read_viewport_text().right(300))
	var wrapped: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-WRAPPED\r", "raw": true, "unless_composer_holds_text": true})
	check("plain text on a continuation row is unsent text too",
		not wrapped.get("success", true) and bool(wrapped.get("held", false))
			and str(wrapped.get("outcome", "")) == "refused_composer_not_empty", str(wrapped))

	# The same shape with a FAINT continuation is a placeholder, not a line.
	session.write_input("wrapped_dim\r")
	var wrapped_dim_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("Press Enter to send") != -1)
	check("the harness painted a faint continuation row", wrapped_dim_up,
		session.read_viewport_text().right(300))
	var wrapped_dim: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-FAINTLINE\r", "raw": true, "unless_composer_holds_text": true})
	check("a faint continuation row is an EMPTY composer, and the write goes through",
		wrapped_dim.get("success", false)
			and str(wrapped_dim.get("composer_check", "")) == "checked", str(wrapped_dim))

	# A blank row inside the box does not end it: the typing goes on below.
	session.write_input("spaced\r")
	var spaced_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("after a blank row I kept typing") != -1)
	check("the harness painted a box with a blank row inside it", spaced_up,
		session.read_viewport_text().right(300))
	var spaced: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-SPACED\r", "raw": true, "unless_composer_holds_text": true})
	check("text below a blank row is still unsent text",
		not spaced.get("success", true) and bool(spaced.get("held", false))
			and str(spaced.get("outcome", "")) == "refused_composer_not_empty"
			and str(spaced.get("composer_check", "")) == "checked", str(spaced))

	# A pasted box-drawing rule carries no text, so the region reads PAST it and
	# the plain row under it still holds — and the refusal quotes that row.
	session.write_input("ruled\r")
	var ruled_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("text under a pasted rule") != -1)
	check("the harness painted a draft split by a pasted box-drawing rule", ruled_up,
		session.read_viewport_text().right(300))
	var ruled: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-RULED\r", "raw": true, "unless_composer_holds_text": true})
	check("a pasted rule does not end the region, and the refusal quotes the row it read",
		not ruled.get("success", true) and bool(ruled.get("held", false))
			and str(ruled.get("outcome", "")) == "refused_composer_not_empty"
			and str(ruled.get("error", "")).contains("text under a pasted rule"), str(ruled))

	# The marker glyph inside a draft is INDENTED; the region's top is the real
	# marker row above it, at column 0, so the quoted line still reads as unsent.
	session.write_input("quoted\r")
	var quoted_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("quoted line I pasted") != -1)
	check("the harness painted a draft holding the marker glyph itself", quoted_up,
		session.read_viewport_text().right(300))
	var quoted: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-QUOTED\r", "raw": true, "unless_composer_holds_text": true})
	# A draft that is nothing but box-drawing glyphs on an indented row is
	# still a draft: only a rule drawn from column 0 is chrome.
	session.write_input("ruleonly\r")
	var ruleonly_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("\u2550\u2550\u2550\u2550") != -1)
	check("the harness painted an indented rule-only draft", ruleonly_up,
		session.read_viewport_text().right(300))
	var ruleonly: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-RULEONLY\r", "raw": true, "unless_composer_holds_text": true})
	check("an indented rule-only draft is unsent text",
		not ruleonly.get("success", true) and bool(ruleonly.get("held", false))
			and str(ruleonly.get("outcome", "")) == "refused_composer_not_empty", str(ruleonly))
	check("an indented marker glyph is draft text, not the composer row",
		not quoted.get("success", true) and bool(quoted.get("held", false))
			and str(quoted.get("outcome", "")) == "refused_composer_not_empty"
			and str(quoted.get("error", "")).contains("quoted line I pasted"), str(quoted))

	# With the cursor left under the block, the footer is inside the region and
	# its style decides. Drawn faint, the box is empty.
	session.write_input("footer_dim\r")
	var footer_dim_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("faint-footer") != -1)
	check("the harness painted an empty box over a faint footer", footer_dim_up,
		session.read_viewport_text().right(300))
	var footer_dim: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-FOOTERDIM\r", "raw": true, "unless_composer_holds_text": true})
	check("a faint footer below the box leaves the composer empty",
		footer_dim.get("success", false)
			and str(footer_dim.get("composer_check", "")) == "checked", str(footer_dim))

	# The same footer drawn in COLOUR — how the real codex paints its model line
	# — is chrome too, and the box stays empty.
	session.write_input("footer_colour\r")
	var footer_colour_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("colour-footer") != -1)
	check("the harness painted the same box over a coloured footer", footer_colour_up,
		session.read_viewport_text().right(300))
	var footer_colour: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-FOOTERCOLOUR\r", "raw": true, "unless_composer_holds_text": true})
	check("a coloured footer below the box leaves the composer empty",
		footer_colour.get("success", false)
			and str(footer_colour.get("composer_check", "")) == "checked", str(footer_colour))

	# A palette colour is a colour too: the popup rows codex draws under a
	# typed slash command are bold palette cyan, and chrome all the same.
	session.write_input("footer_palette\r")
	var footer_palette_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("palette-footer") != -1)
	check("the harness painted the same box over a palette-coloured row", footer_palette_up,
		session.read_viewport_text().right(300))
	var footer_palette: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-FOOTERPALETTE\r", "raw": true, "unless_composer_holds_text": true})
	check("a palette-coloured row below the box leaves the composer empty",
		footer_palette.get("success", false)
			and str(footer_palette.get("composer_check", "")) == "checked", str(footer_palette))

	# A real harness is assumed (not measured) to keep the cursor in its box.
	# Its faint placeholder shows the box is empty, so the blank row below the
	# cursor ends the region: a footer drawn PLAIN (a session title, say) is not
	# read and the box takes the write.
	session.write_input("footer_plain\r")
	var footer_plain_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("plain-footer") != -1)
	check("the harness painted the same box over a plain footer", footer_plain_up,
		session.read_viewport_text().right(300))
	var footer_plain: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-FOOTERPLAIN\r", "raw": true, "unless_composer_holds_text": true})
	check("a plain footer past a blank row under the cursor leaves the composer empty",
		footer_plain.get("success", false)
			and str(footer_plain.get("composer_check", "")) == "checked", str(footer_plain))

	# With no placeholder, the same blank row may be inside a draft: its first
	# line empty, the cursor moved up onto it, its text further down. The region
	# reads past the blank row and holds.
	session.write_input("cursor_above\r")
	var cursor_above_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("a draft line below the cursor") != -1)
	check("the harness painted a draft below a blank row under the cursor", cursor_above_up,
		session.read_viewport_text().right(300))
	var cursor_above: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-CURSORABOVE\r", "raw": true, "unless_composer_holds_text": true})
	check("draft text below a blank row under the cursor is still unsent text",
		not cursor_above.get("success", true) and bool(cursor_above.get("held", false))
			and str(cursor_above.get("outcome", "")) == "refused_composer_not_empty"
			and str(cursor_above.get("error", "")).contains("a draft line below the cursor"), str(cursor_above))

	# A numbered line is what a person types as often as what a chooser draws.
	# The guard exempts no shape, so it is held like any other plain row.
	session.write_input("numbered\r")
	var numbered_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("1. Review this change") != -1)
	check("the harness painted a lone numbered line in the box", numbered_up,
		session.read_viewport_text().right(300))
	var numbered: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-NUMBERED\r", "raw": true, "unless_composer_holds_text": true})
	check("a lone numbered row is a person's own prompt, and is held",
		not numbered.get("success", true) and bool(numbered.get("held", false))
			and str(numbered.get("outcome", "")) == "refused_composer_not_empty"
			and str(numbered.get("composer_check", "")) == "checked", str(numbered))

	# Two numbered lines look exactly like a chooser's option block, and are a
	# person's own list. Any heuristic that let the block through would submit
	# this draft, so the block is not a shape the guard recognises.
	session.write_input("draft\r")
	var draft_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("2. Check the tests") != -1)
	check("the harness painted a two-item numbered draft", draft_up,
		session.read_viewport_text().right(300))
	var draft: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-DRAFT\r", "raw": true, "unless_composer_holds_text": true})
	check("a numbered two-item draft is held like any other unsent text",
		not draft.get("success", true) and bool(draft.get("held", false))
			and str(draft.get("outcome", "")) == "refused_composer_not_empty"
			and str(draft.get("composer_check", "")) == "checked", str(draft))

	# A chooser's selected option opens with the SAME marker and is plain, and
	# reads as occupied here. The reason names the composer, but the action is
	# the right one: nothing may be typed into a permission screen either.
	session.write_input("chooser\r")
	var chooser_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("2. No, tell me what to do instead") != -1)
	check("the harness painted a selected option and its sibling", chooser_up,
		session.read_viewport_text().right(300))
	var chooser: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-CHOOSER\r", "raw": true, "unless_composer_holds_text": true})
	check("a chooser's plain option block is checked, and held",
		not chooser.get("success", true) and bool(chooser.get("held", false))
			and str(chooser.get("outcome", "")) == "refused_composer_not_empty"
			and str(chooser.get("composer_check", "")) == "checked", str(chooser))

	await create_timer(0.4).timeout
	# The whole scrollback, not the viewport: the earlier passes have scrolled
	# off the top by now.
	var after: String = ""
	for row in range(int(session.get_scroll_info().get("total_rows", 0))):
		after += session.extract_row_text_screen(row) + "\n"
	check("every refusal was withheld from the screen and only the passes landed",
		after.find("COMPOSER-WRAPPED") == -1 and after.find("COMPOSER-SPACED") == -1
			and after.find("COMPOSER-NUMBERED") == -1 and after.find("COMPOSER-DRAFT") == -1
			and after.find("COMPOSER-CHOOSER") == -1 and after.find("COMPOSER-RULED") == -1
			and after.find("COMPOSER-QUOTED") == -1
			and after.find("COMPOSER-CURSORABOVE") == -1
			and after.find("COMPOSER-FAINTLINE") != -1
			and after.find("COMPOSER-FOOTERPLAIN") != -1
			and after.find("COMPOSER-FOOTERDIM") != -1
			and after.find("COMPOSER-FOOTERCOLOUR") != -1
			and after.find("COMPOSER-FOOTERPALETTE") != -1,
		session.read_viewport_text().right(300))

	session.write_input("quit\r")
	var gone: bool = await _wait_until(func() -> bool: return session.harness_name() == "")
	check("the composer harness exited and the shell is back in front", gone,
		str(session.get_foreground_process()))

	# The same box under the Claude Code name, read with Claude Code's markers.
	if not await _start_composer_harness(session, "claude"):
		return
	session.write_input("claude_dim\r")
	var claude_dim_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("fix typecheck errors") != -1)
	check("the claude-named harness painted its empty box", claude_dim_up,
		session.read_viewport_text().right(300))
	var claude_dim: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-CLAUDEDIM\r", "raw": true, "unless_composer_holds_text": true})
	check("a no-break space after the marker still reads as an empty box",
		claude_dim.get("success", false)
			and str(claude_dim.get("composer_check", "")) == "checked", str(claude_dim))

	session.write_input("bang\r")
	var bang_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("echo hi from shell mode") != -1)
	check("the harness painted a shell-mode draft", bang_up, session.read_viewport_text().right(300))
	var bang: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-BANG\r", "raw": true, "unless_composer_holds_text": true})
	check("a shell-mode row is a draft: the coloured prefix is the marker, the command holds",
		not bang.get("success", true) and bool(bang.get("held", false))
			and str(bang.get("outcome", "")) == "refused_composer_not_empty"
			and str(bang.get("error", "")).contains("echo hi from shell mode"), str(bang))

	session.write_input("memo\r")
	var memo_up: bool = await _wait_until(func() -> bool:
		return session.read_viewport_text().find("memo text I have not sent") != -1)
	check("the harness painted a memo-mode draft", memo_up, session.read_viewport_text().right(300))
	var memo: Dictionary = tools._terminal_write({"terminal_id": tid,
		"text": "COMPOSER-MEMO\r", "raw": true, "unless_composer_holds_text": true})
	check("a memo-mode row is a draft and holds",
		not memo.get("success", true) and bool(memo.get("held", false))
			and str(memo.get("outcome", "")) == "refused_composer_not_empty", str(memo))

	await create_timer(0.4).timeout
	var claude_after: String = ""
	for row in range(int(session.get_scroll_info().get("total_rows", 0))):
		claude_after += session.extract_row_text_screen(row) + "\n"
	check("under the claude name too only the pass landed on the screen",
		claude_after.find("COMPOSER-CLAUDEDIM") != -1 and claude_after.find("COMPOSER-BANG") == -1
			and claude_after.find("COMPOSER-MEMO") == -1, session.read_viewport_text().right(300))

	session.write_input("quit\r")
	var claude_gone: bool = await _wait_until(func() -> bool: return session.harness_name() == "")
	check("the claude-named harness exited and the shell is back in front", claude_gone,
		str(session.get_foreground_process()))


## Writes the composer harness under *harness_name* and runs it with node, so
## the host classifies the foreground by that name. False when it could not
## be written or did not come up, with the check already recorded.
func _start_composer_harness(session, harness_name: String) -> bool:
	var dir_path: String = "user://terminal_identity_composer"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var script_path: String = ProjectSettings.globalize_path(dir_path.path_join(harness_name))
	var f := FileAccess.open(script_path, FileAccess.WRITE)
	if f == null:
		check("the composer harness script could be written as " + harness_name, false, script_path)
		return false
	f.store_string(COMPOSER_HARNESS_SRC)
	f.close()
	session.write_input("node '%s'\r" % script_path)
	var ready: bool = await _wait_until(func() -> bool:
		return session.harness_name() == harness_name \
			and session.get_plain_text().find("COMPOSER-READY") != -1)
	check("a %s-named harness is in the foreground with its box ready" % harness_name, ready,
		session.read_viewport_text().right(300))
	return ready


func _entry_for(tools, tid: String) -> Dictionary:
	for e: Dictionary in tools._terminal_list({}).get("terminals", []):
		if str(e.get("id", "")) == tid:
			return e
	return {}
