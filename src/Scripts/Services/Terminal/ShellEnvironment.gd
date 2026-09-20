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

## Delimiters around the captured value. Login shells print motd, nvm banners
## and direnv chatter on both sides of our own output, so the value is carved
## out between markers rather than trusted as the whole capture.
##
## Each probe appends a fresh nonce to both marks: the fixed text alone is
## guessable, and rc output that prints a marker pair of its own before the
## real capture would otherwise be read as the answer — a wrong PATH installed
## on Minerva's process, silently. Only the pair carrying this invocation's
## nonce is accepted.
const PATH_MARK_BEGIN := "__MINERVA_PATH_BEGIN__"
const PATH_MARK_END := "__MINERVA_PATH_END__"

## Upper bound on the probe. A login+interactive shell with nvm takes a few
## hundred ms; anything past this is a hung rc file and is abandoned. A static
## var rather than a const so tests can shrink the wait.
static var probe_timeout_ms: int = 4000

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
	# The launch shell is pinned by absolute path before PATH changes hands:
	# `exec <shell> -c` must not depend on the login PATH listing it.
	launch_shell()
	var probed := probe_login_path()
	if probed.is_empty() or probed == OS.get_environment("PATH"):
		return false
	_login_path = probed
	OS.set_environment("PATH", probed)
	return true


## The absolute path of the shell that runs a launch line (`exec <shell> -c`).
## Resolved once from $SHELL, else `bash` on the PATH in force at that moment,
## else /bin/bash, so a login PATH that omits the shell's directory cannot
## break the launch.
static var _launch_shell: String = ""

static func launch_shell() -> String:
	if not _launch_shell.is_empty():
		return _launch_shell
	var from_env := OS.get_environment("SHELL")
	if from_env.begins_with("/") and _executable_at(from_env):
		_launch_shell = from_env
	else:
		var found := resolve_on_path("bash", OS.get_environment("PATH"), "")
		_launch_shell = found if not found.is_empty() else "/bin/bash"
	return _launch_shell


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
	var nonce := new_nonce()
	var script := 'printf "%%s%%s%%s" %s%s "$PATH" %s%s' \
		% [PATH_MARK_BEGIN, nonce, PATH_MARK_END, nonce]
	var args := PackedStringArray(["-ilc", script])
	var run := run_bounded(shell, args, probe_timeout_ms)
	# A shell that printed the markers and THEN wedged (an exit trap, a child
	# holding the pipe) has proven nothing about its PATH: the value may be
	# half-written, and the rc chain never finished. Timed out = no answer.
	if bool(run.get("timed_out", false)):
		return ""
	return parse_path_capture(String(run.get("output", "")), nonce)


## A fresh per-probe marker suffix. Hex, so it is a bare word in the printf
## the probe shell runs. Crypto is the source where it exists; randi covers a
## build without the module.
static func new_nonce() -> String:
	var crypto := Crypto.new()
	if crypto != null:
		return crypto.generate_random_bytes(8).hex_encode()
	return "%08x%08x" % [randi(), randi()]


## Carve the PATH out of a noisy capture, accepting only the marker pair that
## carries `nonce`. Rejects anything that cannot be a PATH (no markers, empty,
## embedded newline, no absolute entry).
static func parse_path_capture(output: String, nonce: String = "") -> String:
	var begin_mark := PATH_MARK_BEGIN + nonce
	var end_mark := PATH_MARK_END + nonce
	var begin := output.find(begin_mark)
	if begin < 0:
		return ""
	begin += begin_mark.length()
	var end := output.find(end_mark, begin)
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
##
## Returns {"output": String, "timed_out": bool}. The two are independent: a
## process that printed and then hung still has output, and the caller must be
## able to refuse it — which is why this is a result and not a bare String.
##
## The kill takes the child's whole process GROUP where one can be identified,
## because the rc files being probed spawn children of their own (direnv, a
## daemon from ~/.zshrc) that would otherwise outlive the probe and hold the
## capture pipe open. See kill_process_group / foreign_process_group.
static func run_bounded(program: String, args: PackedStringArray, timeout_ms: int) -> Dictionary:
	var proc: Dictionary = OS.execute_with_pipe(program, args, false)
	if proc.is_empty():
		return {"output": "", "timed_out": false}
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
	var timed_out: bool = pid >= 0 and OS.is_process_running(pid)
	if timed_out:
		kill_process_group(pid)
	if pipe != null:
		captured += pipe.get_as_text()
		pipe.close()
	return {"output": captured, "timed_out": timed_out}


## SIGKILL the timed-out process and every other member of its group, leader
## last so the group is still identifiable while the scan runs. Returns how
## many pids were signalled.
##
## The members are read out of /proc in-process rather than handed to pkill:
## a helper has to be found on the very PATH the probe exists to repair, and a
## synchronous OS.execute of a missing-or-wedged helper would hang the caller
## for longer than the whole timeout it is serving. Reading /proc costs one
## small file per live process and cannot block on anything.
static func kill_process_group(pid: int) -> int:
	var signalled := 0
	var pgid := foreign_process_group(pid)
	if pgid > 0:
		for member in pids_in_group(pgid):
			if member == pid:
				continue
			OS.kill(member)
			signalled += 1
	OS.kill(pid)
	return signalled + 1


## Every live pid whose process group is `pgid`, from /proc. Empty on hosts
## without /proc (non-Linux POSIX), where only the leader can be killed.
static func pids_in_group(pgid: int) -> Array[int]:
	var found: Array[int] = []
	if pgid <= 0:
		return found
	for name in DirAccess.get_directories_at("/proc"):
		var entry := String(name)
		if not entry.is_valid_int():
			continue
		var member := int(entry)
		if _proc_stat_pgrp(member) == pgid:
			found.append(member)
	return found


## The process group `pid` can be killed through, or 0 when there is none.
## Godot spawns a child into a session of its own, so the group is normally the
## child's pid — but that is an engine detail, so it is read back from /proc
## and refused whenever it is Minerva's own group: killing that group would
## kill Minerva. 0 (no /proc, a shared group) means "kill only the pid".
static func foreign_process_group(pid: int) -> int:
	var own := _proc_stat_pgrp(OS.get_process_id())
	var theirs := _proc_stat_pgrp(pid)
	if own <= 0 or theirs <= 0 or theirs == own:
		return 0
	return theirs


## /proc files report length 0, so FileAccess.get_file_as_string reads nothing
## from them — they have to be opened and read line-wise.
static func _read_proc(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var line := f.get_line()
	f.close()
	return line.strip_edges()


static func _proc_stat_pgrp(pid: int) -> int:
	var stat := _read_proc("/proc/%d/stat" % pid)
	var tail := stat.substr(stat.rfind(")") + 1).strip_edges()
	var fields := tail.split(" ", false)
	# after comm: state, ppid, pgrp → index 2
	if fields.size() < 3 or not String(fields[2]).is_valid_int():
		return 0
	return int(fields[2])


## Characters that start a shell operator when they are not inside quotes.
const _OP_CHARS := "|;&()<>"

## Redirect operators — the only ones that may precede the program word.
const _REDIRECT_OPS: Array[String] = ["<", ">", ">>", "<<"]


## Split a command line the way a shell reads it, so callers judge operators by
## POSITION rather than by substring search: quotes hide operators, a backslash
## escapes the next character, and an unquoted operator character breaks a word.
##
## Returns {"ok": bool, "tokens": Array[Dictionary]}. Each token carries
##   text        – the operator, or the word with one level of quoting removed
##   op          – true for an operator token
##   quoted      – some part of the word came out of quotes or an escape
##   name_quoted – the quoting reached the word's NAME half, i.e. the text in
##                 front of its first `=`; see _mark_quoted
##   expands     – the word holds an unquoted `$` or backtick, so its final
##                 value is the shell's to decide and not ours
## ok is false for an unterminated quote or a trailing backslash: nothing can be
## concluded from half a line, and the shell reports those itself.
static func tokenize(command: String) -> Dictionary:
	var line := command.strip_edges()
	var tokens: Array[Dictionary] = []
	var cur := {"text": "", "started": false, "quoted": false,
		"name_quoted": false, "expands": false}
	var i := 0
	while i < line.length():
		var c := line[i]
		if c == "\\":
			if i + 1 >= line.length():
				return {"ok": false, "tokens": tokens}
			_mark_quoted(cur)
			cur["text"] = String(cur["text"]) + line[i + 1]
			cur["started"] = true
			i += 2
		elif c == "'":
			var close := line.find("'", i + 1)
			if close < 0:
				return {"ok": false, "tokens": tokens}
			_mark_quoted(cur)
			cur["text"] = String(cur["text"]) + line.substr(i + 1, close - i - 1)
			cur["started"] = true
			i = close + 1
		elif c == "\"":
			_mark_quoted(cur)
			i += 1
			var closed := false
			while i < line.length():
				var d := line[i]
				if d == "\\" and i + 1 < line.length():
					# Inside double quotes a backslash escapes only $ ` " \
					# and newline; before any other character it is literal.
					var e := line[i + 1]
					if e == "$" or e == "`" or e == "\"" or e == "\\" or e == "\n":
						cur["text"] = String(cur["text"]) + (e if e != "\n" else "")
					else:
						cur["text"] = String(cur["text"]) + d + e
					i += 2
					continue
				if d == "\"":
					closed = true
					i += 1
					break
				if d == "$" or d == "`":
					cur["expands"] = true
				cur["text"] = String(cur["text"]) + d
				i += 1
			if not closed:
				return {"ok": false, "tokens": tokens}
			cur["started"] = true
		elif c == " " or c == "\t":
			_flush_word(tokens, cur)
			i += 1
		elif _OP_CHARS.contains(c) or c == "\n" or c == "\r":
			_flush_word(tokens, cur)
			var op := c
			if i + 1 < line.length() and line[i + 1] == c and "|&;<>".contains(c):
				op += c  # || && ;; << >>
			tokens.append({"text": op, "op": true, "quoted": false, "expands": false})
			i += op.length()
		elif c == "$" and i + 1 < line.length() and line[i + 1] == "(":
			# A command substitution belongs to the word: its parentheses are
			# not list operators. Nested `$( )` is consumed to the matching close.
			var j := _scan_substitution(line, i + 1)
			if j < 0:
				return {"ok": false, "tokens": []}
			cur["text"] = String(cur["text"]) + line.substr(i, j - i + 1)
			cur["expands"] = true
			cur["started"] = true
			i = j + 1
		elif c == "`":
			var close := line.find("`", i + 1)
			if close < 0:
				return {"ok": false, "tokens": []}
			cur["text"] = String(cur["text"]) + line.substr(i, close - i + 1)
			cur["expands"] = true
			cur["started"] = true
			i = close + 1
		else:
			# Variables, globs and braces are the shell's to expand; a word
			# holding one has no literal name a lookup could judge.
			if c == "$" or c == "*" or c == "?" or c == "[" or c == "{":
				cur["expands"] = true
			cur["text"] = String(cur["text"]) + c
			cur["started"] = true
			i += 1
	_flush_word(tokens, cur)
	return {"ok": true, "tokens": tokens}


## Index of the `)` that closes the command substitution whose `(` sits at
## `open_index`, or -1 when the line ends first. Quotes and backslash escapes
## hide parentheses from the depth count exactly as they do from the shell, so
## `$(printf ')')` is consumed whole instead of ending on its quoted `)`.
static func _scan_substitution(line: String, open_index: int) -> int:
	var depth := 0
	var i := open_index
	while i < line.length():
		var c := line[i]
		if c == "\\":
			i += 2
		elif c == "'":
			var close := line.find("'", i + 1)
			if close < 0:
				return -1
			i = close + 1
		elif c == "\"":
			i = _skip_double_quoted(line, i + 1)
			if i < 0:
				return -1
		else:
			if c == "(":
				depth += 1
			elif c == ")":
				depth -= 1
				if depth == 0:
					return i
			i += 1
	return -1


## Index just past the `"` that closes the double-quoted run starting at
## `start`, or -1 when it is unterminated. A backslash escapes the next char.
static func _skip_double_quoted(line: String, start: int) -> int:
	var i := start
	while i < line.length():
		if line[i] == "\\":
			i += 2
			continue
		if line[i] == "\"":
			return i + 1
		i += 1
	return -1


## Record a quoted stretch on the word being built. It counts against the NAME
## half only while the text so far holds no `=`: quoting in front of the `=`
## (or over the `=` itself) is what stops a shell reading the word as an
## assignment, while quoting the VALUE — `FOO='1'` — leaves it one.
static func _mark_quoted(cur: Dictionary) -> void:
	cur["quoted"] = true
	if not String(cur["text"]).contains("="):
		cur["name_quoted"] = true


## Append the word being built (if any) and reset the builder.
static func _flush_word(tokens: Array[Dictionary], cur: Dictionary) -> void:
	if not bool(cur["started"]):
		return
	tokens.append({"text": String(cur["text"]), "op": false,
		"quoted": bool(cur["quoted"]), "name_quoted": bool(cur["name_quoted"]),
		"expands": bool(cur["expands"])})
	cur["text"] = ""
	cur["started"] = false
	cur["quoted"] = false
	cur["name_quoted"] = false
	cur["expands"] = false


## True when `token` is a leading `NAME=value` environment assignment: an
## unquoted identifier, then `=`. Quoting the NAME defeats it, exactly as it
## does in a shell; quoting the VALUE (`FOO='1'`) does not — that word is still
## an assignment, and judging it a program name makes `exec` hunt for a file
## called "FOO=1".
static func is_assignment_token(token: Dictionary) -> bool:
	if bool(token.get("op", false)) or bool(token.get("name_quoted", false)):
		return false
	var text := String(token.get("text", ""))
	var eq := text.find("=")
	if eq <= 0:
		return false
	for i in eq:
		var c := text[i]
		var alpha: bool = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
		var digit: bool = i > 0 and c >= "0" and c <= "9"
		if not (alpha or digit):
			return false
	return true


## The program word of a shell command line — what PATH lookup applies to.
## Leading environment assignments, IO numbers and redirects are stepped over;
## the answer is the first plain word after them. Returns "" when PATH cannot
## answer for the line at all (it cannot be tokenised, it opens with a
## non-redirect operator, or the program word is quoted or `$`-expanded), so
## callers skip the check instead of reporting a false miss.
static func command_word(command: String) -> String:
	var token := program_token(command)
	if token.is_empty() or bool(token["quoted"]) or bool(token["expands"]):
		return ""
	return String(token["text"])


## The program word with one level of quoting removed — `'codex'` answers
## "codex", where command_word declines it. This is the word the shell will
## actually look for, so it is what a launch preflight must judge; only an
## EXPANDED word ("$AGENT") stays unanswerable, because its value is the
## shell's to decide. Returns "" when there is no program word at all.
static func program_word(command: String) -> String:
	var token := program_token(command)
	if token.is_empty() or bool(token["expands"]):
		return ""
	return String(token["text"])


## The token carrying the program name, or {} when the line has none. Leading
## environment assignments, IO numbers and redirects are stepped over; a line
## that cannot be tokenised or that opens with a non-redirect operator has no
## program word.
static func program_token(command: String) -> Dictionary:
	var parsed := tokenize(command)
	if not bool(parsed.get("ok", false)):
		return {}
	var tokens: Array = parsed.get("tokens", [])
	var i := 0
	while i < tokens.size():
		var token: Dictionary = tokens[i]
		if bool(token["op"]):
			# A redirect and its target sit in front of the program word; any
			# other operator means the line does not start with a command.
			if String(token["text"]) in _REDIRECT_OPS and i + 1 < tokens.size() \
					and not bool(tokens[i + 1]["op"]):
				i += 2
				continue
			return {}
		if is_assignment_token(token):
			i += 1
			continue
		# "2" in `2>log codex` is the redirect's IO number, not a program.
		if String(token["text"]).is_valid_int() and i + 1 < tokens.size() \
				and bool(tokens[i + 1]["op"]) and String(tokens[i + 1]["text"]) in _REDIRECT_OPS:
			i += 1
			continue
		return token
	return {}


## Path of `word` on `path_value` as the shell would find it, or "" when it
## does not resolve. A word that already contains a separator is taken as a
## path, like a shell does.
##
## `cwd` is the directory the COMMAND will run in (the launch dialog's working
## directory), not Minerva's: "./codex" and a relative PATH entry mean
## different files in the two, and judging them in Minerva's directory answers
## the wrong question. An empty `cwd` leaves relative paths to resolve against
## Minerva's own working directory, which is where a terminal without a start
## directory lands anyway.
static func resolve_on_path(word: String, path_value: String, cwd: String = "") -> String:
	if word.is_empty():
		return ""
	if word.contains("/"):
		return _executable_at(_absolutize(word, cwd))
	# allow_empty: an empty PATH entry ("", as in "/usr/bin::/bin" or a
	# trailing colon) means the current directory to every POSIX shell.
	for entry in path_value.split(":", true):
		var dir: String = String(entry)
		if dir.is_empty():
			dir = "."
		var hit := _executable_at(_absolutize(dir, cwd).path_join(word))
		if not hit.is_empty():
			return hit
	return ""


## Path of a word the shell will treat as a FILE — it holds a separator or
## opens with `~` — or "" when nothing executable is there. The tilde is
## expanded here because the shell expands it before the lookup, so reading the
## word literally would miss the file that is actually going to run.
static func resolve_path_word(word: String, cwd: String = "") -> String:
	return _executable_at(_absolutize(expand_tilde(word), cwd))


## A leading `~` or `~/` replaced with $HOME, as the shell expands it. Other
## forms (`~user`) name a passwd entry we do not read, and are left alone.
static func expand_tilde(word: String) -> String:
	if word != "~" and not word.begins_with("~/"):
		return word
	var home := OS.get_environment("HOME")
	if home.is_empty():
		return word
	return home if word == "~" else home.path_join(word.substr(2))


## `path` made absolute against `cwd` when both are relative/present, else as
## given (an empty cwd means "leave it to the process working directory").
static func _absolutize(path: String, cwd: String) -> String:
	if path.begins_with("/") or cwd.is_empty():
		return path
	return cwd.path_join(path).simplify_path()


## `path` when it is a regular file with an execute bit, else "". Existence is
## not enough: a readable-but-not-executable file passes file_exists and then
## dies as "permission denied" AFTER a session and a watch were created. The
## bit is checked for any of user/group/other rather than resolving the
## effective uid — the same approximation `which` makes.
## Windows has no unix bits (cmd decides via PATHEXT), so the check is inert
## there and existence stands.
static func _executable_at(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	if OS.get_name() == "Windows":
		return path
	var bits: int = FileAccess.get_unix_permissions(path)
	if bits <= 0:
		return ""
	# 0x49 = 0111: the three execute bits.
	return path if (bits & 0x49) != 0 else ""


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
