class_name SetupExecutors
extends RefCounted
## Executes ONE `setup.steps[]` entry against real subprocesses/filesystem ops.
##
## Docs/design/plugin-setup-pipeline.md §1 (step vocabulary) and §3 (failure
## envelope) are normative, as amended by the R1 review: steps are
## CWD-INDEPENDENT — every spawned tool binary is exec'd DIRECTLY (no shell,
## no wrapper process, identical code path on every OS) with an argv that
## carries its own directory context (go's `-C <abs plugin_dir>`, absolutized
## cargo --manifest-path / python venv paths). See SetupSteps.gd — the single
## pure argv builder shared with SetupDryRun — for the exact per-type shapes.
##
## exec steps get NO cwd guarantee: argv[0] beginning with "./" is resolved
## against plugin_dir; everything after is passed verbatim. An exec'd program
## that needs the plugin directory must derive it from its own argv[0] or
## accept it as an explicit argument in the manifest's declared argv.
##
## Callers supply already-resolved absolute tool paths (tool_paths) and the
## plugin's absolute data_directory (plugin_dir). This class never re-resolves
## a tool and never expands environment variables in any field — the
## always-build rule (§3) and the "no env-var expansion" rule (§1) both
## depend on tool_paths being handed over verbatim, once, by the caller.
##
## Subprocess mechanism (reuse-scan note): MCPServerConnection's native
## `SubProcess` GDExtension class (src/gdextension/terminal/*/subprocess.*) is
## built for a *persistent* bidirectional stdio-JSON-RPC channel — the wrong
## shape for a one-shot "run this, capture everything, enforce a timeout,
## report an exit code" build step, and it would tie this GDScript-only data
## layer to the terminal extension being compiled. Instead this file uses
## Godot's built-in OS.execute_with_pipe() (confirmed present in this
## project's Godot 4.6.2): spawned with blocking=false it returns
## {"stdio": FileAccess, "stderr": FileAccess, "pid": int} immediately, which
## lets us poll OS.is_process_running(pid) against a wall-clock deadline and
## OS.kill(pid) on timeout. Reading the pipes afterwards is safe even after a
## kill — closing the write end (either on normal exit or on SIGKILL)
## unblocks FileAccess.get_as_text() at EOF, it does not hang.
## OS.get_process_exit_code(pid) supplies the exit code.

const STDERR_TAIL_CAP_BYTES := 2048


## step: one `setup.steps[]` Dictionary (assumed schema-valid — SetupSchema
##       runs at manifest load time, well before any step is executed).
## step_index: position within setup.steps, echoed into every result.
## ctx: {"tool_paths": Dictionary[String, String], "plugin_dir": String}
##      tool_paths maps a bare tool name ("go", "cargo", "python") to its
##      resolved absolute path; plugin_dir is the plugin's absolute
##      data_directory (used only for path resolution — never as a cwd).
## Returns {"ok": true, "step_type": String, "step_index": int} on success,
## or the §3 failure envelope:
##   {"error": "setup_step_failed", "step_type", "step_index", "resolved_argv",
##    "exit_code", "stderr_tail", "artifact_expected"? }
## `artifact_expected` is present only when the failure was the post-step
## artifact check (exit_code 0, declared artifact missing).
static func run_step(step: Dictionary, step_index: int, ctx: Dictionary) -> Dictionary:
	var step_type: String = str(step.get("type", ""))
	var plugin_dir: String = str(ctx.get("plugin_dir", ""))
	var tool_paths: Dictionary = ctx.get("tool_paths", {})

	if step_type == "copy":
		return _run_copy(step, step_index, plugin_dir)

	if not SetupSteps.STEP_TYPES.has(step_type):
		# SetupSchema.validate_setup() should already have rejected this at
		# manifest load — defensive fallback only.
		return _failure(step_type, step_index, [], -1, "unknown step type '%s'" % step_type)

	var plan: Dictionary = SetupSteps.build(step, tool_paths, plugin_dir)
	var timeout_s: int = plan.get("timeout_s", SetupSteps.DEFAULT_TIMEOUT_S)

	for phase in plan.get("phases", []):
		var argv_raw: Array = phase.get("argv", [])
		var argv: Array[String] = []
		for a in argv_raw:
			argv.append(str(a))
		var result := _run_and_check(
			argv, plugin_dir, timeout_s, step_type, step_index, str(phase.get("artifact", ""))
		)
		if result.has("error"):
			return result

	return {"ok": true, "step_type": step_type, "step_index": step_index}


# ---------------------------------------------------------------------------
# copy — pure filesystem op, no subprocess
# ---------------------------------------------------------------------------

static func _run_copy(step: Dictionary, step_index: int, plugin_dir: String) -> Dictionary:
	var from_rel: String = str(step.get("from", ""))
	var to_rel: String = str(step.get("to", ""))
	var from_abs: String = plugin_dir.path_join(from_rel)
	var to_abs: String = plugin_dir.path_join(to_rel)

	var to_dir := to_abs.get_base_dir()
	if not to_dir.is_empty() and not DirAccess.dir_exists_absolute(to_dir):
		DirAccess.make_dir_recursive_absolute(to_dir)

	# No subprocess involved, so there is no argv/exit_code in the usual
	# sense. On failure we still return the §3 envelope shape (resolved_argv
	# empty, exit_code -1 sentinel) so callers have one uniform failure
	# contract regardless of step type.
	var err := DirAccess.copy_absolute(from_abs, to_abs)
	if err != OK:
		return _failure("copy", step_index, [], -1,
				"copy failed (%s): '%s' -> '%s'" % [error_string(err), from_rel, to_rel])

	if not FileAccess.file_exists(to_abs):
		return _failure_artifact_missing("copy", step_index, [], 0, "", to_rel)

	# Mirror the source's mode. DirAccess.copy_absolute() creates the
	# destination with default permissions (verified: 0775 source -> 0664
	# copy), which silently strips the executable bit — and the canonical use
	# of `copy` in a setup stanza is staging a build product where the
	# toolchain left it (cargo's target/release/<bin>) to the path the
	# manifest entrypoint names. Without this the pipeline would report a
	# clean build and the plugin would then fail to spawn.
	# No-op on Windows (get/set_unix_permissions return ERR_UNAVAILABLE there,
	# and NTFS has no exec bit to lose).
	var src_perms := FileAccess.get_unix_permissions(from_abs)
	if src_perms != 0:
		FileAccess.set_unix_permissions(to_abs, src_perms)

	return {"ok": true, "step_type": "copy", "step_index": step_index}


# ---------------------------------------------------------------------------
# Shared subprocess + artifact-check path
# ---------------------------------------------------------------------------

## Runs argv (deadline = timeout_s), then verifies expected_artifact_rel
## against plugin_dir if non-empty. expected_artifact_rel == "" skips the
## post-phase check entirely (exec steps with no declared `artifact`).
static func _run_and_check(
	argv: Array[String], plugin_dir: String, timeout_s: int,
	step_type: String, step_index: int, expected_artifact_rel: String
) -> Dictionary:
	var run := _spawn(argv, timeout_s)

	if run.get("timed_out", false):
		var stderr_msg: String = str(run.get("stderr", ""))
		if not stderr_msg.is_empty():
			stderr_msg += "\n"
		stderr_msg += "[setup] step timed out after %ds" % timeout_s
		return _failure(step_type, step_index, argv, -1, stderr_msg)

	var exit_code: int = run.get("exit_code", -1)
	if exit_code != 0:
		return _failure(step_type, step_index, argv, exit_code, str(run.get("stderr", "")))

	if not expected_artifact_rel.is_empty():
		var artifact_abs: String = plugin_dir.path_join(expected_artifact_rel)
		if not FileAccess.file_exists(artifact_abs) and not DirAccess.dir_exists_absolute(artifact_abs):
			return _failure_artifact_missing(
				step_type, step_index, argv, 0, str(run.get("stderr", "")), expected_artifact_rel
			)

	return {"ok": true, "step_type": step_type, "step_index": step_index}


## Spawns argv[0] DIRECTLY with argv[1..] (no shell, no wrapper process,
## same code path on every OS), enforcing a hard timeout_s deadline (kills
## the process on overrun). Returns {"exit_code": int, "stdout": String,
## "stderr": String, "timed_out": bool}. exit_code is the -1 sentinel when
## the process could not be spawned at all or was killed for a timeout.
static func _spawn(argv: Array[String], timeout_s: int) -> Dictionary:
	if argv.is_empty():
		return {"exit_code": -1, "stdout": "", "stderr": "empty argv", "timed_out": false}

	var args := PackedStringArray()
	for i in range(1, argv.size()):
		args.append(argv[i])

	var spawn: Dictionary = OS.execute_with_pipe(argv[0], args, false)
	if spawn.is_empty():
		return {
			"exit_code": -1, "stdout": "", "stderr": "failed to spawn '%s'" % argv[0], "timed_out": false,
		}

	var pid: int = spawn.get("pid", -1)
	var stdio: FileAccess = spawn.get("stdio", null)
	var stderr_pipe: FileAccess = spawn.get("stderr", null)

	var deadline_ms: int = Time.get_ticks_msec() + maxi(timeout_s, 1) * 1000
	var timed_out := false
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > deadline_ms:
			timed_out = true
			OS.kill(pid)
			break
		OS.delay_msec(20)

	# Reads unblock at EOF whether the process exited normally or was just
	# killed — the write end of the pipe closes either way.
	var stdout_text: String = stdio.get_as_text() if stdio != null else ""
	var stderr_text: String = stderr_pipe.get_as_text() if stderr_pipe != null else ""
	var exit_code: int = -1 if timed_out else OS.get_process_exit_code(pid)

	return {"exit_code": exit_code, "stdout": stdout_text, "stderr": stderr_text, "timed_out": timed_out}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _tail(text: String) -> String:
	var bytes := text.to_utf8_buffer()
	if bytes.size() <= STDERR_TAIL_CAP_BYTES:
		return text
	var tail_bytes := bytes.slice(bytes.size() - STDERR_TAIL_CAP_BYTES, bytes.size())
	return tail_bytes.get_string_from_utf8()


static func _failure(
	step_type: String, step_index: int, resolved_argv: Array[String], exit_code: int, stderr: String
) -> Dictionary:
	return {
		"error": "setup_step_failed",
		"step_type": step_type,
		"step_index": step_index,
		"resolved_argv": resolved_argv,
		"exit_code": exit_code,
		"stderr_tail": _tail(stderr),
	}


static func _failure_artifact_missing(
	step_type: String, step_index: int, resolved_argv: Array[String],
	exit_code: int, stderr: String, artifact_expected: String
) -> Dictionary:
	var envelope := _failure(step_type, step_index, resolved_argv, exit_code, stderr)
	envelope["artifact_expected"] = artifact_expected
	return envelope
