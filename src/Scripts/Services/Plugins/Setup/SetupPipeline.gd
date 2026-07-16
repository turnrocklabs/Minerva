class_name SetupPipeline
extends RefCounted
## Orchestrates ONE plugin's manifest-install setup pipeline end to end:
## toolchain preflight -> run `setup.steps[]` in declared order (always, no
## skip logic) -> verify the manifest entrypoint artifact exists -> report
## success. DCR 019f69428fa0, Docs/design/plugin-setup-pipeline.md §2/§3
## (G3.1/G3.2) — this file is the state-machine/threading piece; the actual
## resolve/build/execute mechanics all live in the already-tested R1 classes
## (ToolchainRegistry, SetupExecutors) — this class does not duplicate them.
##
## THREADING CONTRACT: run_async() spawns a worker Thread and returns
## immediately — ToolchainRegistry.preflight()/resolve() busy-wait up to 5s
## PER TOOL (see ToolchainRegistry's own THREADING header) and SetupExecutors
## spawns real subprocesses with per-step timeouts up to 300s by default, so
## none of that work may run on the caller's thread. All progress/result
## signals are emitted via call_deferred from inside the worker, so every
## signal handler you connect fires on the MAIN thread, never the worker —
## callers never need their own marshalling. The instance self-joins its
## worker thread from within the final deferred callback (`_emit_finished`,
## which runs on the main thread), so callers do not need to call
## wait_to_finish() themselves; `is_running()` only flips false once that
## join has happened, so polling it is a safe "pipeline is fully done,
## including its last emitted signal" check for tests.
##
## APPROVAL SEAM (exec steps): contract §1 — "exec is the only step requiring
## explicit user confirmation at install (its argv is shown verbatim)".
## `approver`, if set, is a Callable(step: Dictionary, step_index: int) -> bool
## invoked from the WORKER thread immediately before an exec step runs. The
## default (approver unset) auto-approves with a push_warning stub — this
## round has no UI. A future UI round (C4) can plug a real confirmation
## dialog in here WITHOUT touching this class, but MUST do its own
## main-thread marshalling (e.g. call_deferred to show a dialog + a
## Semaphore/mutex handshake to block the worker thread on the user's
## answer) — this class invokes the Callable synchronously, in place, on the
## worker thread, and does not marshal on the seam's behalf.
##
## ALWAYS-BUILD: every call to run_async() runs every declared step,
## unconditionally — there is no source-hash/skip cache in v1 (contract §3).
##
## ENVELOPE EXTENSIONS beyond the contract's base shapes (both review-codified):
##   - Preflight failure (S_NEEDS_BINARY): top level carries the FIRST
##     failure's §2 fields flat, plus `failures` = the full Array of per-tool
##     §2 envelopes, so a UI can show every missing tool at once.
##   - Denied exec step (S_BUILD_FAILED): the §3 envelope additionally carries
##     `detail: "exec_denied"` — its argv WAS resolved but never spawned
##     (exit_code -1 sentinel), and a UI (C4) must render it as "you declined
##     this step", not as a broken build.

## Emitted (via call_deferred, so always on the main thread) right before a
## step starts executing.
signal step_started(step_index: int, step_type: String)

## Emitted (via call_deferred) right after a step finishes, success or fail.
## `detail` is the SetupExecutors.run_step() result Dictionary (either
## {"ok": true, ...} or the §3 failure envelope).
signal step_finished(step_index: int, step_type: String, ok: bool, detail: Dictionary)

## Emitted (via call_deferred) exactly once, terminally, whether the run
## succeeded or failed. Shape:
##   {"ok": true,  "state": "registered"}
##   {"ok": false, "state": "S_NEEDS_BINARY",  "envelope": <contract §2 shape>}
##   {"ok": false, "state": "S_BUILD_FAILED",  "envelope": <contract §3 shape>}
signal finished(result: Dictionary)

## Injectable ToolchainRegistry (test seam: point search_dirs_override /
## config_path at fixtures). Defaults to a fresh production ToolchainRegistry
## when left null.
var toolchain_registry: ToolchainRegistry = null

## Exec-step approval seam — see class doc. Callable(Dictionary, int) -> bool.
## An invalid/unset Callable means "auto-approve" (this round's default).
var approver: Callable = Callable()

var _thread: Thread = null
var _running: bool = false


## True from the moment run_async() is called until the terminal `finished`
## signal has actually been emitted AND the worker thread has been joined.
func is_running() -> bool:
	return _running


## Kick off the pipeline on a worker thread and return immediately.
##   plugin_id           — logging/signal identification only.
##   setup                — the manifest's `setup` stanza (already schema-valid
##                           — SetupSchema runs at manifest load time).
##   plugin_dir            — absolute plugin data_directory.
##   entrypoint_artifact  — plugin-relative path to the manifest entrypoint
##                           binary, or "" to skip the final existence check
##                           (e.g. interpreter-launched entrypoints like
##                           "python3" that aren't a build output).
func run_async(plugin_id: String, setup: Dictionary, plugin_dir: String, entrypoint_artifact: String) -> void:
	if _running:
		push_warning("[SetupPipeline] run_async('%s') called while already running — ignored" % plugin_id)
		return
	_running = true
	_thread = Thread.new()
	var err := _thread.start(_run_worker.bind(plugin_id, setup, plugin_dir, entrypoint_artifact))
	if err != OK:
		_running = false
		push_error("[SetupPipeline] failed to start worker thread for '%s': %s" % [plugin_id, error_string(err)])
		finished.emit({"ok": false, "state": "S_BUILD_FAILED", "envelope": {
			"error": "setup_pipeline_internal_error",
			"detail": "Thread.start failed: %s" % error_string(err),
		}})


# ---------------------------------------------------------------------------
# Worker thread body — everything below this point may run OFF the main
# thread. No Node/SceneTree access; only RefCounted helpers + OS/FileAccess/
# DirAccess statics, matching SetupExecutors' own thread-safety assumptions.
# ---------------------------------------------------------------------------

func _run_worker(plugin_id: String, setup: Dictionary, plugin_dir: String, entrypoint_artifact: String) -> void:
	var registry: ToolchainRegistry = toolchain_registry if toolchain_registry != null else ToolchainRegistry.new()

	var requires: Array = setup.get("requires", [])
	var preflight: Dictionary = registry.preflight(requires)
	if not preflight.get("ok", true):
		# Envelope top level = the FIRST failure's §2 fields (so single-failure
		# consumers keep one flat shape), plus a `failures` array carrying EVERY
		# per-tool §2 envelope — ToolchainRegistry.preflight() deliberately
		# never stops at the first missing tool (contract intent: the user sees
		# all missing tools in one pass), and this surface must not re-hide
		# that by persisting only failures[0].
		var failures: Array = preflight.get("failures", [])
		var envelope: Dictionary
		if failures.is_empty():
			envelope = {
				"error": "toolchain_missing", "tool": "", "found_path": "", "found_version": "",
				"required_min": "", "install_hint": "",
			}
		else:
			envelope = (failures[0] as Dictionary).duplicate(true)
		envelope["failures"] = failures.duplicate(true)
		_finish_failed(plugin_id, "S_NEEDS_BINARY", envelope)
		return

	var tool_paths: Dictionary = preflight.get("resolved", {})
	var ctx := {"tool_paths": tool_paths, "plugin_dir": plugin_dir}

	var steps_raw: Variant = setup.get("steps", [])
	var steps: Array = steps_raw if steps_raw is Array else []

	for i in steps.size():
		var step: Dictionary = steps[i]
		var step_type: String = str(step.get("type", ""))
		call_deferred("_emit_step_started", i, step_type)

		if step_type == "exec":
			var approved := _run_approval(step, i)
			if not approved:
				var denied := {
					"error": "setup_step_failed",
					"step_type": "exec",
					"step_index": i,
					"resolved_argv": step.get("argv", []),
					"exit_code": -1,
					"stderr_tail": "denied by approver",
					"detail": "exec_denied",
				}
				call_deferred("_emit_step_finished", i, step_type, false, denied)
				_finish_failed(plugin_id, "S_BUILD_FAILED", denied)
				return

		var step_result: Dictionary = SetupExecutors.run_step(step, i, ctx)
		if step_result.has("error"):
			call_deferred("_emit_step_finished", i, step_type, false, step_result)
			_finish_failed(plugin_id, "S_BUILD_FAILED", step_result)
			return

		call_deferred("_emit_step_finished", i, step_type, true, step_result)

	if not entrypoint_artifact.is_empty():
		var artifact_abs: String = plugin_dir.path_join(entrypoint_artifact)
		if not FileAccess.file_exists(artifact_abs) and not DirAccess.dir_exists_absolute(artifact_abs):
			var missing_envelope := {
				"error": "setup_step_failed",
				"step_type": "entrypoint_check",
				"step_index": steps.size(),
				"resolved_argv": [],
				"exit_code": 0,
				"stderr_tail": "",
				"artifact_expected": entrypoint_artifact,
			}
			_finish_failed(plugin_id, "S_BUILD_FAILED", missing_envelope)
			return

	call_deferred("_emit_finished", {"ok": true, "state": "registered", "plugin_id": plugin_id})


## Runs the approver Callable (or auto-approves with a stub warning). Called
## from the worker thread — see the class doc's APPROVAL SEAM note.
func _run_approval(step: Dictionary, step_index: int) -> bool:
	if approver.is_valid():
		return bool(approver.call(step, step_index))
	push_warning("[SetupPipeline] no approver configured for exec step %d (argv=%s) — auto-approving (stub; C4 plugs a real dialog in here)" % [
		step_index, str(step.get("argv", [])),
	])
	return true


func _finish_failed(plugin_id: String, state: String, envelope: Dictionary) -> void:
	call_deferred("_emit_finished", {"ok": false, "state": state, "envelope": envelope, "plugin_id": plugin_id})


# ---------------------------------------------------------------------------
# Deferred emitters — these run on the MAIN thread (call_deferred target).
# ---------------------------------------------------------------------------

func _emit_step_started(step_index: int, step_type: String) -> void:
	step_started.emit(step_index, step_type)


func _emit_step_finished(step_index: int, step_type: String, ok: bool, detail: Dictionary) -> void:
	step_finished.emit(step_index, step_type, ok, detail)


func _emit_finished(result: Dictionary) -> void:
	# Self-join: this callback runs on the main thread (call_deferred), and by
	# construction it is always the LAST thing the worker thread schedules, so
	# the worker has nothing left to do — wait_to_finish() here just performs
	# the OS-level join without making callers manage the Thread object.
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_running = false
	finished.emit(result)
