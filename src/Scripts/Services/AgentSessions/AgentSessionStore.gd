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
## The GUI twin is AgentSessionsPanel (Preferences > Containers); the MCP twin
## is MCPAgentSessionTools. Both share the one instance from shared().

## Emitted after a call that may have changed a record or its state.
signal changed

const NAME_PATTERN := "^[a-z0-9][a-z0-9-]{0,31}$"
const HARNESSES: PackedStringArray = ["claude", "codex"]
const MODES: PackedStringArray = ["start", "resume", "shell"]
const PYTHON := "python3"
const QUICK_TIMEOUT_S := 60.0
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


static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://Scripts/Services/AgentSessions/AgentSessionStore.gd").new()
	return _shared


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
