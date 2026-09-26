extends RefCounted
## Agent-container sessions as Minerva records: create, start, stop, status
## and list. A record (id, harness, the host folders it mounts, start folder,
## Docket projects, mode) is kept by the launcher Minerva ships, agent.py, in
## <state root>/sessions/NAME/session.json, so it outlives Minerva and is
## listed again on relaunch; its state (running, stopped) is read live from
## Docker on every call. The store keeps no copy of its own.
##
## Every call runs `python3 agent.py COMMAND ... --json` without blocking a
## frame (BoundedProcess) and returns the launcher's one JSON answer:
## {"ok": true, ...} or {"ok": false, "error": "..."}. Sessions in status and
## list answers also carry `attach_command`, the line that attaches the
## session from a Minerva terminal tab.
##
## info() and readiness() inspect a session without changing it: info adds its
## path mappings, Git identity, toolchain profile and its registered session
## identity (HarnessSessionRegistry, the identity notify routes by); readiness
## lists what the session is missing (agent.py readiness, readiness.py).
##
## Grants: status, info and list answers carry `grants`, the session's grant
## record {version, note_read, note_write, notify, and identity + role once one
## is registered} (agent.py grants.json);
## grant() and revoke() change it at any time, running or not. The session's
## gateway reads the record on every call, so the change applies to its next
## call with no attach.
##
## Docket identity: the identity and role HarnessSessionRegistry holds for a
## container session are copied into its grant record (agent.py identity)
## whenever the registry changes, and once when the store is first created.
## The session's gateway scopes its Docket access to the work assigned or
## directed to them (gateway/docket_scope.py).
##
## attach() fronts a running session in a terminal tab: it writes the attach
## command into the tab's shell, where the launcher holds the session's lease
## and its one tmux client. The newest attach wins: attaching while another
## tab fronts the session takes it over, and that tab's launcher reports it
## detached and returns it to its shell. The session outlives Minerva, so
## after a relaunch any fresh tab attaches it again with its harness as it
## was; grants are per-session records, so nothing else re-binds.
##
## The GUI twins are AgentSessionsPanel (Preferences > Containers) and the
## terminal tab menu (AgentSessionAttachMenu); the MCP twin is
## MCPAgentSessionTools. All share the one instance from shared().

## Emitted after a call that may have changed a record or its state.
signal changed

const NAME_PATTERN := "^[a-z0-9][a-z0-9-]{0,31}$"
const NOTE_ID_PATTERN := "^[0-9a-f]{32,64}$"
const HARNESSES: PackedStringArray = ["claude", "codex"]
const MODES: PackedStringArray = ["start", "resume", "shell"]
const HarnessSessionRegistry := preload("res://Scripts/Services/Terminal/HarnessSessionRegistry.gd")

## Programs that count as a tab at its shell prompt, where attach may type.
const SHELLS: PackedStringArray = ["bash", "zsh", "sh", "dash", "fish", "ksh", "mksh"]
## How long attach() waits for the tab to show the session in front: the
## launcher waits up to 10 s for its tmux client, plus docker's own start-up.
const ATTACH_WAIT_S := 30.0
const ATTACH_POLL_S := 0.25

const PROFILE_PATTERN := "^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"
const PYTHON := "python3"
const QUICK_TIMEOUT_S := 60.0
## The container probe and the Docket query each have their own bound inside.
const READINESS_TIMEOUT_S := 150.0
## The first start clones every checkout folder.
const START_TIMEOUT_S := 900.0
## The first build also builds the builder image's toolchains.
const BUILD_TIMEOUT_S := 7200.0
## Where a packaged build carries the kit (scripts/stage-agent-kit.sh), relative
## to the executable's directory: beside it on Linux, in Resources on macOS.
const PACKAGED_LAUNCHERS: PackedStringArray = [
	"agent-kit/agent-container/agent.py",
	"../Resources/agent-kit/agent-container/agent.py",
]
## Relative to the project directory, for editor and source runs.
const SOURCE_LAUNCHER := "../scripts/agent-container/agent.py"

static var _shared: RefCounted = null

## True while build() runs; the last build's answer stays in last_build.
var building: bool = false
var last_build: Dictionary = {}
## Container session name -> "identity\nrole" last written to its grant record.
var _identities_written: Dictionary = {}


static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://Scripts/Services/AgentSessions/AgentSessionStore.gd").new()
		var sync := Callable(_shared, "sync_identities")
		HarnessSessionRegistry.shared().changed.connect(sync)
		sync.call()
	return _shared


## Writes each container session's registered identity and role into its
## grant record, and clears it for a session whose registration is gone. Only
## changes since the last write run the launcher; a failure is reported once
## and retried when that registration next changes.
func sync_identities() -> void:
	if OS.get_name() == "Windows" or launcher_path().is_empty():
		return
	var registry: HarnessSessionRegistry = HarnessSessionRegistry.shared()
	var wanted: Dictionary = registry.container_identities()
	for container: String in _identities_written:
		if not wanted.has(container):
			wanted[container] = {"identity": "", "role": ""}
	var wrote: bool = false
	for container: String in wanted:
		var identity: String = str(wanted[container]["identity"])
		var role: String = str(wanted[container]["role"])
		var written: String = "%s\n%s" % [identity, role]
		if str(_identities_written.get(container, "")) == written or not _check_id(container).is_empty():
			continue
		# Marked before the launcher runs, so a change signalled meanwhile
		# does not write the same record twice.
		_identities_written[container] = written
		var args: PackedStringArray = ["identity", container]
		if not identity.is_empty():
			args.append("--identity=" + identity)
			if not role.is_empty():
				args.append("--role=" + role)
		var result: Dictionary = await _run(args, QUICK_TIMEOUT_S)
		wrote = true
		if not bool(result.get("ok", false)):
			push_warning("AgentSessionStore: Docket identity for %s not recorded: %s" % [container, str(result.get("error", ""))])
		if identity.is_empty() and _identities_written.get(container) == written:
			_identities_written.erase(container)
	if wrote:
		changed.emit()


## The launcher this Minerva uses: the packaged kit when present, else the
## source checkout the project runs from. "" when neither exists.
static func launcher_path() -> String:
	var exe_dir: String = OS.get_executable_path().get_base_dir()
	for relative: String in PACKAGED_LAUNCHERS:
		var path: String = exe_dir.path_join(relative).simplify_path()
		if FileAccess.file_exists(path):
			return path
	var source: String = ProjectSettings.globalize_path("res://").path_join(SOURCE_LAUNCHER).simplify_path()
	return source if FileAccess.file_exists(source) else ""


## The command that attaches session `id` when run in a Minerva terminal tab.
static func attach_command(id: String) -> String:
	var launcher: String = launcher_path()
	if launcher.is_empty():
		return ""
	return "%s '%s' attach %s" % [PYTHON, launcher.replace("'", "'\\''"), id]


func create(id: String, harness: String, folders: PackedStringArray, start_in: String,
		projects: PackedStringArray, mode: String) -> Dictionary:
	var problem: String = _check_id(id)
	if problem.is_empty() and not HARNESSES.has(harness):
		problem = "harness must be one of: %s" % ", ".join(HARNESSES)
	if problem.is_empty() and not mode.is_empty() and not MODES.has(mode):
		problem = "mode must be one of: %s" % ", ".join(MODES)
	if problem.is_empty() and folders.is_empty():
		problem = "a session mounts at least one folder"
	if not problem.is_empty():
		return _error(problem)
	# --option=value keeps a path that starts with "-" from reading as an option.
	var args: PackedStringArray = ["create", id, "--harness=" + harness]
	for folder: String in folders:
		args.append("--folder=" + folder)
	if not start_in.is_empty():
		args.append("--start-in=" + start_in)
	for project: String in projects:
		args.append("--project=" + project)
	if not mode.is_empty():
		args.append("--mode=" + mode)
	var result: Dictionary = await _run(args, QUICK_TIMEOUT_S)
	changed.emit()
	return result


## Starts session `id`; `mode` overrides the record's mode for this start only.
func start(id: String, mode: String = "") -> Dictionary:
	var problem: String = _check_id(id)
	if problem.is_empty() and not mode.is_empty() and not MODES.has(mode):
		problem = "mode must be one of: %s" % ", ".join(MODES)
	if not problem.is_empty():
		return _error(problem)
	var args: PackedStringArray = ["start", id]
	if not mode.is_empty():
		args.append("--mode=" + mode)
	var result: Dictionary = await _run(args, START_TIMEOUT_S)
	changed.emit()
	return _with_attach(result)


## Stops both containers; the record, home and clones are kept.
func stop(id: String) -> Dictionary:
	var problem: String = _check_id(id)
	if not problem.is_empty():
		return _error(problem)
	var result: Dictionary = await _run(PackedStringArray(["stop", id]), QUICK_TIMEOUT_S)
	changed.emit()
	return result


func status(id: String) -> Dictionary:
	var problem: String = _check_id(id)
	if not problem.is_empty():
		return _error(problem)
	return _with_attach(await _run(PackedStringArray(["status", id]), QUICK_TIMEOUT_S))


## One session for inspection: status plus path_mappings, git_identity,
## toolchain_profile and session_identity; `map_paths` are host paths answered
## in `mapped` with the path the harness sees (null when no folder holds one).
func info(id: String, map_paths: PackedStringArray = PackedStringArray()) -> Dictionary:
	var problem: String = _check_id(id)
	if not problem.is_empty():
		return _error(problem)
	var args: PackedStringArray = ["info", id]
	for path: String in map_paths:
		args.append("--map=" + path)
	var result: Dictionary = _with_attach(await _run(args, QUICK_TIMEOUT_S))
	if bool(result.get("ok", false)):
		result["session_identity"] = session_identity(id, str(result.get("attached_terminal", "")))
	return result


## Read-only readiness of session `id` against toolchain profile `profile`
## ("" = the default): {"ok", "ready", "checks": [{check, name, ok, detail}],
## "missing": [...], "checked"}. A registered session identity is one check.
func readiness(id: String, profile: String = "") -> Dictionary:
	var problem: String = _check_id(id)
	if problem.is_empty() and not profile.is_empty() \
			and RegEx.create_from_string(PROFILE_PATTERN).search(profile) == null:
		problem = "profile names are letters, digits and . _ + -"
	if not problem.is_empty():
		return _error(problem)
	var args: PackedStringArray = ["readiness", id]
	if not profile.is_empty():
		args.append("--profile=" + profile)
	var result: Dictionary = await _run(args, READINESS_TIMEOUT_S)
	if not bool(result.get("ok", false)):
		return result
	var identity: Dictionary = session_identity(id, "")
	var registered: bool = bool(identity["registered"])
	var check: Dictionary = {"check": "identity", "name": id, "ok": registered,
		"detail": str(identity["identity"]) if registered else
			"no session identity is registered: register it with minerva_session_register (container %s)" % id}
	var checks: Array = result.get("checks", []) if result.get("checks") is Array else []
	checks.append(check)
	result["checks"] = checks
	if not registered:
		var missing: Array = result.get("missing", []) if result.get("missing") is Array else []
		missing.append("identity %s: %s" % [id, check["detail"]])
		result["missing"] = missing
		result["ready"] = false
	return result


## The session's identity as HarnessSessionRegistry holds it: the record
## registered for container `id`, and, when `terminal_id` fronts the session,
## what the registry answers for that terminal (the same record, so
## `consistent` is true unless a stale binding shadows it).
static func session_identity(id: String, terminal_id: String) -> Dictionary:
	var registry: HarnessSessionRegistry = HarnessSessionRegistry.shared()
	var identity: String = registry.identity_for_container(id)
	var described: Dictionary = {"identity": identity, "registered": not identity.is_empty()}
	if not terminal_id.is_empty():
		var for_terminal: String = registry.identity_for_terminal(terminal_id)
		described["terminal_id"] = terminal_id
		described["terminal_identity"] = for_terminal
		described["consistent"] = for_terminal == identity
	return described


## Fronts running session `id` in `terminal` (a TerminalSession at its shell
## prompt), taking it over from any tab that fronts it now. Writes the attach
## command as one guarded write (the shell must still be the foreground, and
## no person may have typed there within `typed_window_ms`; 0 skips that
## check), then waits until the tab shows the session in front. Answers
## {"ok", "id", "terminal_id", "took_over_from"} ("" when no tab held it), or
## {"ok": true, "already_attached": true} when this tab already fronts it.
## Refused with a reason when the session is not running, or the tab is
## running something other than a shell (a harness, another session).
func attach(id: String, terminal: TerminalSession, typed_window_ms: int = 0) -> Dictionary:
	var problem: String = _check_id(id)
	if problem.is_empty() and (terminal == null or not terminal.is_alive()):
		problem = "that terminal has exited"
	if problem.is_empty() and not terminal.foreground_supported():
		problem = "attaching needs a terminal whose foreground Minerva can read (Linux or macOS)"
	if not problem.is_empty():
		return _error(problem)
	var described: Dictionary = await status(id)
	if not bool(described.get("ok", false)):
		return described
	if str(described.get("state", "")) != "running":
		return _error("session %s is not running; start it first" % id)
	var command: String = attach_command(id)
	if command.is_empty():
		return _error("this Minerva build has no agent-session launcher (agent-kit/agent-container/agent.py)")
	var terminal_id: String = str(terminal.terminal_id)
	var front: Dictionary = terminal.get_foreground_process()
	var fronting: String = str(front.get("container", ""))
	if fronting == id:
		return {"ok": true, "id": id, "terminal_id": terminal_id, "already_attached": true,
			"took_over_from": "", "message": "session %s is already attached in this tab" % id}
	if not fronting.is_empty():
		return _error("this tab fronts agent session %s; detach it there (Ctrl+] then d) or use another tab" % fronting)
	var program: String = TerminalSession.program_of(front)
	if front.is_empty() or not SHELLS.has(program):
		return _error("this tab is running %s, not a shell at its prompt; attach from a tab at a shell prompt"
			% (program if not program.is_empty() else "something Minerva cannot read"))
	var previous: String = str(described.get("attached_terminal", ""))
	var receipt: Dictionary = terminal.begin_write_transaction(command,
		{"expect_process": int(front.get("pid", 0)), "unless_typed_within_ms": typed_window_ms})
	if not bool(receipt.get("success", false)):
		return _error(str(receipt.get("error", "the attach command could not be written")))
	var tree := Engine.get_main_loop() as SceneTree
	var waited: float = 0.0
	while waited < ATTACH_WAIT_S and terminal.is_alive():
		await tree.create_timer(ATTACH_POLL_S).timeout
		waited += ATTACH_POLL_S
		if str(terminal.get_foreground_process().get("container", "")) == id:
			changed.emit()
			return {"ok": true, "id": id, "terminal_id": terminal_id,
				"took_over_from": previous if previous != terminal_id else "",
				"message": "session %s attached in this tab" % id}
	changed.emit()
	# The lease can be this tab's while the pane is not readable from the host
	# (an extra pane or window): attached, but notify into it will hold.
	var after: Dictionary = await status(id)
	if str(after.get("attached_terminal", "")) == terminal_id:
		return {"ok": true, "id": id, "terminal_id": terminal_id,
			"took_over_from": previous if previous != terminal_id else "", "pane_readable": false,
			"message": "session %s attached in this tab, but its tmux pane cannot be read from the host" % id}
	return _error("session %s did not come to the front within %d s; the tab shows the launcher's answer"
		% [id, int(ATTACH_WAIT_S)])


## Adds grants to session `id`: notes it may read, notes it may write (write
## implies read) and, when `notify`, the notify grant (any harness tab except
## its own). Answers {"ok", "id", "grants"}.
func grant(id: String, note_read: PackedStringArray, note_write: PackedStringArray,
		notify: bool) -> Dictionary:
	return await _change_grants("grant", id, note_read, note_write, notify)


## Removes those grants: a read entry, a write entry, the notify grant. A note
## still in the other list keeps that access.
func revoke(id: String, note_read: PackedStringArray, note_write: PackedStringArray,
		notify: bool) -> Dictionary:
	return await _change_grants("revoke", id, note_read, note_write, notify)


func _change_grants(command: String, id: String, note_read: PackedStringArray,
		note_write: PackedStringArray, notify: bool) -> Dictionary:
	var problem: String = _check_id(id)
	var pattern := RegEx.create_from_string(NOTE_ID_PATTERN)
	var args: PackedStringArray = [command, id]
	for note: String in note_read + note_write:
		if problem.is_empty() and pattern.search(note) == null:
			problem = "note ids are 32-64 lowercase hex characters: %s" % note
	for note: String in note_read:
		args.append("--note-read=" + note)
	for note: String in note_write:
		args.append("--note-write=" + note)
	if notify:
		args.append("--notify")
	if problem.is_empty() and note_read.is_empty() and note_write.is_empty() and not notify:
		problem = "name at least one grant: a note to read, a note to write, or notify"
	if not problem.is_empty():
		return _error(problem)
	var result: Dictionary = await _run(args, QUICK_TIMEOUT_S)
	changed.emit()
	return result


## Every record, with its state, and whether the agent image is built:
## {"ok", "sessions": [...], "image": {"tag", "built"}, "building"}.
func list_sessions() -> Dictionary:
	var result: Dictionary = await _run(PackedStringArray(["list"]), QUICK_TIMEOUT_S)
	var sessions: Array = result.get("sessions", []) if result.get("sessions") is Array else []
	for session: Variant in sessions:
		if session is Dictionary:
			_with_attach(session)
	result["building"] = building
	return result


## Builds the agent image (and its builder image) from the kit's recipes.
## One build at a time; a second call while one runs answers at once.
func build() -> Dictionary:
	if building:
		return _error("the agent image is already building")
	building = true
	changed.emit()
	last_build = await _run(PackedStringArray(["build"]), BUILD_TIMEOUT_S)
	building = false
	changed.emit()
	return last_build


func _run(args: PackedStringArray, timeout_s: float) -> Dictionary:
	if OS.get_name() == "Windows":
		return _error("agent sessions need a Linux or macOS host")
	var launcher: String = launcher_path()
	if launcher.is_empty():
		return _error("this Minerva build has no agent-session launcher (agent-kit/agent-container/agent.py)")
	var argv: PackedStringArray = [launcher]
	argv.append_array(args)
	argv.append("--json")
	var outcome: Dictionary = await BoundedProcess.run(PYTHON, argv, timeout_s)
	var output: String = str(outcome.get("output", ""))
	# The answer is the first stdout line; anything after it is stderr.
	var answer: Variant = JSON.parse_string(output.get_slice("\n", 0))
	if answer is Dictionary and (answer as Dictionary).has("ok"):
		return answer
	# 127: the shell convention for a program that was not found.
	if int(outcome.get("pid", -1)) == -1 or (int(outcome.get("exit_code", 0)) == 127 and output.strip_edges().is_empty()):
		return _error("%s could not be started; agent sessions need Python 3 on PATH" % PYTHON)
	if int(outcome.get("exit_code", 0)) == -1:
		return _error("the launcher did not finish within %d s" % int(timeout_s))
	var text: String = output.strip_edges()
	return _error(text if not text.is_empty() else "the launcher failed (exit %d)" % int(outcome.get("exit_code", 0)))


static func _with_attach(session: Dictionary) -> Dictionary:
	if bool(session.get("ok", false)) and session.has("id"):
		session["attach_command"] = attach_command(str(session["id"]))
	return session


static func _check_id(id: String) -> String:
	var pattern := RegEx.create_from_string(NAME_PATTERN)
	if pattern.search(id) == null:
		return "session names are 1-32 lowercase letters, digits and -, starting with a letter or digit"
	return ""


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
