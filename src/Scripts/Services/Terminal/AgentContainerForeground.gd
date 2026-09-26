extends RefCounted
## Sees through an agent-container launcher to the program in front inside
## the container. TerminalSession.get_foreground_process() passes every
## native answer through resolve(), so the notify path, the input arbiter's
## guards and terminal_list all judge the harness the person actually sees.
##
## A tab attached to an agent session (the shipped launcher agent.py,
## attach/up) has the launcher in front on the host; the container's
## processes are not its descendants. The host can still read them in /proc
## (same kernel, pids translated into the host's namespace), so no command
## runs inside the container.
##
## Identity comes only from the host, in two files agent.py writes under
## <state root>/sessions/NAME/, neither of which the dev container mounts: the
## binding (control/binding.json) must name this terminal and hold a live
## lease, and launcher.json must carry the same lease generation, the
## launcher's process group as the one in front, and a container init whose
## pid AND start time match /proc. Only then is the container's tmux
## pane read: init -> its one tmux server -> that server's one pane shell ->
## the shell's terminal foreground group. Anything else is either not a bound
## launcher (the native answer stands, so no harness) or unreadable ({}, so
## writers hold). Nothing is cached: every call re-reads the live state.

const PANE_SHELL := ["bash", "--rcfile", "/opt/minerva-agent/agent-bashrc", "-i"]
const LAUNCHER_INTERPRETERS := ["python", "python3"]
## A foreground leader is found by walking parents up to the pane shell; a
## harness sits one or two levels below it.
const MAX_PARENT_HOPS := 16

## Overridable roots, for tests only. An empty state_root follows agent.py's
## rule: $MINERVA_AGENT_STATE, else $XDG_STATE_HOME/minerva-agent, else
## ~/.local/state/minerva-agent.
static var proc_root: String = "/proc"
static var state_root: String = ""


## The foreground to report for `terminal_id` given the native answer `host`.
static func resolve(terminal_id: String, host: Dictionary) -> Dictionary:
	if not is_launcher(host):
		return host
	var bindings: Array = _live_bindings(terminal_id, int(host.get("pid", 0)))
	if bindings.is_empty():
		return host
	if bindings.size() > 1:
		return {}
	var binding: Dictionary = bindings[0]
	var pane: Dictionary = _pane_foreground(int(binding["container_pid"]), int(binding["container_start"]))
	if not pane.is_empty():
		pane["container"] = str(binding["name"])
		pane["container_generation"] = str(binding["generation"])
	return pane


## Whether the native foreground is shaped like the launcher: a Python
## interpreter running a script named agent.py. Only a prefilter — the binding
## decides; this keeps every other foreground off the file reads below.
static func is_launcher(host: Dictionary) -> bool:
	var argv: Array = Array(host.get("argv", []))
	if argv.size() < 2 or str(argv[1]).get_file() != "agent.py":
		return false
	var program: String = str(argv[0]).get_file().to_lower()
	return program in LAUNCHER_INTERPRETERS or program.begins_with("python3.")


static func _state_root() -> String:
	if not state_root.is_empty():
		return state_root
	if not OS.get_environment("MINERVA_AGENT_STATE").is_empty():
		return OS.get_environment("MINERVA_AGENT_STATE")
	var base: String = OS.get_environment("XDG_STATE_HOME")
	if base.is_empty():
		base = OS.get_environment("HOME").path_join(".local/state")
	return base.path_join("minerva-agent")


## Every binding that names this terminal, is unexpired and whose launcher
## group is the one in front. Each is {name, generation, container_pid,
## container_start}.
static func _live_bindings(terminal_id: String, foreground_pgid: int) -> Array:
	var found: Array = []
	if terminal_id.is_empty() or foreground_pgid <= 0:
		return found
	var sessions: String = _state_root().path_join("sessions")
	var now: float = Time.get_unix_time_from_system()
	for name in DirAccess.get_directories_at(sessions):
		var dir: String = sessions.path_join(name)
		var data: Dictionary = _json_file(dir.path_join("control/binding.json"))
		if str(data.get("terminal_id", "")) != terminal_id:
			continue
		var expires = data.get("expires_at", null)
		if not (expires is float or expires is int) or not is_finite(float(expires)) \
				or float(expires) <= now:
			continue
		var generation = data.get("generation", null)
		var launcher: Dictionary = _json_file(dir.path_join("launcher.json"))
		if not generation is String or generation.is_empty() \
				or not launcher.get("generation", null) is String \
				or str(launcher["generation"]) != generation:
			continue
		var pgid: int = _positive_int(launcher.get("launcher_pgid", null))
		var pid: int = _positive_int(launcher.get("container_pid", null))
		var start: int = _positive_int(launcher.get("container_start", null))
		if pgid != foreground_pgid or pid <= 0 or start <= 0:
			continue
		found.append({"name": String(name), "generation": str(generation),
			"container_pid": pid, "container_start": start})
	return found


## A JSON object file, or {} when missing or anything else.
static func _json_file(path: String) -> Dictionary:
	var text: String = FileAccess.get_file_as_string(path)
	var json := JSON.new()   # parse(), unlike parse_string(), logs nothing on bad input
	if text.is_empty() or json.parse(text) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


## A JSON number that is a whole, finite, positive value, else 0.
static func _positive_int(value) -> int:
	if value is int:
		return value if value > 0 else 0
	if value is float and is_finite(value) and value > 0.0 and value == floorf(value) \
			and value < 9.0e15:
		return int(value)
	return 0


## The foreground of the container's tmux pane, as the native query shapes
## it, or {} when the topology is not exactly the one the image builds.
static func _pane_foreground(init_pid: int, init_start: int) -> Dictionary:
	var init_stat: PackedStringArray = _stat_fields(init_pid)
	if init_stat.size() < 20 or String(init_stat[19]) != str(init_start):
		return {}
	var servers: Array[int] = []
	for child in _children(init_pid):
		var child_argv: PackedStringArray = _argv(child)
		if child_argv.size() > 0 and child_argv[0].get_file() == "tmux":
			servers.append(child)
	if servers.size() != 1:
		return {}
	# One pane only: a second window or split pane would leave which one the
	# person is looking at to guesswork.
	var panes: Array[int] = _children(servers[0])
	if panes.size() != 1 or Array(_argv(panes[0])) != PANE_SHELL:
		return {}
	var shell: int = panes[0]
	var shell_stat: PackedStringArray = _stat_fields(shell)
	if shell_stat.size() < 6 or not String(shell_stat[5]).is_valid_int():
		return {}
	var leader: int = int(shell_stat[5])     # tpgid: the tty's foreground group
	if leader <= 0 or not _descends_from(leader, shell):
		return {}
	var leader_stat: PackedStringArray = _stat_fields(leader)
	if leader_stat.size() < 3 or String(leader_stat[2]) != str(leader):
		return {}   # the group's leader is gone, or the group is not its own
	var argv: PackedStringArray = _argv(leader)
	var exe: String = ""
	var dir := DirAccess.open(proc_root)
	if dir != null:
		exe = dir.read_link(proc_root.path_join("%d/exe" % leader))
	var name: String = _read_text(proc_root.path_join("%d/comm" % leader)).strip_edges()
	if name.is_empty():
		return {}
	return {"pid": leader, "name": name, "argv": argv, "exe": exe, "exe_name": exe.get_file()}


## `pid` is `ancestor` or sits below it within MAX_PARENT_HOPS.
static func _descends_from(pid: int, ancestor: int) -> bool:
	var current: int = pid
	for _hop in range(MAX_PARENT_HOPS + 1):
		if current == ancestor:
			return true
		var stat: PackedStringArray = _stat_fields(current)
		if stat.size() < 2 or not String(stat[1]).is_valid_int():
			return false
		current = int(stat[1])
		if current <= 1:
			return false
	return false


## Direct children across every thread (tmux may run more than one).
static func _children(pid: int) -> Array[int]:
	var found: Array[int] = []
	var tasks: String = proc_root.path_join("%d/task" % pid)
	for tid in DirAccess.get_directories_at(tasks):
		for word in _read_text(tasks.path_join(tid).path_join("children")).split(" ", false):
			if word.is_valid_int() and not found.has(int(word)):
				found.append(int(word))
	return found


## /proc/PID/stat after the parenthesised comm: [state, ppid, pgrp, session,
## tty_nr, tpgid, ...]; index 19 is the start time. Empty when unreadable.
static func _stat_fields(pid: int) -> PackedStringArray:
	var stat: String = _read_text(proc_root.path_join("%d/stat" % pid))
	var close: int = stat.rfind(")")
	if close < 0:
		return PackedStringArray()
	return stat.substr(close + 1).strip_edges().split(" ", false)


static func _argv(pid: int) -> PackedStringArray:
	var raw: PackedByteArray = _read_bytes(proc_root.path_join("%d/cmdline" % pid))
	var argv := PackedStringArray()
	var start: int = 0
	for i in range(raw.size()):
		if raw[i] == 0:
			argv.append(raw.slice(start, i).get_string_from_utf8())
			start = i + 1
	if start < raw.size():
		argv.append(raw.slice(start).get_string_from_utf8())
	return argv


static func _read_text(path: String) -> String:
	return _read_bytes(path).get_string_from_utf8()


## /proc files report length 0, so they are read by buffer, not by length.
static func _read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var data: PackedByteArray = f.get_buffer(65536)
	f.close()
	return data
