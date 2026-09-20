extends RefCounted
## Shell-environment helpers shared by the terminal stack.
##
## WHY: every Minerva PTY runs an rc-less shell on purpose (the unix/windows
## terminal extension execs bash --norc --noprofile, zsh with a scratch
## ZDOTDIR, fish --no-config) so the host can inject the prompt markers the
## block detection and the agent-relay turn detection depend on. The child
## therefore inherits Minerva's OWN process environment — and when Minerva is
## started from a desktop entry that PATH is the bare systemd user PATH, with
## no nvm / pyenv / cargo shims. Agents installed there ("codex", "opencode")
## are simply not found.
##
## The fix is to resolve the PATH the user's INTERACTIVE LOGIN shell would
## have, once, outside any PTY, and copy it into Minerva's own environment so
## every terminal born afterwards inherits it. The probe shell runs the user's
## rc files; the PTY shell still does not.
##
## Everything here is static + side-effect free apart from apply_login_path().

## Unique delimiters around the captured value. Login shells print motd, nvm
## banners and direnv chatter on both sides of our own output, so the value is
## carved out between markers rather than trusted as the whole capture.
const PATH_MARK_BEGIN := "__MINERVA_PATH_BEGIN__"
const PATH_MARK_END := "__MINERVA_PATH_END__"

## Upper bound on the probe. A login+interactive shell with nvm takes a few
## hundred ms; anything past this is a hung rc file and is abandoned.
const PROBE_TIMEOUT_MS := 4000

## Poll granularity while waiting for the probe to exit.
const PROBE_POLL_MS := 20

## Resolved once per process. Empty string = not resolved (or failed).
static var _login_path: String = ""
static var _probe_done: bool = false


## Resolve-and-apply, idempotent: the first call runs the probe, later calls
## are free. Returns true when the process PATH was actually replaced.
## No-op on Windows, where cmd.exe resolves PATH itself and there is no login
## shell to ask.
static func apply_login_path() -> bool:
	if _probe_done:
		return false
	_probe_done = true
	if OS.get_name() == "Windows":
		return false
	var probed := probe_login_path()
	if probed.is_empty() or probed == OS.get_environment("PATH"):
		return false
	_login_path = probed
	OS.set_environment("PATH", probed)
	return true


## The PATH new terminals will see: the login PATH when the probe succeeded,
## otherwise the inherited one. Triggers the probe on first use.
static func effective_path() -> String:
	apply_login_path()
	return OS.get_environment("PATH")


## Run the user's login shell as interactive+login and capture $PATH from it.
## Returns "" on any failure — callers fall back to the inherited PATH.
static func probe_login_path() -> String:
	var shell := OS.get_environment("SHELL")
	if shell.is_empty():
		shell = "/bin/sh"
	var script := 'printf "%%s%%s%%s" %s "$PATH" %s' % [PATH_MARK_BEGIN, PATH_MARK_END]
	var args := PackedStringArray(["-ilc", script])
	return parse_path_capture(run_bounded(shell, args, PROBE_TIMEOUT_MS))


## Carve the PATH out of a noisy capture. Rejects anything that cannot be a
## PATH (no markers, empty, embedded newline, no absolute entry).
static func parse_path_capture(output: String) -> String:
	var begin := output.find(PATH_MARK_BEGIN)
	if begin < 0:
		return ""
	begin += PATH_MARK_BEGIN.length()
	var end := output.find(PATH_MARK_END, begin)
	if end < 0:
		return ""
	var value := output.substr(begin, end - begin)
	if value.is_empty() or value.contains("\n") or value.contains("\r"):
		return ""
	if not value.contains("/"):
		return ""
	return value


## Run a program, capture its stdout, and kill it if it outstays the timeout.
## OS.execute() has no timeout, and a wedged rc file would hang the caller
## forever; the non-blocking pipe + pid poll gives a hard bound.
static func run_bounded(program: String, args: PackedStringArray, timeout_ms: int) -> String:
	var proc: Dictionary = OS.execute_with_pipe(program, args, false)
	if proc.is_empty():
		return ""
	var pid: int = int(proc.get("pid", -1))
	var pipe: FileAccess = proc.get("stdio") as FileAccess
	var captured := ""
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if pipe != null:
			captured += pipe.get_as_text()
		if pid < 0 or not OS.is_process_running(pid):
			break
		OS.delay_msec(PROBE_POLL_MS)
	if pid >= 0 and OS.is_process_running(pid):
		OS.kill(pid)
	if pipe != null:
		captured += pipe.get_as_text()
		pipe.close()
	return captured


## The program word of a shell command line — what PATH lookup applies to.
## Returns "" when the line starts with something PATH cannot answer for
## (a variable assignment, a subshell, a redirect), so callers skip the check
## instead of reporting a false miss.
static func command_word(command: String) -> String:
	var line := command.strip_edges()
	if line.is_empty():
		return ""
	var word := line.split(" ", false)[0].split("\t", false)[0]
	if word.contains("=") or word.begins_with("(") or word.begins_with("\"") \
			or word.begins_with("'") or word.begins_with("$"):
		return ""
	return word


## Absolute path of `word` on `path_value`, or "" when it does not resolve.
## A word that already contains a separator is taken as a path, like a shell
## does. GDScript cannot read the executable bit, so existence is the test.
static func resolve_on_path(word: String, path_value: String) -> String:
	if word.is_empty():
		return ""
	if word.contains("/"):
		return word if FileAccess.file_exists(word) else ""
	for dir in path_value.split(":", false):
		var candidate: String = String(dir).path_join(word)
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


## First `count` PATH entries, for an error message that shows the user which
## PATH was searched without printing a 2 KB line.
static func path_summary(path_value: String, count: int = 4) -> String:
	var entries := path_value.split(":", false)
	var shown: Array[String] = []
	for i in mini(count, entries.size()):
		shown.append(String(entries[i]))
	var text := ", ".join(shown)
	if entries.size() > count:
		text += ", …(%d more)" % (entries.size() - count)
	return text


## Last `count` non-empty lines of terminal text — the shell's own diagnostic
## ("bash: line 1: codex: command not found") when a harness dies on start.
static func last_output_lines(text: String, count: int = 3) -> String:
	var kept: Array[String] = []
	var lines := text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	for i in range(lines.size() - 1, -1, -1):
		var line := String(lines[i]).strip_edges()
		if line.is_empty():
			continue
		kept.push_front(line)
		if kept.size() >= count:
			break
	return "\n".join(kept)
