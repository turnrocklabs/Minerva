extends SceneTree
## Headless test of seeing through an agent-container launcher to the harness
## in front inside the container (AgentContainerForeground).
##
## Run: godot --headless --path src --script test/test_agent_container_foreground.gd
##
## Needs no autoloads: it builds TerminalSession directly. The container side
## is a fake /proc tree and a fake agent.py state root on disk; the host side
## of the integration oracle is real — a forkpty'd shell running a script
## named agent.py that hex-dumps every byte it reads.
##
## ORACLES
##   - a bound launcher with Claude in the pane reports Claude, with the
##     container named; with the pane shell in front it reports the shell (so
##     no harness), and every broken link in the chain falls back to the
##     native answer (not a launcher, stale lease, other terminal, other
##     launcher group, cleared binding, stale generation, missing or malformed
##     launcher file) or to {} (init start time, tmux servers, panes, pane
##     shell argv, foreground leader missing or outside the pane, two live
##     bindings); tmux children spread over threads are all read;
##   - end to end: through the real session and its input arbiter, a write
##     expecting claude lands while Claude is in the container's pane and is
##     refused, with no byte written, once the pane shell is back in front;
##     after the lease lapses the tab reads as the bare launcher again.

const SESSION_PATH := "res://Scripts/Services/Terminal/TerminalSession.gd"
const FG_PATH := "res://Scripts/Services/Terminal/AgentContainerForeground.gd"
const TERMINAL := "4242"
const PGID := 777
const INIT := 1000
const TMUX := 1001
const SUPERVISOR := 1002
const SHELL := 1003
const CLAUDE := 1004
const START := 5555
const PANE_ARGV := ["bash", "--rcfile", "/opt/minerva-agent/agent-bashrc", "-i"]
const CLAUDE_EXE := "/agent-home/tools/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
const LAUNCHER_SRC := """import os, sys, tty
tty.setraw(0)
sys.stdout.write("LAUNCHERREADY\\r\\n")
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
var _fg = null
var _root: String = ""
var _proc: String = ""
var _state: String = ""


func _init() -> void:
	print("=== agent container foreground ===\n")
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


func _run() -> void:
	await process_frame
	_fg = load(FG_PATH)
	_root = ProjectSettings.globalize_path("user://agent_container_fg_%d" % OS.get_process_id())
	_test_resolution()
	await _test_end_to_end()


# ── fixtures ───────────────────────────────────────────────────────────

## A fresh fake /proc and state root, with the healthy container topology and
## a live binding for TERMINAL held by launcher group PGID.
func _reset(tpgid: int = CLAUDE) -> void:
	_proc = _root.path_join("proc-%d" % Time.get_ticks_usec())
	_state = _root.path_join("state-%d" % Time.get_ticks_usec())
	_fg.proc_root = _proc
	_fg.state_root = _state
	_fake_process(INIT, "tini", 0, INIT, -1, START, ["/sbin/docker-init", "--"], [TMUX, SUPERVISOR])
	_fake_process(TMUX, "tmux: server", INIT, TMUX, -1, 1, ["tmux", "-f", "/opt/minerva-agent/tmux.conf",
		"new-session", "-d", "-s", "harness"], [SHELL])
	_fake_process(SUPERVISOR, "bash", INIT, SUPERVISOR, -1, 1,
		["bash", "/opt/minerva-agent/minerva-session", "claude", "resume"], [])
	_fake_process(SHELL, "bash", TMUX, SHELL, tpgid, 1, PANE_ARGV, [CLAUDE], "/usr/bin/bash")
	_fake_process(CLAUDE, "claude", SHELL, CLAUDE, tpgid, 1, ["claude", "--resume"], [], CLAUDE_EXE)
	_bind("proto1", TERMINAL, Time.get_unix_time_from_system() + 60.0, "gen1")
	_launcher("proto1", {"generation": "gen1", "launcher_pgid": PGID,
		"container_pid": INIT, "container_start": START})


func _fake_process(pid: int, comm: String, ppid: int, pgrp: int, tpgid: int, start: int,
		argv: Array, children: Array, exe: String = "") -> void:
	var dir: String = _proc.path_join(str(pid))
	DirAccess.make_dir_recursive_absolute(dir.path_join("task/%d" % pid))
	_set_stat(pid, comm, ppid, pgrp, tpgid, start)
	var cmdline := PackedByteArray()
	for arg in argv:
		cmdline.append_array(str(arg).to_utf8_buffer())
		cmdline.append(0)
	_write_bytes(dir.path_join("cmdline"), cmdline)
	_write(dir.path_join("comm"), comm + "\n")
	_write(dir.path_join("task/%d/children" % pid), " ".join(children.map(func(c): return str(c))) + " ")
	if not exe.is_empty():
		DirAccess.open(dir).create_link(exe, dir.path_join("exe"))


## Fields after comm: state ppid pgrp session tty tpgid, 13 fillers, start.
func _set_stat(pid: int, comm: String, ppid: int, pgrp: int, tpgid: int, start: int) -> void:
	var fields: Array = ["S", ppid, pgrp, pgrp, 34816, tpgid]
	for _i in range(13):
		fields.append(0)
	fields.append(start)
	_write(_proc.path_join("%d/stat" % pid), "%d (%s) %s\n" % [pid, comm, " ".join(fields.map(func(f): return str(f)))])


func _bind(name: String, terminal: String, expires, generation: String) -> void:
	var data: Dictionary = {"terminal_id": terminal, "notify_targets": [],
		"generation": generation, "expires_at": expires}
	_write(_state.path_join("sessions/%s/control/binding.json" % name), JSON.stringify(data))


func _launcher(name: String, data) -> void:
	var text: String = data if data is String else JSON.stringify(data)
	_write(_state.path_join("sessions/%s/launcher.json" % name), text)


func _write(path: String, text: String) -> void:
	_write_bytes(path, text.to_utf8_buffer())


func _write_bytes(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


func _host(pid: int = PGID) -> Dictionary:
	return {"pid": pid, "name": "python3", "argv": ["python3", "/x/scripts/agent-container/agent.py",
		"attach", "proto1"], "exe": "/usr/bin/python3.12", "exe_name": "python3.12"}


func _harness(process: Dictionary) -> String:
	return load(SESSION_PATH).harness_of(process)


# ── resolution against a fake /proc ────────────────────────────────────

func _test_resolution() -> void:
	_reset()
	var seen: Dictionary = _fg.resolve(TERMINAL, _host())
	check("bound launcher with Claude in the pane reports Claude",
		_harness(seen) == "claude" and int(seen.get("pid", 0)) == CLAUDE
			and str(seen.get("exe_name", "")) == "claude.exe", str(seen))
	check("and names the container session", str(seen.get("container", "")) == "proto1", str(seen))
	check("and its attachment's generation", str(seen.get("container_generation", "")) == "gen1", str(seen))

	_reset(SHELL)
	seen = _fg.resolve(TERMINAL, _host())
	check("with the pane shell in front it reports the shell, so no harness",
		int(seen.get("pid", 0)) == SHELL and _harness(seen) == "", str(seen))

	# Every failed identity link leaves the native answer standing.
	var native: Dictionary = {"pid": 55, "name": "claude", "argv": ["claude"], "exe": "", "exe_name": ""}
	_reset()
	check("a foreground that is not a launcher is returned untouched",
		_fg.resolve(TERMINAL, native) == native)
	check("a python foreground running another script is untouched",
		_fg.resolve(TERMINAL, {"pid": PGID, "argv": ["python3", "/x/other.py"]})
			== {"pid": PGID, "argv": ["python3", "/x/other.py"]})
	for label in FALLBACKS:
		_reset()
		_break_identity(label)
		var host: Dictionary = _host()
		check("%s: the native answer stands" % label, _fg.resolve(TERMINAL, host) == host,
			str(_fg.resolve(TERMINAL, host)))

	# A bound launcher whose container cannot be read exactly is unreadable.
	for label in UNREADABLE:
		_reset()
		_break_topology(label)
		var answer: Dictionary = _fg.resolve(TERMINAL, _host())
		check("%s: unreadable, so writers hold" % label, answer.is_empty(), str(answer))

	# Threads: the one pane may be listed by any tmux thread.
	_reset()
	_write(_proc.path_join("%d/task/%d/children" % [TMUX, TMUX]), "")
	_write(_proc.path_join("%d/task/1009/children" % TMUX), "%d " % SHELL)
	check("a pane listed by a second tmux thread is still found",
		_harness(_fg.resolve(TERMINAL, _host())) == "claude")


const FALLBACKS := ["stale lease", "lease that is not a number", "binding for another terminal",
	"cleared binding", "malformed binding", "stale generation (taken over)", "missing launcher file",
	"malformed launcher file", "launcher group that is not in front", "fractional container pid",
	"container pid as a string", "zero start time (launcher could not read it)"]


func _break_identity(label: String) -> void:
	var live: float = Time.get_unix_time_from_system() + 60.0
	var binding: String = _state.path_join("sessions/proto1/control/binding.json")
	var fields: Dictionary = {"generation": "gen1", "launcher_pgid": PGID,
		"container_pid": INIT, "container_start": START}
	match label:
		"stale lease":
			_bind("proto1", TERMINAL, Time.get_unix_time_from_system() - 1.0, "gen1")
		"lease that is not a number":
			_bind("proto1", TERMINAL, true, "gen1")
		"binding for another terminal":
			_bind("proto1", "9999", live, "gen1")
		"cleared binding":
			_write(binding, "{}")
		"malformed binding":
			_write(binding, "{not json")
		"stale generation (taken over)":
			_bind("proto1", TERMINAL, live, "gen2")
		"missing launcher file":
			DirAccess.remove_absolute(_state.path_join("sessions/proto1/launcher.json"))
		"malformed launcher file":
			_launcher("proto1", "[1,2")
		"launcher group that is not in front":
			fields["launcher_pgid"] = PGID + 1
			_launcher("proto1", fields)
		"fractional container pid":
			fields["container_pid"] = 1000.5
			_launcher("proto1", fields)
		"container pid as a string":
			fields["container_pid"] = "1000"
			_launcher("proto1", fields)
		"zero start time (launcher could not read it)":
			fields["container_start"] = 0
			_launcher("proto1", fields)


const UNREADABLE := ["container init restarted (start time differs)", "second tmux pane",
	"second pane listed by another tmux thread", "second tmux server", "no tmux server",
	"pane shell with other argv", "foreground leader gone", "foreground group outside the pane",
	"foreground pid not its group's leader", "two live bindings for this terminal"]


func _break_topology(label: String) -> void:
	match label:
		"container init restarted (start time differs)":
			_set_stat(INIT, "tini", 0, INIT, -1, START + 1)
		"second tmux pane":
			_fake_process(1005, "bash", TMUX, 1005, 1005, 1, PANE_ARGV, [])
			_write(_proc.path_join("%d/task/%d/children" % [TMUX, TMUX]), "%d 1005 " % SHELL)
		"second pane listed by another tmux thread":
			_fake_process(1005, "bash", TMUX, 1005, 1005, 1, PANE_ARGV, [])
			_write(_proc.path_join("%d/task/1009/children" % TMUX), "1005 ")
		"second tmux server":
			_fake_process(1006, "tmux", INIT, 1006, -1, 1, ["tmux", "new-session"], [])
			_write(_proc.path_join("%d/task/%d/children" % [INIT, INIT]), "%d %d 1006 " % [TMUX, SUPERVISOR])
		"no tmux server":
			_write(_proc.path_join("%d/task/%d/children" % [INIT, INIT]), "%d " % SUPERVISOR)
		"pane shell with other argv":
			_fake_process(SHELL, "bash", TMUX, SHELL, CLAUDE, 1, ["bash", "-i"], [CLAUDE])
		"foreground leader gone":
			_set_stat(SHELL, "bash", TMUX, SHELL, 1099, 1)
		"foreground group outside the pane":
			_set_stat(SHELL, "bash", TMUX, SHELL, SUPERVISOR, 1)
		"foreground pid not its group's leader":
			_set_stat(CLAUDE, "claude", SHELL, SHELL, CLAUDE, 1)
		"two live bindings for this terminal":
			_bind("proto2", TERMINAL, Time.get_unix_time_from_system() + 60.0, "gen9")
			_launcher("proto2", {"generation": "gen9", "launcher_pgid": PGID,
				"container_pid": INIT, "container_start": START})


# ── end to end through the real session and arbiter ────────────────────

func _test_end_to_end() -> void:
	var session = load(SESSION_PATH).new("container-fg")
	root.add_child(session)
	if not session.terminal_available or not session.start(80, 24) or not session.foreground_supported():
		print("SKIP: PTY or foreground query unavailable for the end-to-end oracle")
		session.queue_free()
		return
	var launcher: String = _root.path_join("scripts/agent-container/agent.py")
	_write(launcher, LAUNCHER_SRC)
	_reset()
	session.write_input("python3 '%s'\r" % launcher)
	var ready: bool = await _wait_until(func() -> bool:
		return session.get_plain_text().find("LAUNCHERREADY") != -1)
	check("the fake launcher is in front of the tab", ready, session.read_viewport_text().right(300))
	if not ready:
		session.close()
		return
	# The binding is bound to the real launcher group the PTY reports.
	var native: Dictionary = session.terminal.get_foreground_process()
	_launcher("proto1", {"generation": "gen1", "launcher_pgid": int(native.get("pid", 0)),
		"container_pid": INIT, "container_start": START})
	_bind("proto1", str(session.terminal_id), Time.get_unix_time_from_system() + 60.0, "gen1")

	check("the tab reads as Claude inside the container", session.harness_name() == "claude",
		str(session.get_foreground_process()))
	var arbiter = session.get_input_arbiter()
	var admitted: Dictionary = session.begin_write_transaction("ok", {"expect_harness": "claude", "pause_ms": 50})
	check("a write expecting claude is admitted and says the check ran",
		bool(admitted.get("success", false)) and str(admitted.get("harness_check", "")) == arbiter.HARNESS_CHECKED,
		str(admitted))
	var landed: bool = await _wait_until(func() -> bool:
		return _dumped(session) == [0x6f, 0x6b, 0x0d])
	check("and its body then Enter reach the launcher", landed, str(_dumped(session)))

	# Claude exits: the pane shell is back in front.
	_set_stat(SHELL, "bash", TMUX, SHELL, SHELL, 1)
	var refused: Dictionary = session.begin_write_transaction("no", {"expect_harness": "claude", "pause_ms": 50})
	check("once the pane shell is in front the same write is refused",
		not bool(refused.get("success", true)) and str(refused.get("outcome", "")) == arbiter.OUTCOME_REFUSED_HARNESS,
		str(refused))
	await create_timer(0.3).timeout
	check("and writes no byte", _dumped(session) == [0x6f, 0x6b, 0x0d], str(_dumped(session)))

	_bind("proto1", str(session.terminal_id), Time.get_unix_time_from_system() - 1.0, "gen1")
	var bare: Dictionary = session.get_foreground_process()
	check("after the lease lapses the tab reads as the bare launcher",
		not bare.has("container") and session.harness_name() == "", str(bare))
	session.close()
	_fg.proc_root = "/proc"
	_fg.state_root = ""


func _dumped(session) -> Array:
	var out: Array = []
	for line in session.get_plain_text().split("\n"):
		var text: String = line.strip_edges()
		if text.begins_with("HEX "):
			out.append(text.substr(4).strip_edges().hex_to_int())
	return out
