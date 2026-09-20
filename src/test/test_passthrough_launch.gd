extends SceneTree
## W3 (chat-passthrough): passthrough launch dialog.
##
## Run: timeout 120 godot --headless --path src --script test/test_passthrough_launch.gd
##
## Acceptance (W3 contract):
##   1. infer_profile table: claude/codex/opencode/unknown.
##   2. Validation: empty name blocks Start with an inline error; nonexistent
##      cwd blocks; bind-to-existing selection disables command/cwd fields.
##   3. Launch happy path (stub watch_starter registers the fake agent-relay
##      entry): background session exists in the registry with the right name,
##      the PTY received the cd + `exec bash -lc` writes, the chat is created
##      with PassthroughMode / BoundTerminalId / PassthroughCommand / Cwd.
##   4. Watch-fail + entry-timeout paths: inline error, session CLOSED (no
##      orphan), no chat created, dialog stays open.
##   5. shell_exited → program message lands exactly once in the bound chat,
##      carrying the terminal's last lines.
##   7. ShellEnvironment: delimited PATH capture survives rc noise, garbage is
##      rejected, PATH lookup (executability, launch-cwd relative entries) +
##      output tail behave; the probe itself installs a fake shell's PATH once
##      and refuses a capture from a shell that hung after printing it.
##   8. A startup command whose first word is not on PATH is refused before any
##      session or watch exists; a harness that dies on startup reports the
##      shell's last lines instead of the provider riddle.
##   6. ServiceHistory round-trip includes PassthroughCommand/PassthroughCwd;
##      old saves default empty.
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type
## (the `so` autoload-node harness pattern from test_passthrough_mode.gd).

const DIALOG_PATH := "res://Scripts/UI/Controls/PassthroughLaunchDialog.gd"
const SHELL_ENV_PATH := "res://Scripts/Services/Terminal/ShellEnvironment.gd"
const PROVIDER_REGISTRY_PATH := "res://Scripts/Services/Plugins/PluginChatProviderRegistry.gd"
const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const SERVICE_HISTORY_PATH := "res://Scripts/Models/ServiceHistory.gd"
const VBOX_CHAT_PATH := "res://Scripts/UI/Controls/vboxChat.gd"

## ChatPane subclass with the UI presentation of start_passthrough_chat stubbed
## out (render_history & friends need the full scene); the model build, the
## launch field-storage and the exit wiring under test stay REAL.
const PANE_STUB_SOURCE := """
extends "res://Scripts/UI/Views/ChatPane.gd"

var presented: Array = []

func start_passthrough_chat(entry_key: String, display_name: String, bound_terminal_id: String = "") -> ChatHistory:
	var history := _build_passthrough_history(entry_key, display_name, bound_terminal_id)
	if history != null:
		presented.append(history)
	return history
"""

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== W3 passthrough launch dialog test ===\n")
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


func _new_dialog():
	var d = load(DIALOG_PATH).new()
	root.add_child(d)  # _ready builds the form
	return d


func _new_stub_pane():
	var s := GDScript.new()
	s.source_code = PANE_STUB_SOURCE
	var err := s.reload()
	if err != OK:
		return null
	return s.new()


## Poll until predicate() is true or timeout. Returns predicate's final value.
func _wait_until(predicate: Callable, timeout_ms: int = 10000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return bool(predicate.call())


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return

	_test_infer_profile()
	_test_quoting()
	_test_shell_environment()
	_test_login_path_probe()
	await _test_path_guard(so)
	await _test_validation(so)
	await _test_happy_path(so)
	await _test_watch_fail_paths(so)
	await _test_launch_exit_note(so)
	await _test_shell_exit_message(so)
	_test_service_history_roundtrip()


# --- Acceptance 1 -----------------------------------------------------------
func _test_infer_profile() -> void:
	print("\n-- infer_profile table --")
	var D = load(DIALOG_PATH)
	check("claude command → claude",
		D.infer_profile("claude --dangerously-skip-permissions") == "claude")
	check("codex command → codex", D.infer_profile("codex -m gpt-5") == "codex")
	check("opencode command → opencode", D.infer_profile("opencode") == "opencode")
	check("unknown command → default claude", D.infer_profile("vim notes.txt") == "claude")
	check("empty command → default claude", D.infer_profile("") == "claude")
	check("case-insensitive", D.infer_profile("CLAUDE") == "claude")


func _test_quoting() -> void:
	print("\n-- shell quoting + launch incantation (both dialects) --")
	var D = load(DIALOG_PATH)
	check("shell_quote wraps in single quotes", D.shell_quote("abc") == "'abc'")
	check("shell_quote escapes embedded single quotes",
		D.shell_quote("a'b") == "'a'\\''b'", D.shell_quote("a'b"))
	# No login-shell wrapper: PATH is fixed on Minerva's own process, so the
	# command must reach the PTY bare (the user's ~/.profile chain is not a
	# dependency of the launch any more).
	check("build_launch_line posix runs a simple command under exec",
		D.build_launch_line("claude --x", false) == "exec bash -c 'claude --x'\r",
		D.build_launch_line("claude --x", false))
	check("build_launch_line posix has no LOGIN shell wrapper",
		not D.build_launch_line("claude --x", false).contains("-lc"))
	# `exec` takes a PROGRAM: an assignment prefix or a pipeline must reach the
	# shell as typed, or exec looks for a program called "FOO=1" / hands the
	# shell back only one component of the line.
	check("is_simple_command: plain command", D.is_simple_command("codex --yolo"))
	check("is_simple_command: quoted argument is still simple",
		D.is_simple_command("claude --msg \"a b\""))
	check("is_simple_command: env assignment is not simple",
		not D.is_simple_command("FOO=1 codex"))
	# Quoting the VALUE leaves the word an assignment — the shell still sets
	# FOO and runs codex, so exec must not be handed "FOO=1" as a program.
	check("is_simple_command: a single-quoted assignment value is still an assignment",
		not D.is_simple_command("FOO='1' codex"))
	check("is_simple_command: a double-quoted assignment value is still an assignment",
		not D.is_simple_command("FOO=\"a b\" codex"))
	# Quoting the NAME is what defeats it: `'FOO=1'` is a plain program word.
	check("is_simple_command: a quoted assignment NAME is a plain word",
		D.is_simple_command("'FOO=1' codex"))
	check("build_launch_line posix writes a quoted-value assignment bare",
		D.build_launch_line("FOO='1' codex", false) == "exec bash -c 'FOO='\\''1'\\'' codex'\r",
		D.build_launch_line("FOO='1' codex", false))
	check("is_simple_command: pipeline is not simple",
		not D.is_simple_command("codex | tee log"))
	check("is_simple_command: redirect is not simple",
		not D.is_simple_command("codex > log"))
	check("is_simple_command: list is not simple",
		not D.is_simple_command("cd /tmp && codex"))
	check("is_simple_command: empty line is not simple", not D.is_simple_command("  "))
	# Operators are the SHELL's only when they are unquoted: a `;` or `&&`
	# inside an argument belongs to the program, and losing the exec over it
	# leaves a wrapper shell alive in front of the harness.
	check("is_simple_command: a quoted operator belongs to the argument",
		D.is_simple_command("sh -c 'echo diagnostic; exit 7'"))
	check("is_simple_command: a quoted && belongs to the argument",
		D.is_simple_command("sh -c 'echo hi && sleep 30'"))
	check("is_simple_command: a double-quoted operator belongs to the argument",
		D.is_simple_command("sh -c \"echo hi | cat\""))
	check("is_simple_command: an escaped operator belongs to the argument",
		D.is_simple_command("echo a\\;b"))
	# A quoted first word is exec'able (exec resolves it itself), even though
	# the PATH preflight declines to judge it.
	check("is_simple_command: a quoted first word is still exec'able",
		D.is_simple_command("'my agent' --x"))
	check("is_simple_command: an expanded program word is still simple (the shell expands, then execs)",
		D.is_simple_command("$AGENT --x"))
	check("is_simple_command: an expanded argument is still simple",
		D.is_simple_command("codex --cd \"$HOME/project\""))
	check("build_launch_line: an expanded argument still launches under exec",
		D.build_launch_line("codex --cd \"$HOME/project\"", false) == "exec bash -c 'codex --cd \"$HOME/project\"'\r",
		D.build_launch_line("codex --cd \"$HOME/project\"", false))
	check("is_simple_command: an unterminated quote is not simple",
		not D.is_simple_command("sh -c 'oops"))
	check("build_launch_line execs a command whose operators are all quoted",
		D.build_launch_line("sh -c 'echo hi; exit 7'", false) == "exec bash -c 'sh -c '\\''echo hi; exit 7'\\'''\r",
		D.build_launch_line("sh -c 'echo hi; exit 7'", false))
	check("build_launch_line posix writes an env-assignment line bare",
		D.build_launch_line("FOO=1 codex", false) == "exec bash -c 'FOO=1 codex'\r",
		D.build_launch_line("FOO=1 codex", false))
	check("build_launch_line posix writes a pipeline bare",
		D.build_launch_line("codex | tee log", false) == "exec bash -c 'codex | tee log'\r",
		D.build_launch_line("codex | tee log", false))
	check("build_launch_line windows runs the bare command (cmd has no exec/bash)",
		D.build_launch_line("claude --x", true) == "claude --x\r",
		D.build_launch_line("claude --x", true))
	check("build_cd_line posix single-quotes + \\r",
		D.build_cd_line("/tmp/a b", false) == "cd '/tmp/a b'\r",
		D.build_cd_line("/tmp/a b", false))
	check("build_cd_line windows: cd /d, double quotes, backslashes",
		D.build_cd_line("C:/github/My Proj", true) == "cd /d \"C:\\github\\My Proj\"\r",
		D.build_cd_line("C:/github/My Proj", true))
	check("is_windows_shell matches host OS",
		D.is_windows_shell() == (OS.get_name() == "Windows"))
	check("entry key format", D.entry_key_for_terminal("123") == "plugin:agent_relay:terminal-123")


# --- Acceptance 7 -----------------------------------------------------------
func _test_shell_environment() -> void:
	print("\n-- ShellEnvironment: PATH capture, lookup, output tail --")
	var SE = load(SHELL_ENV_PATH)
	var noisy: String = "Welcome to the box\n%s/usr/bin:/home/me/.nvm/bin%s\nnvm --> v24\n" \
		% [SE.PATH_MARK_BEGIN, SE.PATH_MARK_END]
	check("delimited capture survives rc noise on both sides",
		SE.parse_path_capture(noisy) == "/usr/bin:/home/me/.nvm/bin",
		SE.parse_path_capture(noisy))
	check("capture without markers is rejected", SE.parse_path_capture("/usr/bin:/bin\n") == "")
	check("empty captured value is rejected",
		SE.parse_path_capture(SE.PATH_MARK_BEGIN + SE.PATH_MARK_END) == "")
	check("value with no path separator is rejected",
		SE.parse_path_capture(SE.PATH_MARK_BEGIN + "garbage" + SE.PATH_MARK_END) == "")
	check("multi-line value is rejected",
		SE.parse_path_capture(SE.PATH_MARK_BEGIN + "/a\n/b" + SE.PATH_MARK_END) == "")
	check("effective_path is never empty", not SE.effective_path().is_empty())

	check("command_word takes the program word", SE.command_word("  codex --yolo ") == "codex")
	check("command_word of an empty line is empty", SE.command_word("   ") == "")
	# The word PATH is asked about is the PROGRAM, so an operator that is not
	# separated by a space, a leading assignment, an IO number or a redirect
	# must not end up glued to it — "codex|tee" is not a file anyone installs.
	check("command_word stops at an unspaced pipe",
		SE.command_word("codex|tee log") == "codex", SE.command_word("codex|tee log"))
	check("command_word stops at an unspaced redirect",
		SE.command_word("codex>log") == "codex", SE.command_word("codex>log"))
	check("command_word steps over a leading redirect",
		SE.command_word(">log codex") == "codex", SE.command_word(">log codex"))
	check("command_word steps over a leading IO-numbered redirect",
		SE.command_word("2>log codex") == "codex", SE.command_word("2>log codex"))
	check("command_word steps over leading env assignments",
		SE.command_word("FOO=1 BAR=2 codex --x") == "codex",
		SE.command_word("FOO=1 BAR=2 codex --x"))
	check("command_word steps over an assignment whose value is quoted",
		SE.command_word("FOO='1' codex --x") == "codex",
		SE.command_word("FOO='1' codex --x"))
	# A quoted NAME is not an assignment, so the word itself IS the program —
	# and a quoted program word is one PATH may not answer for.
	check("command_word declines a quoted assignment name",
		SE.command_word("'FOO=1' codex") == "", SE.command_word("'FOO=1' codex"))
	check("command_word keeps a quoted operator inside the argument",
		SE.command_word("sh -c 'a; b'") == "sh", SE.command_word("sh -c 'a; b'"))
	# Lines PATH cannot answer for: the shell decides the word, or there is no
	# word to decide. The preflight skips these rather than inventing a miss.
	check("command_word declines a quoted program word",
		SE.command_word("'my agent' --x") == "", SE.command_word("'my agent' --x"))
	check("command_word declines an expanded program word",
		SE.command_word("$AGENT --x") == "", SE.command_word("$AGENT --x"))
	check("command_word declines a line opening with an operator",
		SE.command_word("| codex") == "", SE.command_word("| codex"))
	check("command_word declines a subshell",
		SE.command_word("(codex)") == "", SE.command_word("(codex)"))
	check("command_word declines an unterminated quote",
		SE.command_word("sh -c 'oops") == "", SE.command_word("sh -c 'oops"))

	# program_word is the same walk, but it ANSWERS for a quoted word: the
	# quoting hid the characters from the parser, not the program from the
	# lookup. Only an expansion stays unanswerable.
	check("program_word unquotes the program word",
		SE.program_word("'my agent' --x") == "my agent", SE.program_word("'my agent' --x"))
	check("program_word unquotes a partly quoted word",
		SE.program_word("\"cod\"ex --x") == "codex", SE.program_word("\"cod\"ex --x"))
	check("program_word steps over assignments like command_word",
		SE.program_word("FOO=1 'codex' --x") == "codex", SE.program_word("FOO=1 'codex' --x"))
	check("program_word declines an expanded program word",
		SE.program_word("$AGENT --x") == "", SE.program_word("$AGENT --x"))
	check("program_word declines a line opening with an operator",
		SE.program_word("| codex") == "", SE.program_word("| codex"))
	check("program_word declines an unterminated quote",
		SE.program_word("sh -c 'oops") == "", SE.program_word("sh -c 'oops"))
	check("expand_tilde expands a leading ~/ and leaves ~user alone",
		SE.expand_tilde("~/bin/x") == OS.get_environment("HOME").path_join("bin/x")
		and SE.expand_tilde("~root/bin/x") == "~root/bin/x",
		SE.expand_tilde("~/bin/x"))

	# A quoted or escaped parenthesis inside a substitution is not the closing
	# one; counting it as such truncated the word and left the line untokenisable.
	check("a substitution holding a quoted ) is consumed whole",
		SE.command_word("codex --arg $(printf ')')") == "codex",
		SE.command_word("codex --arg $(printf ')')"))
	check("a substitution holding a double-quoted ) is consumed whole",
		SE.command_word("codex --arg $(printf \")\")") == "codex",
		SE.command_word("codex --arg $(printf \")\")"))
	check("a substitution holding an escaped ) is consumed whole",
		SE.command_word("codex --arg $(printf \\))") == "codex",
		SE.command_word("codex --arg $(printf \\))"))

	# PATH lookup against real files, so the check is not a mock.
	var dir: String = OS.get_user_data_dir()
	var probe_name := "w3_path_probe.bin"
	var probe_path: String = dir.path_join(probe_name)
	_write_file(probe_path, "x")
	# A readable-but-not-executable file is NOT a command: accepting it buys a
	# terminal, a watch and then "permission denied".
	check("resolve_on_path refuses a non-executable file",
		SE.resolve_on_path(probe_name, "/w3/nope:" + dir) == "",
		SE.resolve_on_path(probe_name, "/w3/nope:" + dir))
	FileAccess.set_unix_permissions(probe_path, 0x1ED)  # 0755
	check("resolve_on_path finds an executable word on the given PATH",
		SE.resolve_on_path(probe_name, "/w3/nope:" + dir) == probe_path,
		SE.resolve_on_path(probe_name, "/w3/nope:" + dir))
	check("resolve_on_path misses when the word is absent",
		SE.resolve_on_path("w3_not_there.bin", dir) == "")
	check("resolve_on_path treats a path-ish word as a path",
		SE.resolve_on_path(probe_path, "/w3/nope") == probe_path)
	DirAccess.remove_absolute(probe_path)

	# The lookup happens in the directory the COMMAND will run in, not
	# Minerva's: a relative word, a relative PATH entry and an EMPTY PATH entry
	# (which every shell reads as ".") are all answered against the launch cwd.
	var cwd: String = dir.path_join("w3_launch_cwd")
	var bin_dir: String = cwd.path_join("bin")
	DirAccess.make_dir_recursive_absolute(bin_dir)
	var agent_path: String = bin_dir.path_join("w3_agent.bin")
	_write_file(agent_path, "x")
	FileAccess.set_unix_permissions(agent_path, 0x1ED)  # 0755
	check("relative PATH entry resolves against the launch cwd",
		SE.resolve_on_path("w3_agent.bin", "bin", cwd) == agent_path,
		SE.resolve_on_path("w3_agent.bin", "bin", cwd))
	check("relative word resolves against the launch cwd",
		SE.resolve_on_path("./bin/w3_agent.bin", "", cwd) == agent_path,
		SE.resolve_on_path("./bin/w3_agent.bin", "", cwd))
	check("an empty PATH entry means the launch cwd",
		SE.resolve_on_path("w3_agent.bin", "/w3/nope:", bin_dir) == agent_path,
		SE.resolve_on_path("w3_agent.bin", "/w3/nope:", bin_dir))
	check("without a launch cwd the relative entry is not Minerva's answer",
		SE.resolve_on_path("w3_agent.bin", "bin") == "",
		SE.resolve_on_path("w3_agent.bin", "bin"))
	DirAccess.remove_absolute(agent_path)
	DirAccess.remove_absolute(bin_dir)
	DirAccess.remove_absolute(cwd)

	check("path_summary shows the head and counts the rest",
		SE.path_summary("/a:/b:/c:/d:/e", 2) == "/a, /b, …(3 more)", SE.path_summary("/a:/b:/c:/d:/e", 2))
	check("last_output_lines keeps the last non-empty lines in order",
		SE.last_output_lines("boot\n\nbash: codex: command not found\n\n", 2)
			== "boot\nbash: codex: command not found",
		SE.last_output_lines("boot\n\nbash: codex: command not found\n\n", 2))
	check("last_output_lines on blank text is empty", SE.last_output_lines("\n\n  \n") == "")


## Write `text` to an absolute path (no exec bit).
func _write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


## Write an executable /bin/sh script and return its path.
func _write_script(path: String, body: String) -> String:
	_write_file(path, body)
	FileAccess.set_unix_permissions(path, 0x1ED)  # 0755
	return path


func _count_lines(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var n := 0
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not String(line).strip_edges().is_empty():
			n += 1
	return n


# --- Acceptance 7b ----------------------------------------------------------
## The central behaviour, driven end to end against a REAL shell process: the
## probe is $SHELL, so pointing $SHELL at a script of our own makes the whole
## apply_login_path path observable — what it accepts, what it refuses, and
## how often it runs.
func _test_login_path_probe() -> void:
	print("\n-- login-PATH probe: applied once, refused on timeout --")
	if OS.get_name() == "Windows":
		print("(skipped: POSIX probe only)")
		return
	var SE = load(SHELL_ENV_PATH)
	var dir: String = OS.get_user_data_dir().path_join("w3_shellenv")
	DirAccess.make_dir_recursive_absolute(dir)
	var count_file: String = dir.path_join("probe_calls.txt")
	DirAccess.remove_absolute(count_file)
	var fake_path := "/w3/fake/bin:/usr/bin"
	# The probe invokes "$SHELL -ilc <script>", so a fake shell can set the PATH
	# it wants to be believed and then run the real capture script ("$2") —
	# which is the only way to emit this invocation's nonce.
	var run_real: String = "PATH='" + fake_path + "'\nexport PATH\neval \"$2\"\n"
	# rc noise that forges a marker pair of its own BEFORE the real capture:
	# the fixed marker text is public, so only the nonce can tell them apart.
	var forged: String = "printf '%s%s%s\\n' '" + SE.PATH_MARK_BEGIN \
		+ "' '/w3/forged/bin' '" + SE.PATH_MARK_END + "'\n"
	var ok_shell: String = _write_script(dir.path_join("fake_shell_ok.sh"),
		"#!/bin/sh\nprintf 'x\\n' >> '" + count_file + "'\n" + forged + run_real)
	# The hung shell also leaves a background child behind, the way an rc file
	# that starts a daemon does, and records its pid for the group-kill oracle.
	var child_pid_file: String = dir.path_join("hang_child.pid")
	DirAccess.remove_absolute(child_pid_file)
	var hang_shell: String = _write_script(dir.path_join("fake_shell_hang.sh"),
		"#!/bin/sh\n" + run_real + "sleep 9 &\necho $! > '" + child_pid_file
		+ "'\nsleep 9\n")
	# A `pkill` that never returns, first on the PATH the timeout cleanup runs
	# under: a cleanup that shells out to a helper is only as bounded as the
	# helper, and this one is not bounded at all.
	var trap_bin: String = dir.path_join("trapbin")
	DirAccess.make_dir_recursive_absolute(trap_bin)
	_write_script(trap_bin.path_join("pkill"), "#!/bin/sh\nsleep 9\n")

	var original_shell: String = OS.get_environment("SHELL")
	var original_path: String = OS.get_environment("PATH")
	var original_timeout: int = SE.probe_timeout_ms

	# (a) recovery: the probed PATH lands on Minerva's own process.
	SE._probe_done = false
	SE._login_path = ""
	OS.set_environment("SHELL", ok_shell)
	var applied: bool = SE.apply_login_path()
	check("the probed login PATH is installed on Minerva's process",
		applied and OS.get_environment("PATH") == fake_path, OS.get_environment("PATH"))
	check("a forged marker pair printed by rc noise loses to the real capture",
		OS.get_environment("PATH") != "/w3/forged/bin", OS.get_environment("PATH"))
	# (c) once per process, however many callers ask.
	var again: bool = SE.apply_login_path()
	check("a second apply_login_path does not probe again",
		not again and _count_lines(count_file) == 1, str(_count_lines(count_file)))
	OS.set_environment("PATH", original_path)

	# (b) a shell that prints the markers and THEN wedges proves nothing: the
	# inherited PATH must survive it.
	SE._probe_done = false
	SE._login_path = ""
	SE.probe_timeout_ms = 400
	OS.set_environment("SHELL", hang_shell)
	# The hung shell still needs the real /bin/sleep, so the trap dir is
	# PREPENDED: whatever the cleanup looks up by name finds the trap first.
	OS.set_environment("PATH", trap_bin + ":" + original_path)
	var started := Time.get_ticks_msec()
	var applied_hung: bool = SE.apply_login_path()
	var elapsed := Time.get_ticks_msec() - started
	var path_after_hang: String = OS.get_environment("PATH")
	OS.set_environment("PATH", original_path)
	check("a shell that hangs after printing leaves PATH alone",
		not applied_hung and path_after_hang == trap_bin + ":" + original_path,
		path_after_hang)
	check("the timed-out probe still returns inside its bound", elapsed < 3000, str(elapsed))
	# The kill takes the probe's process group, so a child the rc files left
	# running goes with it. /proc is how the group is identified; without it
	# (non-Linux POSIX) only the shell itself is killed, by design.
	if DirAccess.dir_exists_absolute("/proc"):
		var child_pid: int = int(FileAccess.get_file_as_string(child_pid_file).strip_edges())
		# /proc/<pid>, not OS.is_process_running: the grandchild is not Godot's
		# own child, and waitpid on a stranger only raises ECHILD.
		var gone := false
		for _i in 25:
			gone = not DirAccess.dir_exists_absolute("/proc/%d" % child_pid)
			if gone:
				break
			OS.delay_msec(20)
		check("the timed-out probe kills the child its rc files left running",
			child_pid > 0 and gone, str(child_pid))
	else:
		print("(skipped: no /proc — the group kill cannot be identified here)")

	SE.probe_timeout_ms = original_timeout
	OS.set_environment("SHELL", original_shell)
	OS.set_environment("PATH", original_path)
	SE._login_path = ""
	SE._probe_done = true  # later tests must not re-probe the real shell
	DirAccess.remove_absolute(ok_shell)
	DirAccess.remove_absolute(hang_shell)
	DirAccess.remove_absolute(trap_bin.path_join("pkill"))
	DirAccess.remove_absolute(trap_bin)
	DirAccess.remove_absolute(count_file)
	DirAccess.remove_absolute(child_pid_file)
	DirAccess.remove_absolute(dir)


# --- Acceptance 8a ----------------------------------------------------------
func _test_path_guard(so) -> void:
	print("\n-- startup command must resolve on PATH before anything is created --")
	var D = load(DIALOG_PATH)
	var registry = so.get_terminal_session_registry()
	var dialog = _new_dialog()
	var watch_calls := [0]
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		watch_calls[0] += 1
		return {"ok": true}
	dialog.popup_launch()
	var sessions_before: int = registry.session_count()
	dialog._name_edit.text = "PATH Guard"
	dialog._command_edit.text = "w3-definitely-not-installed --yolo"
	await dialog._on_start_pressed()

	if D.is_windows_shell():
		# cmd resolves its own shims — the guard is deliberately inert there.
		check("windows: PATH guard is inert", D.path_check_error("w3-definitely-not-installed") == "")
	else:
		check("unresolvable command → error names the word and PATH",
			dialog.current_error().contains("w3-definitely-not-installed")
				and dialog.current_error().contains("not on PATH"),
			dialog.current_error())
		check("unresolvable command → no session created",
			registry.session_count() == sessions_before, str(registry.session_count()))
		check("unresolvable command → watch never called", watch_calls[0] == 0)
		check("unresolvable command → dialog stays open", dialog.visible)
		check("a resolvable command passes the guard", D.path_check_error("sh -c true") == "",
			D.path_check_error("sh -c true"))
		check("a bare shell (no command) passes the guard", D.path_check_error("") == "")
		# The guard only answers for a bare name on the PATH Minerva holds.
		# Every other shape resolves somewhere we cannot see, so it is the
		# shell's to report — refusing it here blocks a working launch.
		check("an assignment-set PATH is not judged against ours",
			D.path_check_error("PATH=/w3-nowhere w3-definitely-not-installed") == "",
			D.path_check_error("PATH=/w3-nowhere w3-definitely-not-installed"))
		check("a builtin in a list is not looked up as a file",
			D.path_check_error("cd /tmp && w3-definitely-not-installed") == "",
			D.path_check_error("cd /tmp && w3-definitely-not-installed"))
		# Explicit paths and quoted names are checked too. The PTY shell is
		# interactive, so a failed `exec` drops back to the prompt instead of
		# exiting: nothing downstream can ever diagnose these.
		check("a missing absolute path → error naming the path",
			D.path_check_error("/w3-nowhere/codex --yolo").contains("/w3-nowhere/codex"),
			D.path_check_error("/w3-nowhere/codex --yolo"))
		check("a real executable path passes the guard",
			D.path_check_error("/bin/sh -c true") == "",
			D.path_check_error("/bin/sh -c true"))
		check("a missing relative path → error naming the path",
			D.path_check_error("./w3-nowhere-codex").contains("./w3-nowhere-codex"),
			D.path_check_error("./w3-nowhere-codex"))
		check("a missing ~ path is expanded and refused",
			D.path_check_error("~/w3-nowhere/codex --x").contains("~/w3-nowhere/codex"),
			D.path_check_error("~/w3-nowhere/codex --x"))
		check("a quoted missing name → error naming the word",
			D.path_check_error("'w3-definitely-not-installed' --yolo").contains(
				"w3-definitely-not-installed"),
			D.path_check_error("'w3-definitely-not-installed' --yolo"))
		check("a quoted real name passes the guard",
			D.path_check_error("'sh' -c true") == "", D.path_check_error("'sh' -c true"))
		check("a ~ path still launches under exec",
			D.build_launch_line("~/w3-nowhere/codex --x", false) == "exec bash -c '~/w3-nowhere/codex --x'\r",
			D.build_launch_line("~/w3-nowhere/codex --x", false))
		check("a list still launches bare",
			D.build_launch_line("cd /tmp && codex", false) == "exec bash -c 'cd /tmp && codex'\r",
			D.build_launch_line("cd /tmp && codex", false))
		check("a builtin that takes a command is not looked up as a file",
			D.path_check_error("exec w3-definitely-not-installed --yolo") == ""
			and D.path_check_error("command w3-definitely-not-installed --yolo") == "",
			D.path_check_error("exec w3-definitely-not-installed --yolo"))
		check("an expanded program word skips the guard",
			D.path_check_error("$AGENT --x") == "", D.path_check_error("$AGENT --x"))
		check("a line that names its own shell word is not double-wrapped",
			D.build_launch_line("exec codex --yolo", false) == "exec bash -c 'exec codex --yolo'\r"
			and D.build_launch_line("command codex", false) == "exec bash -c 'command codex'\r",
			D.build_launch_line("exec codex --yolo", false))
		check("a quoted shell word is still the shell's own word",
			D.build_launch_line("'exec' codex", false) == "exec bash -c ''\\''exec'\\'' codex'\r",
			D.build_launch_line("'exec' codex", false))
		check("a substitution holding a quoted ) still launches under exec",
			D.is_simple_command("codex --arg $(printf ')')")
			and D.build_launch_line("codex --arg $(printf ')')", false)
				== "exec bash -c 'codex --arg $(printf '\\'')'\\'')'\r",
			D.build_launch_line("codex --arg $(printf ')')", false))
		check("a command substitution is part of its word, so the line still execs",
			D.is_simple_command("codex --cd $(pwd)")
			and D.build_launch_line("codex --cd $(pwd)", false) == "exec bash -c 'codex --cd $(pwd)'\r"
			and D.is_simple_command("codex --cd `pwd`")
			and not D.is_simple_command("codex --cd $(pwd"),
			D.build_launch_line("codex --cd $(pwd)", false))

	dialog.queue_free()
	await process_frame


# --- Acceptance 8b ----------------------------------------------------------
func _test_launch_exit_note(so) -> void:
	print("\n-- a harness that dies on startup reports the shell's last lines --")
	if load(DIALOG_PATH).is_windows_shell():
		print("(skipped: POSIX shell dialect only)")
		return
	var registry = so.get_terminal_session_registry()
	var cpr = load(PROVIDER_REGISTRY_PATH).new()
	so.plugin_chat_provider_registry = cpr
	var pane = _new_stub_pane()
	var dialog = _new_dialog()
	# Generous entry timeout on purpose: a dead shell must cut the wait short
	# instead of burning it down.
	dialog.entry_wait_timeout_sec = 6.0
	dialog.chat_starter = pane.launch_passthrough_chat
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		return {"ok": true}  # watch "succeeds"; the entry never appears
	dialog.popup_launch()
	var sessions_before: int = registry.session_count()

	dialog._name_edit.text = "Dying Harness"
	# A SIMPLE command (one word), so the launch line is the `exec` form and the
	# dying harness IS the PTY shell — its exit code is the terminal's. The
	# script is executable on purpose: the PATH guard tests the file an
	# absolute path names, and would refuse a plain one before anything ran.
	var dying: String = _write_script(
		OS.get_user_data_dir().path_join("w3_dying_harness.sh"),
		"#!/bin/sh\necho w3-dead-marker\nexit 7\n")
	dialog._command_edit.text = dying
	var started_at := Time.get_ticks_msec()
	await dialog._on_start_pressed()
	var elapsed := Time.get_ticks_msec() - started_at

	check("dead harness → error quotes the terminal's last lines",
		dialog.current_error().contains("w3-dead-marker"), dialog.current_error())
	check("dead harness → error names the exit code, not the provider entry",
		dialog.current_error().contains("code 7")
			and not dialog.current_error().contains("chat provider"),
		dialog.current_error())
	check("dead harness → the entry wait is cut short", elapsed < 5000, str(elapsed))
	check("dead harness → no chat created", pane.presented.is_empty())
	check("dead harness → session closed (no orphan)",
		registry.session_count() == sessions_before, str(registry.session_count()))
	check("dead harness → dialog stays open", dialog.visible)

	DirAccess.remove_absolute(dying)
	dialog.queue_free()
	pane.free()
	so.plugin_chat_provider_registry = null
	await process_frame


# --- Acceptance 2 -----------------------------------------------------------
func _test_validation(so) -> void:
	print("\n-- validation: inline errors, dialog stays open --")
	var registry = so.get_terminal_session_registry()
	var dialog = _new_dialog()
	var watch_calls := [0]
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		watch_calls[0] += 1
		return {"ok": true}
	dialog.popup_launch()
	var sessions_before: int = registry.session_count()

	# Empty name → blocked.
	dialog._name_edit.text = ""
	dialog._on_start_pressed()
	check("empty name → inline error", dialog.current_error() != "", dialog.current_error())
	check("empty name → watch never called", watch_calls[0] == 0)
	check("empty name → no session created", registry.session_count() == sessions_before)
	check("empty name → dialog still open", dialog.visible)

	# Nonexistent cwd → blocked.
	dialog._name_edit.text = "Validate Test"
	dialog._cwd_edit.text = "/definitely/not/a/dir/w3_launch_test"
	dialog._on_start_pressed()
	check("bad cwd → inline error mentions directory",
		dialog.current_error().to_lower().contains("directory"), dialog.current_error())
	check("bad cwd → no session created", registry.session_count() == sessions_before)

	# Bind-to-existing disables command/cwd fields.
	var session = registry.create_session("bind-target", 80, 24)
	check("probe session started", session != null and session.started)
	dialog._refresh_existing_dropdown()
	check("existing dropdown lists the live session", dialog._existing_dropdown.item_count == 2,
		str(dialog._existing_dropdown.item_count))
	dialog._existing_dropdown.select(1)
	dialog._on_existing_selected(1)
	check("bind-to-existing → command field disabled", not dialog._command_edit.editable)
	check("bind-to-existing → cwd field disabled", not dialog._cwd_edit.editable)
	check("bind-to-existing → browse button disabled", dialog._cwd_browse_button.disabled)
	dialog._existing_dropdown.select(0)
	dialog._on_existing_selected(0)
	check("back to new-session → command field re-enabled", dialog._command_edit.editable)
	check("back to new-session → browse button re-enabled", not dialog._cwd_browse_button.disabled)

	# Directory chooser: a pick only FILLS the cwd LineEdit (typed and picked
	# paths share one validation path). Drive the dialog's signal directly —
	# popping a real FileDialog headless proves nothing about the picker UI.
	dialog._on_cwd_browse_pressed()
	check("browse builds a directory-mode chooser",
		dialog._cwd_dialog != null
			and dialog._cwd_dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR
			and dialog._cwd_dialog.access == FileDialog.ACCESS_FILESYSTEM)
	if dialog._cwd_dialog != null:
		dialog._cwd_dialog.hide()
		dialog._cwd_dialog.dir_selected.emit("/tmp")
		check("dir pick fills the cwd field", dialog._cwd_edit.text == "/tmp",
			dialog._cwd_edit.text)

	registry.close_session(session.terminal_id)
	dialog.queue_free()
	await process_frame


# --- Acceptance 3 -----------------------------------------------------------
func _test_happy_path(so) -> void:
	print("\n-- launch happy path (stubbed watch registers the entry) --")
	var registry = so.get_terminal_session_registry()
	var cpr = load(PROVIDER_REGISTRY_PATH).new()
	so.plugin_chat_provider_registry = cpr

	var pane = _new_stub_pane()
	check("stub ChatPane compiles", pane != null)
	if pane == null:
		so.plugin_chat_provider_registry = null
		return

	var dialog = _new_dialog()
	dialog.entry_wait_timeout_sec = 3.0
	dialog.chat_starter = pane.launch_passthrough_chat
	var watch_calls: Array = []
	dialog.watch_starter = func(args: Dictionary) -> Dictionary:
		watch_calls.append(args)
		cpr.register_entry("agent_relay", {
			"entry_id": "terminal-%s" % str(args.get("terminal_id", "")),
			"display_name": "Agent on %s" % str(args.get("terminal_id", "")),
			"generate_tool": "minerva_agent_relay_send",
			"history_mode": "newest_only"})
		return {"ok": true}

	dialog.popup_launch()
	# A long-lived stand-in for an agent CLI: it keeps profile inference on
	# "claude", prints a marker, and stays alive so the launch is not racing
	# its own startup-failure detection.
	# The "&&" is inside sh's quoted argument, so this IS a simple command: it
	# reaches the PTY under `exec` and the harness owns the PTY's exit code,
	# which is what the launch failure paths read.
	var command := "sh -c 'echo claude-marker-w3 && sleep 30'"
	# A directory that exists on every platform ("/tmp" doesn't on Windows).
	var test_cwd: String = OS.get_user_data_dir()
	dialog._name_edit.text = "PT Launch Test"
	dialog._command_edit.text = command
	dialog._on_command_changed(command)
	dialog._cwd_edit.text = test_cwd
	await dialog._on_start_pressed()

	check("no launch error", dialog.current_error() == "", dialog.current_error())
	check("watch seam called once", watch_calls.size() == 1, str(watch_calls.size()))
	if watch_calls.is_empty():
		dialog.queue_free()
		pane.free()
		so.plugin_chat_provider_registry = null
		return
	var tid: String = str(watch_calls[0].get("terminal_id", ""))
	check("watch got a terminal id", not tid.is_empty())
	check("watch got the inferred profile", str(watch_calls[0].get("profile", "")) == "claude",
		str(watch_calls[0]))

	# Background session exists in the registry, named after the form.
	check("background session exists in registry", registry.has_session(tid))
	var session = registry.get_session(tid)
	check("session named from the form", session != null and session.session_name == "PT Launch Test",
		session.session_name if session != null else "<null>")

	# The PTY received the launch write (echoed by the shell) in the host
	# dialect. The cd line only appears on the fallback path — new extension
	# binaries take the cwd natively (start_directory_applied).
	var D = load(DIALOG_PATH)
	var windows: bool = D.is_windows_shell()
	var expected_launch: String = D.build_launch_line(command, windows).trim_suffix("\r")
	if not windows:
		check("the launch line execs the quoted-operator command",
			expected_launch.begins_with("exec bash -c 'sh -c "), expected_launch)
	var expected_cd: String = D.build_cd_line(test_cwd, windows).trim_suffix("\r")
	var native_cwd: bool = session != null and session.start_directory_applied
	var saw_writes: bool = await _wait_until(func() -> bool:
		if session == null:
			return false
		var txt: String = session.get_plain_text()
		if not txt.contains(expected_launch):
			return false
		return native_cwd or txt.contains(expected_cd))
	check("PTY received the launch write (+ cd fallback only when not native)", saw_writes,
		session.get_plain_text().left(400) if session != null else "<null>")
	if native_cwd:
		check("native cwd path skips the cd keystrokes",
			not session.get_plain_text().contains(expected_cd),
			session.get_plain_text().left(400))

	# Chat created with the full passthrough binding.
	check("exactly one chat created", pane.presented.size() == 1, str(pane.presented.size()))
	if pane.presented.size() == 1:
		var history = pane.presented[0]
		check("chat PassthroughMode", history.PassthroughMode == true)
		check("chat BoundTerminalId == session id", history.BoundTerminalId == tid,
			history.BoundTerminalId)
		check("chat PassthroughCommand stored", history.PassthroughCommand == command,
			history.PassthroughCommand)
		check("chat PassthroughCwd stored", history.PassthroughCwd == test_cwd, history.PassthroughCwd)
		check("chat PassthroughName from session name", history.PassthroughName == "PT Launch Test",
			history.PassthroughName)
	check("dialog closed on success", not dialog.visible)

	registry.close_session(tid)
	dialog.queue_free()
	pane.free()
	so.plugin_chat_provider_registry = null
	await process_frame


# --- Acceptance 4 -----------------------------------------------------------
func _test_watch_fail_paths(so) -> void:
	print("\n-- watch-fail + entry-timeout: error, session closed, no chat --")
	var registry = so.get_terminal_session_registry()
	var cpr = load(PROVIDER_REGISTRY_PATH).new()
	so.plugin_chat_provider_registry = cpr

	var pane = _new_stub_pane()
	var dialog = _new_dialog()
	dialog.entry_wait_timeout_sec = 0.3
	dialog.chat_starter = pane.launch_passthrough_chat
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		return {"ok": false, "error": "plugin not running"}
	dialog.popup_launch()
	var sessions_before: int = registry.session_count()

	dialog._name_edit.text = "Fail Test"
	dialog._command_edit.text = "sleep 30"  # long-lived: not a startup failure
	await dialog._on_start_pressed()
	check("watch fail → inline error names the watch/plugin",
		dialog.current_error().to_lower().contains("agent-relay"), dialog.current_error())
	check("watch fail → session closed (no orphan)", registry.session_count() == sessions_before,
		str(registry.session_count()))
	check("watch fail → no chat created", pane.presented.is_empty())
	check("watch fail → dialog still open", dialog.visible)

	# Entry-timeout path: watch claims success but never registers the entry.
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		return {"ok": true}
	await dialog._on_start_pressed()
	check("entry timeout → inline error", dialog.current_error() != "", dialog.current_error())
	check("entry timeout → session closed (no orphan)",
		registry.session_count() == sessions_before, str(registry.session_count()))
	check("entry timeout → no chat created", pane.presented.is_empty())
	check("entry timeout → dialog still open", dialog.visible)

	# isError-style seam result also counts as failure.
	dialog.watch_starter = func(_args: Dictionary) -> Dictionary:
		return {"isError": true, "content": [{"type": "text", "text": "{\"error\": \"boom\"}"}]}
	await dialog._on_start_pressed()
	check("isError envelope → inline error", dialog.current_error() != "", dialog.current_error())
	check("isError envelope → session closed", registry.session_count() == sessions_before)

	dialog.queue_free()
	pane.free()
	so.plugin_chat_provider_registry = null
	await process_frame


# --- Acceptance 5 -----------------------------------------------------------
func _test_shell_exit_message(so) -> void:
	print("\n-- shell_exited → one program message in the bound chat --")
	var registry = so.get_terminal_session_registry()
	var pane = _new_stub_pane()
	var CH = load(CHAT_HISTORY_PATH)
	var VB = load(VBOX_CHAT_PATH)

	var session = registry.create_session("exit-probe", 80, 24)
	check("exit-probe session started", session != null and session.started)
	if session == null or not session.started:
		pane.free()
		return
	var tid: String = str(session.terminal_id)

	var history = CH.new(null, "hist-w3-exit")
	history.PassthroughMode = true
	history.BoundTerminalId = tid
	var vb_parent := Control.new()
	vb_parent.name = "ExitTestParent"
	var vb = VB.new(vb_parent)
	vb.chat_history = history
	history.VBox = vb

	# Wire TWICE — de-dupe must still yield exactly one message per exit.
	pane._wire_passthrough_exit(history)
	pane._wire_passthrough_exit(history)

	session.write_input("echo w3-tail-$((40+2))\r")
	session.write_input("exit 3\r")
	var exited: bool = await _wait_until(func() -> bool: return session.shell_exit_code != null)
	check("shell exited", exited)
	await process_frame  # let queued signal lambdas run

	var exit_labels: Array[String] = []
	for child in vb.get_children():
		if child is Label and str(child.text).contains("terminal agent exited"):
			exit_labels.append(child.text)
	check("exactly one exit message", exit_labels.size() == 1, str(exit_labels))
	if exit_labels.size() == 1:
		check("message names the exit code + relaunch affordance",
			exit_labels[0].contains("(code 3)") and exit_labels[0].contains("⇅"),
			exit_labels[0])
		check("message carries the terminal's last lines",
			exit_labels[0].contains("w3-tail-42"), exit_labels[0])

	# Binding AFTER the exit (already-dead session) surfaces immediately, once.
	var history2 = CH.new(null, "hist-w3-exit2")
	history2.PassthroughMode = true
	history2.BoundTerminalId = tid
	var vb2 = VB.new(vb_parent)
	vb2.chat_history = history2
	history2.VBox = vb2
	pane._wire_passthrough_exit(history2)
	var late := 0
	for child in vb2.get_children():
		if child is Label and str(child.text).contains("terminal agent exited"):
			late += 1
	check("bind-after-exit surfaces the message immediately, once", late == 1, str(late))

	registry.close_session(tid)
	vb.free()
	vb2.free()
	vb_parent.free()
	pane.free()
	await process_frame


# --- Acceptance 6 -----------------------------------------------------------
func _test_service_history_roundtrip() -> void:
	print("\n-- ServiceHistory: PassthroughCommand/Cwd round-trip --")
	var CH = load(CHAT_HISTORY_PATH)
	var SH = load(SERVICE_HISTORY_PATH)

	var sh = CH.new(null, "hist-w3-rt")
	sh.PassthroughMode = true
	sh.BoundTerminalId = "term-9"
	sh.PassthroughCommand = "claude --dangerously-skip-permissions"
	sh.PassthroughCwd = "/home/me/proj"

	var serialized: Dictionary = sh.Serialize()
	check("Serialize writes PassthroughCommand",
		str(serialized.get("PassthroughCommand", "")) == "claude --dangerously-skip-permissions")
	check("Serialize writes PassthroughCwd", str(serialized.get("PassthroughCwd", "")) == "/home/me/proj")

	var json_data = JSON.parse_string(JSON.stringify(serialized))
	var restored = SH.Deserialize(json_data)
	check("round-trip preserves PassthroughCommand",
		restored.PassthroughCommand == "claude --dangerously-skip-permissions",
		restored.PassthroughCommand)
	check("round-trip preserves PassthroughCwd", restored.PassthroughCwd == "/home/me/proj",
		restored.PassthroughCwd)

	var fields: Array = SH.SERIALIZER_FIELDS
	for f in ["PassthroughCommand", "PassthroughCwd"]:
		check("SERIALIZER_FIELDS has %s" % f, fields.has(f))

	# Old saves (fields absent) → defaults empty.
	var old_dict: Dictionary = CH.new(null, "hist-w3-old").Serialize()
	old_dict.erase("PassthroughCommand")
	old_dict.erase("PassthroughCwd")
	var old_restored = SH.Deserialize(old_dict)
	check("old save: PassthroughCommand defaults empty", old_restored.PassthroughCommand == "")
	check("old save: PassthroughCwd defaults empty", old_restored.PassthroughCwd == "")
