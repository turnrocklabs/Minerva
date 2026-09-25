class_name PluginManager
extends Node
## Lifecycle supervisor for Minerva plugins.
##
## Owns a PluginDB, drives per-plugin state transitions, spawns and tears down
## MCPServerConnection instances, and monitors running processes for unexpected
## exits.  Policy enforcement and MCP tool registration are handled elsewhere.
##
## Crash-loop detection: if a plugin crashes 3 or more times within a 60-second
## rolling window, it is placed in CRASH_LOOP state and will not be auto-restarted.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const AutoUpdater := preload("res://Scripts/Services/Plugins/PluginAutoUpdater.gd")
const PendingUpgrade := preload("res://Scripts/Services/Plugins/PluginPendingUpgrade.gd")
const InstallWorkers := preload("res://Scripts/Services/Plugins/PluginInstallWorkers.gd")

## How often (seconds) to poll running plugins for liveness.
const HEALTH_CHECK_INTERVAL_SEC := 5.0

## Number of crashes within the window that triggers CRASH_LOOP.
const CRASH_LOOP_THRESHOLD := 3

## Rolling window (seconds) used for crash-loop detection.
const CRASH_LOOP_WINDOW_SEC := 60.0

## How often (seconds) to check plugin file modification times for hot reload.
const FILE_WATCH_INTERVAL_SEC := 2.0

## Seconds to wait after a file change before triggering a reload (debounce).
const RELOAD_DEBOUNCE_SEC := 0.5

## File extensions watched for hot reload.
const WATCH_EXTENSIONS := ["py", "js", "sh", "json", "gd", "tscn"]

## Mirrors of PluginDefinition.State to avoid parse-order dependency.
## PluginManager extends Node (parsed early); PluginDefinition extends RefCounted.
const S_INSTALLED := 0   # S_INSTALLED
const S_STARTING := 1    # S_STARTING
const S_RUNNING := 2     # S_RUNNING
const S_STOPPED := 3     # S_STOPPED
const S_ERROR := 4       # S_ERROR
const S_CRASH_LOOP := 5  # S_CRASH_LOOP

## Manifest-install setup-pipeline states (DCR 019f69428fa0, contract
## Docs/design/plugin-setup-pipeline.md §3). These are NOT members of
## PluginDefinition.State — that enum lives in PluginDefinition.gd, which is
## out of this round's scope fence — so `def.state` (declared as that enum
## type) is assigned these plain ints exactly the same way the six mirrored
## constants above already are (PluginDefinition.State is, like every
## GDScript enum, just a named int; assigning an int outside its named set
## is legal and already proven by the existing S_* mirror pattern).
## S_BUILDING     — setup pipeline running (SetupPipeline worker thread active).
## S_BUILD_FAILED — terminal until rebuild(); carries a §3 step-failure envelope.
## S_NEEDS_BINARY — preflight failed (missing/too-old/shim/hang toolchain) or,
##                  for a future marketplace lane (C6, out of scope here), no
##                  runnable artifact and no setup lane; carries a §2 envelope.
const S_BUILDING := 6
const S_BUILD_FAILED := 7
const S_NEEDS_BINARY := 8

const SkillConsent := preload("res://Scripts/Services/Plugins/PluginSkillConsent.gd")
const Seeding := preload("res://Scripts/Services/Plugins/PluginContentSeeding.gd")


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal plugin_started(id: String)
## Plugin `id`'s process has started and its backend tools are discovered
## (start_plugin succeeded): from now on they can be called.
signal plugin_ready(id: String)
## An agent's or a panel's call of backend tool `tool` of plugin `id` has
## ended, answered or not (so it may have changed something there).
signal backend_tool_called(id: String, tool: String)
signal plugin_stopped(id: String)
signal plugin_crashed(id: String)
signal plugin_state_changed(id: String, old_state: int, new_state: int)
signal plugin_file_changed(id: String)
## A reconcile_recovered drain finished.
signal content_drained
## Emitted when live GDScript instances make an in-process update unsafe.
signal plugin_restart_required(id: String, reason: String)

## Setup-pipeline progress (DCR 019f69428fa0 round R3-UI, G4.1/G4.2). Re-emitted,
## with `id` correlated (SetupPipeline's own signals don't carry it), whenever
## the SetupPipeline running for `id` reports a step boundary. `step_count` is
## the plugin's declared `setup.steps[]` length. See get_build_progress()/
## get_build_log() below for the polling-free UI + MCP surface these back.
signal plugin_build_step_started(id: String, step_index: int, step_count: int, step_type: String)
signal plugin_build_step_finished(id: String, step_index: int, step_count: int, step_type: String, ok: bool, detail: Dictionary)


# ---------------------------------------------------------------------------
# Private types
# ---------------------------------------------------------------------------

## Per-plugin runtime bookkeeping stored in _runtime dict (keyed by plugin id).
## We use a plain Dictionary rather than a class so that we don't need a
## separate file for a simple struct.
##
## Fields:
##   connection: MCPServerConnection | null
##   start_time: float   — Time.get_unix_time_from_system() at last start
##   crash_count: int    — total lifetime crashes
##   crash_times: Array[float]  — timestamps of crashes within rolling window
##   stopping: bool      — true while stop_plugin is running (avoid re-entry)


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var _db = null  # PluginDB — initialized in _ready to avoid parse-order issues

## id -> runtime Dictionary (see comment above)
var _runtime: Dictionary = {}
## Plugin id → Callable(tool: String, arguments: Dictionary, caller: String)
## -> String, awaited before an agent's call of one of that plugin's backend
## tools through the tool registry (caller "agent"), or a panel's through its
## broker or private channel (caller "panel"), never the host's own calls: a
## non-empty answer refuses the call with that message.
var _backend_tool_guards: Dictionary = {}

## Accumulated time since last health-check sweep.
var _health_timer_acc: float = 0.0

## Accumulated time since last file-watch sweep.
var _file_watch_acc: float = 0.0

## Per-plugin file modification time snapshots.
## Structure: { plugin_id: { file_path: modified_time_int } }
var _file_mtimes: Dictionary = {}

## Per-plugin debounce timers awaiting reload after a file change.
## Structure: { plugin_id: SceneTreeTimer }
## A non-null entry means a debounce is in flight for that plugin.
var _reload_pending: Dictionary = {}

## Per-plugin set of paths that changed during the current debounce window.
## Accumulated during file-watch scans; consumed (and cleared) when the debounce
## timer fires.  Structure: { plugin_id: Array[String] }
var _pending_changed_paths: Dictionary = {}

## Per-plugin live scene-panel registry for hot-reload.
## Maps plugin_id -> Array of Dictionaries:
##   { "panel_name": String, "tscn_path": String, "editor": Editor,
##     "vbox": Control, "root": Control }
## Populated when a PLUGIN_SCENE editor is opened; cleaned on close / stop.
## NOTE: Only PluginManager.gd writes to this; callers use the public API below.
var _live_scene_panels: Dictionary = {}

## plugin_id -> user-facing reason. GDScript's internal cache is path based;
## loading a second generation while old instances live can combine member
## layouts from different generations. Keep the old panels intact and expose
## an explicit restart requirement instead of mutating cached scripts in place.
var _restart_required: Dictionary = {}

## Runtime registry of plugin-supplied chat-provider entries (chat-passthrough
## W1). Held here (not on SingletonObject) so its lifecycle is bound to the
## manager; stop/crash signals drop the dead plugin's entries. Lazily created in
## _ready() (load() to avoid parse-order issues), exposed via
## get_chat_provider_registry().
var _chat_provider_registry = null  # PluginChatProviderRegistry

## plugin_id -> SetupPipeline instance, kept alive while S_BUILDING so its
## `finished`/`step_*` signals (already marshalled to the main thread via
## call_deferred — see SetupPipeline's THREADING CONTRACT) have somewhere to
## land. Erased once the pipeline reports its terminal result.
var _setup_pipelines: Dictionary = {}

## plugin_id -> the §2/§3 envelope for the plugin's current S_BUILD_FAILED /
## S_NEEDS_BINARY state. Persisted to `setup_state_path` (see below) so a
## half-built plugin reports honestly after a restart.
##
## Reuse note: PluginDefinition.to_dict()/from_dict() (the natural home for
## this) and PluginDB.gd's own persisted record are OUT of this round's scope
## fence, so this state rides in a small dedicated sidecar file instead —
## the same pattern ToolchainRegistry already uses for user://toolchain_paths.cfg
## (a standalone ConfigFile/JSON store owned by the class that needs it,
## rather than routing through the shared plugins.json). Flagged for the
## reviewer: folding this into PluginDefinition's own serialization would be
## the more conventional home if/when that file is back in scope.
var _setup_envelopes: Dictionary = {}

## Test seam: override to a scratch user:// path so tests never touch the
## real sidecar file. Empty default reads/writes DEFAULT_SETUP_STATE_PATH.
const DEFAULT_SETUP_STATE_PATH := "user://plugins/setup_state.json"
var setup_state_path: String = DEFAULT_SETUP_STATE_PATH

## Test seam: when set, called with no arguments to obtain a fresh
## SetupPipeline instance instead of `SetupPipeline.new()` — lets tests inject
## a pipeline whose `toolchain_registry` points at fixture search dirs instead
## of the real PATH/well-known install dirs.
var setup_pipeline_factory: Callable = Callable()

## Production seam (R3-UI, G4.1): SetupPipeline.approver — Callable(step:
## Dictionary, step_index: int) -> bool — applied to EVERY setup pipeline this
## manager starts (install or rebuild), unless a `setup_pipeline_factory`-
## injected pipeline already set its own `.approver` (tests do this; we never
## clobber it — see _start_setup_pipeline()). Left unset (default), SetupPipeline
## falls back to its own documented auto-approve-with-push_warning stub, i.e.
## zero behavior change for anyone who doesn't wire this. A UI embedder (e.g.
## PluginManagerPanel) sets this once to a Callable that shows a confirmation
## dialog and blocks the CALLING (worker) thread on the user's answer — see
## SetupPipeline.gd's APPROVAL SEAM doc for the marshalling contract.
var exec_approver: Callable = Callable()

## plugin_id -> {"step_index": int, "step_count": int, "step_type": String} for
## the setup pipeline CURRENTLY running (S_BUILDING only). Erased once the
## pipeline reaches a terminal state. Read via get_build_progress().
var _build_progress: Dictionary = {}

## plugin_id -> Array[String] of human-readable step/build log lines for the
## MOST RECENT setup-pipeline run (install or rebuild). Reset (not erased) at
## the start of each new run, so a plugin's last build log survives past the
## run's own terminal state — "Retain last build log per plugin" (G4.2).
## In-memory only (unlike _setup_envelopes, not persisted across restart —
## the envelope's own stderr_tail already covers the "what failed" case after
## a restart; the full step-by-step log is a live-session convenience).
var _build_logs: Dictionary = {}

## plugin_id set (Dictionary-as-set) of pipeline runs whose exec steps are
## being denied by the unattended FAIL-CLOSED default (review MF1): when no
## exec_approver is wired (headless / MCP-driven install, panel never opened),
## _start_setup_pipeline plugs a deny-all Callable into the pipeline's approver
## seam instead of letting SetupPipeline's auto-approve stub run arbitrary
## argv with zero confirmation (contract §1: exec REQUIRES explicit user
## confirmation). Tracked per run so _on_setup_pipeline_finished can rewrite
## the stored envelope's detail to "exec_denied_headless" — distinguishing
## "the machine had no way to ask" from a user actually clicking Cancel.
var _unattended_deny_ids: Dictionary = {}

## Marketplace installs; lives as long as this manager (PluginInstallQueue.gd).
var install_queue: Node = null
## What the startup recovery of unfinished installs could not undo:
## [{dir, id, reason}] (PluginInstallTransaction.recover_all).
var install_recovery_problems: Array = []
## reconcile_recovered is running, and was called again meanwhile.
var _draining := false
var _drain_again := false


# ---------------------------------------------------------------------------
# Lifecycle (Node)
# ---------------------------------------------------------------------------

func _ready() -> void:
	if _db == null:
		_db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	install_recovery_problems = MarketplaceClient.sweep_staging(_db)
	for problem in install_recovery_problems:
		push_error("[PluginManager] An unfinished plugin install needs attention: %s" % problem.reason)
		if SingletonObject and SingletonObject.has_method("create_toast_notification"):
			SingletonObject.call_deferred("create_toast_notification",
				"An unfinished plugin install needs attention: %s" % problem.reason, 1, false)
	install_queue = load("res://Scripts/Services/Plugins/PluginInstallQueue.gd").new()
	install_queue.manager = self
	add_child(install_queue)
	# Chat-provider registry (W1). Drop a plugin's entries when it stops/crashes
	# so dead providers vanish gracefully from the chooser.
	if _chat_provider_registry == null:
		_chat_provider_registry = load("res://Scripts/Services/Plugins/PluginChatProviderRegistry.gd").new()
	plugin_stopped.connect(_chat_provider_registry.drop_plugin)
	plugin_crashed.connect(_chat_provider_registry.drop_plugin)
	_load_setup_state()
	SingletonObject.verbose_log("[PluginManager] Ready — %d plugin(s) in DB" % _db.get_all().size())


## Return the PluginChatProviderRegistry (chat-passthrough W1). May be null if
## accessed before _ready().
func get_chat_provider_registry():
	return _chat_provider_registry


func _process(delta: float) -> void:
	_health_timer_acc += delta
	if _health_timer_acc >= HEALTH_CHECK_INTERVAL_SEC:
		_health_timer_acc = 0.0
		_run_health_checks()

	_file_watch_acc += delta
	if _file_watch_acc >= FILE_WATCH_INTERVAL_SEC:
		_file_watch_acc = 0.0
		_run_file_watch_checks()


# ---------------------------------------------------------------------------
# Public API — install / remove
# ---------------------------------------------------------------------------

## Parse a manifest.json, validate it, and register the plugin in the DB.
##
## If the manifest declares skills[] (DCR 019df57b), seed them into the user
## docket after the core install completes.  When auto_confirm_skills is false
## (default), a confirmation dialog is shown to the user before seeding; pass
## true for headless / programmatic flows that have already obtained consent.
##
## Returns {"ok": true, "id": "..."} on the no-skills path, or with extra keys
## on the skill-seeding path:
##   "skills_seeded": int — newly created records
##   "skills_skipped": int — already-installed pristine matches (idempotent re-install)
##   "skills_deferred_to_update": int — content changed; T4 reconciliation handles
##   "skills_declined": true — user cancelled the seed dialog (only when not auto-confirmed)
##
## `lane` selects the install lane (Docs/design/plugin-setup-pipeline.md §1):
## the default manifest/dev lane builds a declared `setup` stanza, while the
## marketplace lane verifies the shipped artifact instead of building. Only
## MarketplaceClient passes the marketplace lane.
##
## Returns {"error": "..."} on install failure.
func install_plugin(manifest_path: String, auto_confirm_skills: bool = false,
		lane: String = PluginDefinition.LANE_MANIFEST, consent: Dictionary = {}) -> Dictionary:
	var def = _db.install(manifest_path, lane)
	if def == null:
		# PluginDB.install already push_error'd; check for duplicate separately.
		var PluginDef = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
		var check_def = PluginDef.from_manifest(manifest_path, lane)
		if check_def != null and _db.has_plugin(check_def.id):
			return {"error": "Plugin '%s' is already installed" % check_def.id}
		return {"error": "Failed to install plugin from manifest: %s" % manifest_path}

	_ensure_runtime(def.id)

	# Auto-create plugin data directory and declared filesystem paths
	var create_result := _create_plugin_directories(def)
	if create_result.has("error"):
		# Don't fail the install, but log a warning
		push_warning("[PluginManager] Warning creating directories for '%s': %s" % [def.id, create_result["error"]])

	# Default-grant declared capabilities (except privilege-escalation ones).
	# Install is the trust act; per-capability opt-in is friction the user
	# can reverse later by revoking specific caps. A required plugin's grants
	# can predate its record (an older Minerva shipped it built in); those
	# decisions, revocations included, are kept.
	if not (RequiredPlugins.has(def.id) and _policy_ref != null and _policy_ref._grants.has(def.id)):
		_auto_grant_declared_capabilities(def)

	print("[PluginManager] Registered plugin manifest '%s' v%s" % [def.id, def.version])
	_register_manifest_tools(def.id)

	var result: Dictionary = {"ok": true, "id": def.id}

	# Manifest-install setup pipeline (DCR 019f69428fa0 §3, always-build rule).
	# A manifest with no `setup` stanza behaves exactly as before this round —
	# def.state stays S_INSTALLED and nothing below runs. When a stanza IS
	# declared, this is the ONLY place that flips the plugin into S_BUILDING;
	# the pipeline runs on a worker thread and reports back asynchronously via
	# _on_setup_pipeline_finished, so install_plugin() itself returns without
	# blocking on the build (contract: UI thread must never be blocked).
	#
	# ...on the manifest/dev lane only. The marketplace lane installs the same
	# manifest.json out of a release tarball, where the source the stanza would
	# build was never packaged (§1 lane split): building there would fail on a
	# plugin whose binary is sitting right next to the manifest. That lane
	# verifies the shipped artifact instead — the check §1/C6 reserved
	# S_NEEDS_BINARY for.
	if def.install_lane == PluginDefinition.LANE_MARKETPLACE:
		result.merge(_verify_release_artifact(def))
	elif not def.setup.is_empty():
		_start_setup_pipeline(def.id)
		result["building"] = true

	# Skill and knowledge seeding (DCR 019df57b T3).
	if not def.skills.is_empty() or not def.knowledge.is_empty():
		result.merge(await Seeding.seed_install(self, def, auto_confirm_skills, consent))

	# Cross-plugin reactivity (DCR 019df57b T7).  This plugin's declared tools
	# are now part of the "available" set; any pre-existing skill whose
	# unsatisfied_deps included one of those tools should re-resolve.
	result.merge(await Seeding.recompute_reactivity(self))
	return result


## Create plugin data directories. Called on successful install.
## Creates user://plugins/data/<plugin_id>/ and any declared filesystem_paths.
## Returns {"ok": true} or {"error": "..."}.
func _create_plugin_directories(def) -> Dictionary:  # def: PluginDefinition
	# Create base plugin data directory
	var base_dir := "user://plugins/data".path_join(def.id)
	var err := DirAccess.make_dir_recursive_absolute(base_dir)
	if err != OK:
		return {"error": "Failed to create plugin data directory '%s': %s" % [base_dir, error_string(err)]}

	print("[PluginManager] Created plugin data directory: %s" % base_dir)

	# Create any declared filesystem_paths
	if def.filesystem_mode == "scoped_paths":
		for path in def.filesystem_paths:
			# Expand user:// to absolute path
			var abs_path: String = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
			err = DirAccess.make_dir_recursive_absolute(abs_path)
			if err != OK:
				# Log but don't fail — plugin might use paths conditionally
				push_warning("[PluginManager] Could not create filesystem path '%s' for plugin '%s': %s" % [path, def.id, error_string(err)])
			else:
				print("[PluginManager] Created filesystem path: %s" % abs_path)

	return {"ok": true}


## Re-install (upgrade) an already-installed plugin from a new manifest version,
## reconciling its skills and knowledge (PluginContentSeeding.reconcile; a
## customised record asks, or takes auto_confirm_updates for headless/MCP
## flows).
##
## Returns:
##   {"ok": true, "id": "...", "reconcile": {...counts...}, ...}
##   {"error": "..."}
func update_plugin(manifest_path: String, auto_confirm_updates: bool = false,
		lane: String = PluginDefinition.LANE_MANIFEST, consent: Dictionary = {}) -> Dictionary:
	var PluginDef = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var def = PluginDef.from_manifest(manifest_path, lane)
	if def == null:
		return {"error": "Failed to parse manifest: %s" % manifest_path}
	if not _db.has_plugin(def.id):
		return {"error": "Plugin '%s' not installed; use install_plugin first" % def.id}
	var previous_def = _db.get_by_id(def.id)
	def.autostart = previous_def.autostart
	def.auto_reload = previous_def.auto_reload
	def.auto_update = previous_def.auto_update
	def.install_lane = lane

	if not _db.update_definition(def):
		return {"error": "Failed to update plugin definition for '%s'" % def.id}

	_register_manifest_tools(def.id)

	var result: Dictionary = {"ok": true, "id": def.id}
	result.merge(await Seeding.reconcile(self, previous_def, def, consent, auto_confirm_updates))
	return result


## Put the Docket content of `attempted_def`'s plugin back in line with what
## is installed after its update was rolled back, restoring the customised
## records in `journal` (PluginInstallTransaction.CONTENT_PENDING).
func reconcile_after_rollback(attempted_def, journal: Dictionary = {}) -> Dictionary:
	if _db.has_plugin(attempted_def.id):
		_register_manifest_tools(attempted_def.id)
	return await Seeding.reconcile_after_rollback(self, attempted_def, journal)


## Bring Docket in line with every install that has ended
## (PluginInstallTransaction.content_pending): one that committed keeps its
## content (PluginContentSeeding.content_committed); one that was undone is
## reconciled with the definition it had applied, as saved in its journal. Each is dequeued
## once its repair completed; one that did not keeps only the journal entries
## still to put back, so a retry never rewrites text put back before. Nothing
## is done while Docket is not available; a call during a drain makes that
## drain pass again and returns when it ends.
func reconcile_recovered() -> void:
	if not Seeding.docket().unavailable().is_empty():
		return
	if _draining:
		_drain_again = true
		await content_drained
		return
	_draining = true
	var Txn = load("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
	_drain_again = true
	while _drain_again:
		_drain_again = false
		for recovered in Txn.content_pending(ProjectSettings.globalize_path(MarketplaceClient.STAGING_DIR)):
			var journal: Dictionary = recovered.journal
			var attempted = PluginDefinition.from_dict(journal.attempted) if journal.get("attempted") is Dictionary \
				else _db.get_by_id(recovered.id)
			var done := true
			var reason := ""
			if recovered.committed:
				reason = await Seeding.content_committed_problem(journal)
				done = reason.is_empty()
			else:
				var result: Dictionary
				if attempted != null:
					result = await reconcile_after_rollback(attempted, journal)
				else:
					var operation := Seeding.docket()
					await operation.pin(journal, [""])
					result = await Seeding.unseed(self, recovered.id, operation)
				done = Seeding.complete(result)
				journal["entries"] = result.get("journal_left", journal.get("entries", []))
				reason = Seeding.unfinished_reason(result)
			if done:
				Txn.content_done(recovered.path)
			elif not Txn.requeue_content(recovered.path, recovered.id, journal, recovered.committed, reason):
				push_error("[PluginManager] '%s''s unfinished Docket repair could not be narrowed in %s; its next retry judges all its saved text again" % [
					recovered.id, recovered.path])
	_draining = false
	content_drained.emit()


## See PluginSkillConsent.collect.
func collect_skill_consent(manifest_path: String, auto_confirm: bool, op = null) -> Dictionary:
	return await SkillConsent.collect(self, _db, Seeding.available_tools(self), Seeding.docket(),
		manifest_path, auto_confirm, op)


## Stop the plugin if running, then remove it from the DB.
## If delete_data is true, also remove the plugin's data directory.
## Returns {"ok": true} or {"error": "..."}.
func remove_plugin(id: String, delete_data: bool = false) -> Dictionary:
	if RequiredPlugins.has(id):
		return {"error": "%s is required by Minerva and cannot be removed; you can stop it, or turn its Auto-start off" % RequiredPlugins.display_name(id)}
	if not _db.has_plugin(id):
		return {"error": "Plugin '%s' not found" % id}

	var def = _db.get_by_id(id)

	# Setup-pipeline guard (review MF1): while S_BUILDING, _setup_pipelines
	# holds the manager's ONLY strong reference to the RefCounted SetupPipeline
	# whose worker thread is still executing (its bound Callables hold ObjectIDs,
	# not refs) — erasing it mid-build is a use-after-free plus a "Thread
	# destroyed while running" abort, and delete_data would rm the plugin dir
	# out from under a live build subprocess. Refuse, mirroring the
	# running-plugin convention below (this early return also covers the
	# delete_data branch further down).
	if def.state == S_BUILDING:
		return {"error": "Plugin '%s' is still building — wait for the setup pipeline to finish before removing" % id}

	# The staging lock is held until the removal is saved, so no install
	# replaces this plugin meanwhile. Its unfinished installs are marked
	# first, so recovery after a crash does not bring it back once removed,
	# and are dropped only once the record is gone from disk. Only stopping
	# the plugin happens before that.
	if _db.is_stale():
		return {"error": "Another Minerva changed the plugin list; restart Minerva before removing '%s'" % id}
	var Transaction = load("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")
	var staging_root := ProjectSettings.globalize_path(MarketplaceClient.STAGING_DIR)
	var removal: Dictionary = Transaction.begin_removal(staging_root, id)
	if removal.has("error"):
		return {"error": removal.error}
	if def.state in [S_RUNNING, S_STARTING]:
		var stop_result := stop_plugin(id)
		if stop_result.get("error"):
			Transaction.end_removal(staging_root, id, removal, false)
			return {"error": "Could not stop plugin before removal: %s" % stop_result.get("error")}
	var removed: bool = _db.remove(id)
	Transaction.end_removal(staging_root, id, removal, removed)
	if not removed:
		return {"error": "Failed to remove plugin '%s' from DB" % id}


	_runtime.erase(id)
	_setup_pipelines.erase(id)
	_build_progress.erase(id)
	_build_logs.erase(id)
	_unattended_deny_ids.erase(id)
	if _setup_envelopes.erase(id):
		_save_setup_state()

	# Clean up data directory if requested
	if delete_data:
		var data_dir := "user://plugins/data".path_join(id)
		var err := _delete_directory_recursive(data_dir)
		if err != OK:
			push_warning("[PluginManager] Could not delete data directory for '%s': %s" % [id, error_string(err)])
		else:
			print("[PluginManager] Deleted plugin data directory: %s" % data_dir)

	print("[PluginManager] Removed plugin '%s'" % id)

	# Unseed plugin-shipped skills and knowledge (pristine records deleted,
	# customised ones kept as the user's), then recompute skill reactivity.
	# Runs AFTER _db.remove so the uninstalled plugin's tools are no longer
	# counted as available.
	var result: Dictionary = {"ok": true}
	# The plugin's knowledge project is reached by its name now, and recorded
	# for a retry even while it is not open.
	var removal_docket := Seeding.docket()
	if def != null and not def.knowledge.is_empty():
		await removal_docket.has_project(def.knowledge_project)
	result.merge(await Seeding.unseed(self, id, removal_docket))
	# Content that could not all be removed is cleaned up by reconcile_recovered.
	# It records where it reached them, and at least the names of the master and
	# the knowledge project, so its retry reaches no other project.
	var cleanup_paths: Dictionary = result.get("content_paths", {}).duplicate()
	for name in ["" if def == null or def.knowledge.is_empty() else def.knowledge_project, ""]:
		if not cleanup_paths.has("" if name == "master" else name):
			cleanup_paths["" if name == "master" else name] = ""
	if not Seeding.complete(result) and not Transaction.queue_cleanup(staging_root, id,
			{"paths": cleanup_paths}, Seeding.unfinished_reason(result)):
		push_error("[PluginManager] '%s''s leftover Docket content could not be queued for cleanup" % id)
	return result


# ---------------------------------------------------------------------------
# Public API — start / stop / restart
# ---------------------------------------------------------------------------

## Start a plugin: create MCPServerConnection, configure stdio, connect.
## State transitions: INSTALLED/STOPPED/ERROR → STARTING → RUNNING or ERROR.
## Returns {"ok": true} or {"error": "..."}. The first start after an update
## installed while the plugin was stopped commits that update, or rolls it
## back and starts the previous version, and an update left unfinished is
## undone first (PluginPendingUpgrade). `in_transaction` is only for the
## install that is replacing the plugin and holds the staging lock.
func start_plugin(id: String, in_transaction: bool = false) -> Dictionary:
	# Refused before PluginPendingUpgrade, which would take a refusal for a
	# failed first start and roll a pending update back.
	if id == "voice" and not load("res://Scripts/Services/Voice/VoiceFeatureControl.gd").is_enabled():
		return {"error": "Voice Support is disabled in Preferences", "disabled": true}
	if in_transaction:
		return await _start_plugin_now(id)
	return await PendingUpgrade.start(self, id, _start_plugin_now.bind(id))


func _start_plugin_now(id: String) -> Dictionary:
	if _shutting_down:
		return {"error": "Minerva is shutting down — refusing to start plugin '%s'" % id}

	var def = _db.get_by_id(id)
	if def == null:
		return {"error": RequiredPlugins.missing_message(id) if RequiredPlugins.has(id) else "Plugin '%s' not found" % id}
	if RequiredPlugins.has(id):
		var runtime_issue := RequiredPlugins.runtime_issue(def)
		if not runtime_issue.is_empty():
			return {"error": RequiredPlugins.missing_message(id, runtime_issue)}

	if def.state == S_RUNNING:
		return {"error": "Plugin '%s' is already running" % id}

	if def.state == S_STARTING:
		return {"error": "Plugin '%s' is already starting" % id}

	if def.state == S_CRASH_LOOP:
		return {"error": "Plugin '%s' is in crash-loop — reset it first" % id}

	# Setup-pipeline gate (DCR 019f69428fa0 §3): a plugin that is still
	# building, or that failed to build, has no verified runnable artifact —
	# refusing here is what makes the old "binary not found" failure below
	# (originally ~line 549) unreachable for a manifest install with a
	# `setup` stanza: by the time a plugin can reach S_INSTALLED with a
	# stanza declared, SetupPipeline has already verified the entrypoint
	# artifact exists.
	if def.state == S_BUILDING:
		return {"error": "Plugin '%s' is still building — wait for the setup pipeline to finish" % id}
	if def.state == S_BUILD_FAILED or def.state == S_NEEDS_BINARY:
		# The repair differs per lane: dev installs rebuild, marketplace
		# installs reinstall (rebuild() refuses them — there is no source).
		if def.install_lane == PluginDefinition.LANE_MARKETPLACE:
			return {"error": "Plugin '%s' has no usable binary for this platform (state=%d) — reinstall or update it from the marketplace" % [id, def.state]}
		return {"error": "Plugin '%s' has not been built successfully (state=%d) — call rebuild() first" % [id, def.state]}

	# Merge persisted runtime scope grants into def.filesystem_paths so all
	# host.files.* validators see user-approved paths from prior sessions.
	var GrantsClass = load("res://Scripts/Services/Plugins/PluginScopeGrants.gd")
	if GrantsClass != null:
		var grants_store = GrantsClass.new()
		for granted_path in grants_store.get_granted_paths(def.id):
			if granted_path not in def.filesystem_paths:
				def.filesystem_paths.append(granted_path)

	# One-time migration for plugins installed before default-grant landed:
	# if the policy has no entry at all for this plugin (not even an empty list),
	# treat as "freshly installed" and auto-grant declared caps. An empty list
	# means the user explicitly revoked everything — leave it alone.
	if _policy_ref != null and not _policy_ref._grants.has(def.id):
		_auto_grant_declared_capabilities(def)

	RequiredPlugins.prepare_launch(def)

	# Clean up any leftover connection from a previous run.
	_cleanup_connection(id)

	_transition_state(id, S_STARTING)

	# Build command + args from the manifest.
	# SubProcess doesn't support chdir, so resolve relative script paths to
	# absolute paths based on the plugin's data_directory.
	var command: String = def.entrypoint
	# Always globalize: marketplace-installed plugins have data_directory =
	# "user://plugins/<id>" and side-loaded plugins have an OS-absolute path.
	# SubProcess (fork+exec) needs a real filesystem path either way; an
	# unresolved user:// or res:// scheme passed to OS.execute fails with
	# ERR_CANT_CONNECT even though FileAccess.file_exists() understands it.
	var plugin_dir: String = ProjectSettings.globalize_path(def.data_directory)

	# Resolve relative entrypoint (e.g., "./obs_controller") to absolute path.
	# This is needed for Go binaries and other executables without file extensions,
	# since the args resolution loop below only handles .py/.js/.sh/.gd files.
	if command.begins_with("./"):
		var abs_command: String = plugin_dir.path_join(command.substr(2))
		if FileAccess.file_exists(abs_command) or FileAccess.file_exists(ProjectSettings.localize_path(abs_command)):
			command = abs_command
		elif OS.get_name() == "Windows" and (FileAccess.file_exists(abs_command + ".exe") or FileAccess.file_exists(ProjectSettings.localize_path(abs_command + ".exe"))):
			# Windows builds carry a .exe suffix that the cross-platform manifest
			# entrypoint omits (e.g. manifest says "./drive-plugin" but the
			# packaged binary is "drive-plugin.exe"). Resolve the suffix here so
			# plugins don't need a Windows-specific manifest.
			command = abs_command + ".exe"
		else:
			# Binary not found — plugin probably wasn't compiled for this platform.
			# Fail early so the UI shows "error" with a clear message instead of
			# letting the OS-level spawn failure take down the subprocess API.
			var msg := "Plugin binary not found at '%s'. This plugin needs to be compiled for %s." % [abs_command, OS.get_name()]
			push_error("[PluginManager] " + msg)
			_cleanup_connection(id)
			_transition_state(id, S_ERROR)
			return {"error": msg}

	var resolved_args: PackedStringArray = PackedStringArray()
	for arg in def.args:
		if arg.ends_with(".py") or arg.ends_with(".js") or arg.ends_with(".sh") or arg.ends_with(".gd"):
			# Resolve script path relative to plugin directory
			var full_path: String = plugin_dir.path_join(arg)
			if FileAccess.file_exists(full_path) or FileAccess.file_exists(ProjectSettings.localize_path(full_path)):
				resolved_args.append(full_path)
			else:
				resolved_args.append(arg)
		else:
			resolved_args.append(arg)

	# Create and configure the connection.
	var conn := MCPServerConnection.new(def.id, "", MCPServerConnection.TransportType.STDIO)
	conn.configure_stdio(command, resolved_args)

	# Tag the connection with the plugin id so _stdio_request can pass it to the handler.
	conn.plugin_id = id

	# Wire bidirectional capability request handler so the plugin can call
	# Minerva tools mid-execution via minerva/capability on stdout.
	var broker = _get_capability_broker()
	if broker != null:
		conn.capability_request_handler = func(p_id: String, capability: String, args: Dictionary) -> Dictionary:
			return await broker.dispatch(p_id, capability, args)
	else:
		push_warning("[PluginManager] No CapabilityBroker available — plugin '%s' cannot use bidirectional capabilities" % id)

	# Set event broker reference for async event/state routing
	var event_broker_ref = _get_event_broker()
	if event_broker_ref != null:
		conn.event_broker = event_broker_ref

	var rt := _ensure_runtime(id)
	rt["connection"] = conn
	# A backend that serves its panel's edits privately gets a secret of its
	# own for each process it runs.
	rt["panel_authority"] = null
	if not def.panel_authority.is_empty():
		var authority := PluginPanelAuthority.new(id, conn, def.panel_authority)
		authority.tool_guard = func(tool: String, arguments: Dictionary) -> String:
			return await check_backend_tool(id, tool, arguments, "panel")
		authority.tool_called = func(tool: String) -> void: backend_tool_called.emit(id, tool)
		conn.stdio_env_for_generation = authority.env_for_generation
		rt["panel_authority"] = authority
	rt["start_time"] = Time.get_unix_time_from_system()
	rt["stopping"] = false

	# Connect liveness signals so we can react to disconnects.
	if not conn.disconnected.is_connected(_on_plugin_disconnected.bind(id)):
		conn.disconnected.connect(_on_plugin_disconnected.bind(id))

	SingletonObject.verbose_log("[PluginManager] Starting plugin id=%s transport=stdio" % id)

	var err: Error = await conn.connect_to_server()
	if not _owns_runtime_connection(id, conn):
		return {"error": "Plugin '%s' start was cancelled" % id}

	if err != OK:
		var failure_reason: String = conn.last_failure_reason
		if failure_reason.is_empty():
			failure_reason = "Subprocess failed to start: %s" % error_string(err)
		push_error("[PluginManager] Failed to start plugin '%s': %s" % [id, failure_reason])
		_cleanup_connection(id)
		_transition_state(id, S_ERROR)
		return {"error": failure_reason}

	_transition_state(id, S_RUNNING)

	# Defensive: ensure the connection's single stdout reader is wired.
	# connect_to_server() already does this for STDIO; the is_connected guard
	# makes this a harmless no-op when it is already connected.
	if conn._subprocess and not conn._subprocess.output_ready.is_connected(conn._drain_stdout):
		conn._subprocess.output_ready.connect(conn._drain_stdout)

	plugin_started.emit(id)
	SingletonObject.verbose_log("[PluginManager] Plugin '%s' is RUNNING" % id)

	# Dynamic tool discovery: query the backend's tools/list and register the
	# results into PluginToolRegistry with the auto-prefix policy (Option B).
	# Awaited so callers observe a fully-registered tool surface when
	# start_plugin() returns — no race window where the plugin is RUNNING but
	# its tools aren't yet callable. plugin_started fires before discovery so
	# any manifest-declared tools (registered by on_plugin_started) land first;
	# backend discovery then supersedes them via the registry's purge-and-emit
	# path.
	await _discover_backend_tools(id, conn)
	if not _owns_runtime_connection(id, conn):
		return {"error": "Plugin '%s' start was cancelled" % id}
	if RequiredPlugins.has(id):
		# Untyped: a check that stops on a script error yields null, which must
		# refuse the start rather than pass as "no issue".
		var checked = await RequiredPlugins.host_tools_missing(def, conn)
		if not _owns_runtime_connection(id, conn):
			return {"error": "Plugin '%s' start was cancelled" % id}
		var contract_issue: String = checked if checked is String \
			else "%s %s's tool check failed; it was stopped." % [RequiredPlugins.display_name(id), def.version]
		if not contract_issue.is_empty():
			push_error("[PluginManager] %s" % contract_issue)
			stop_plugin(id)
			_transition_state(id, S_ERROR)
			return {"error": contract_issue}

	plugin_ready.emit(id)
	return {"ok": true}


## Sets (or, given an invalid Callable, clears) plugin `id`'s guard of its
## backend tools (see _backend_tool_guards).
func set_backend_tool_guard(id: String, guard: Callable) -> void:
	if guard.is_valid():
		_backend_tool_guards[id] = guard
	else:
		_backend_tool_guards.erase(id)


## "" when a call of backend tool `tool` of plugin `id` with `arguments` by
## `caller` ("agent" or "panel") may go, else why it may not. A
## `write_binding` (MinervaMCPServer.call_tool) is handed to the guard with
## this call only.
func check_backend_tool(id: String, tool: String, arguments: Dictionary, caller: String = "agent",
		write_binding: Dictionary = {}) -> String:
	var guard: Callable = _backend_tool_guards.get(id, Callable())
	if not guard.is_valid():
		return "" if write_binding.is_empty() else "no guard holds this write to its target, so it is not sent"
	var answer
	if write_binding.is_empty():
		answer = await guard.call(tool, arguments, caller)
	else:
		answer = await guard.call(tool, arguments, caller, write_binding)
	return answer if answer is String else "the host could not check the call of %s" % tool


func _owns_runtime_connection(id: String, connection) -> bool:
	var rt: Dictionary = _runtime.get(id, {})
	return rt.get("connection") == connection and not rt.get("stopping", false)


## Discover and register the plugin backend's tools.
## Awaited from start_plugin() so the plugin's tools are callable as soon as
## start_plugin() returns. Reviewer (cycle round 1) flagged the original
## fire-and-forget shape as a race; this is the resolution.
## conn is MCPServerConnection (untyped to avoid parse-order dependency).
func _discover_backend_tools(plugin_id: String, conn) -> void:
	# Resolve tool registry via SingletonObject (avoids circular dep at parse time).
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
	if so == null:
		push_warning("[PluginManager] SingletonObject not in scene tree; skipping backend tool discovery for '%s'" % plugin_id)
		return
	var registry = so.get("plugin_tool_registry") if "plugin_tool_registry" in so else null
	if registry == null:
		push_warning("[PluginManager] plugin_tool_registry not available; skipping backend tool discovery for '%s'" % plugin_id)
		return
	var result: Dictionary = await registry.register_backend_tools(plugin_id, conn)
	if result.get("error"):
		push_warning("[PluginManager] Backend tool discovery for '%s' failed: %s" % [
			plugin_id, result.get("error")
		])
	elif result.get("skipped"):
		SingletonObject.verbose_log("[PluginManager] Backend tool discovery skipped for '%s': %s" % [
			plugin_id, result.get("skipped")
		])
	else:
		SingletonObject.verbose_log("[PluginManager] Backend tool discovery for '%s': %d tool(s) registered" % [
			plugin_id, result.get("registered", []).size()
		])
		var publish_callback := _on_plugin_catalog_committed.bind(plugin_id, conn)
		if not conn.catalog_committed.is_connected(publish_callback):
			conn.catalog_committed.connect(publish_callback)
		conn.start_tool_catalog_watch()


func _on_plugin_catalog_committed(plugin_id: String, conn) -> void:
	if get_connection(plugin_id) != conn:
		return
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") \
		if Engine.get_main_loop() else null
	var registry = so.get("plugin_tool_registry") \
		if so != null and "plugin_tool_registry" in so else null
	if registry == null or not registry.has_method("publish_backend_tools"):
		return
	var result: Dictionary = registry.publish_backend_tools(plugin_id, conn)
	if result.get("error"):
		push_warning("[PluginManager] Catalog publication for '%s' failed: %s" % [
			plugin_id, result.get("error")])


## Synchronize a changed manifest with the plugin's current lifecycle state.
## Installed panel tools are host-owned; backend tools require a running
## subprocess and must not be advertised merely because a manifest is present.
func _register_manifest_tools(plugin_id: String) -> void:
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
	if so == null:
		return
	var registry = so.get("plugin_tool_registry") if "plugin_tool_registry" in so else null
	if registry == null or not registry.has_method("sync_manifest_tools"):
		return
	var def = _db.get_by_id(plugin_id)
	if def == null:
		return
	var result: Dictionary = registry.sync_manifest_tools(
		plugin_id, def.state == S_RUNNING)
	if result.get("error"):
		push_error("[PluginManager] Manifest tool sync failed for '%s': %s" % [
			plugin_id, result.get("error")])


## Stop a running plugin cleanly.
## Returns {"ok": true} or {"error": "..."}.
func stop_plugin(id: String, by_person: bool = false) -> Dictionary:
	var def = _db.get_by_id(id)
	if def == null:
		return {"error": "Plugin '%s' not found" % id}
	if by_person:
		_person_stops[id] = person_stops(id) + 1

	if def.state == S_STOPPED:
		return {"ok": true}  # Already stopped, idempotent.

	var rt := _ensure_runtime(id)
	if rt.get("stopping", false):
		return {"ok": true}  # Re-entrant call during async stop — ignore.
	rt["stopping"] = true

	# Cancel any pending hot-reload debounce to prevent stale restart
	_reload_pending.erase(id)
	_pending_changed_paths.erase(id)

	SingletonObject.verbose_log("[PluginManager] Stopping plugin '%s'..." % id)

	_cleanup_connection(id)
	_transition_state(id, S_STOPPED)
	rt["stopping"] = false
	rt["start_time"] = 0.0

	plugin_stopped.emit(id)
	SingletonObject.verbose_log("[PluginManager] Plugin '%s' STOPPED" % id)
	return {"ok": true}


## Stop and then start a plugin.
## Returns {"ok": true} or {"error": "..."}.
func restart_plugin(id: String) -> Dictionary:
	if not _db.has_plugin(id):
		return {"error": "Plugin '%s' not found" % id}

	SingletonObject.verbose_log("[PluginManager] Restarting plugin '%s'..." % id)

	var stop_result := stop_plugin(id)
	if stop_result.get("error"):
		return {"error": "Restart failed during stop: %s" % stop_result.get("error")}

	# Small yield so the subprocess OS handle is fully released before we
	# respawn — not strictly necessary but avoids port/pipe races.
	await Engine.get_main_loop().create_timer(0.2).timeout

	return await start_plugin(id)


# ---------------------------------------------------------------------------
# Public API — manifest-install setup pipeline (DCR 019f69428fa0 §3)
# ---------------------------------------------------------------------------

## Re-run preflight + the setup pipeline for a plugin currently parked in
## S_BUILD_FAILED or S_NEEDS_BINARY (contract §3: "Rebuild = preflight +
## pipeline rerun"). Returns immediately; the outcome arrives asynchronously
## via _on_setup_pipeline_finished, same as install_plugin()'s kickoff.
func rebuild(id: String) -> Dictionary:
	var def = _db.get_by_id(id)
	if def == null:
		return {"error": "Plugin '%s' not found" % id}
	if def.state != S_BUILD_FAILED and def.state != S_NEEDS_BINARY:
		return {"error": "Plugin '%s' is not in a rebuildable state (state=%d)" % [id, def.state]}
	# Rebuild means "run the producer again", which only the manifest/dev lane
	# has. A marketplace plugin's producer ran on the publisher's machine; the
	# user-side repair is a reinstall/update, not a build.
	if def.install_lane == PluginDefinition.LANE_MARKETPLACE:
		return {"error": "rebuild_unavailable_marketplace: plugin '%s' was installed from a release artifact — reinstall or update it from the marketplace instead" % id}
	if def.setup.is_empty():
		return {"error": "Plugin '%s' has no setup stanza to rebuild" % id}
	_start_setup_pipeline(id)
	return {"ok": true, "id": id, "building": true}


## The current §2/§3 envelope for a plugin in S_BUILD_FAILED / S_NEEDS_BINARY,
## or {} if the plugin has no recorded envelope (never built, or built clean).
func get_setup_envelope(id: String) -> Dictionary:
	return _setup_envelopes.get(id, {})


## Live step position while `id` is S_BUILDING, or {} if it isn't currently
## building. Shape: {"step_index": int, "step_count": int, "step_type": String}.
## Signal-driven consumers (PluginManagerPanel, MCP) should prefer
## plugin_build_step_started/plugin_build_step_finished for push updates; this
## getter exists for the initial snapshot (e.g. MCP polling a state query) and
## for a UI attaching mid-build.
func get_build_progress(id: String) -> Dictionary:
	return _build_progress.get(id, {}).duplicate()


## The step-by-step log lines for `id`'s most recent setup-pipeline run
## (install or rebuild), retained until the NEXT run starts. [] if `id` has
## never run a setup pipeline this session.
func get_build_log(id: String) -> Array:
	return (_build_logs.get(id, []) as Array).duplicate()


## Marketplace-lane counterpart to _start_setup_pipeline(): the release tarball
## already contains the producer's output, so instead of building we verify the
## artifact the manifest's entrypoint names actually landed.
##
## Present  -> {} (plugin stays S_INSTALLED, exactly as before this change).
## Absent   -> S_NEEDS_BINARY + a `plugin_binary_missing` envelope, which is
##             what §1/C6 reserved that state for: "installed but no runnable
##             artifact for this platform and no setup lane available."
##             Without this, the failure surfaced much later as a raw spawn
##             error the first time the user tried to start the plugin.
func _verify_release_artifact(def) -> Dictionary:
	if not def.setup.is_empty():
		# Not an error: the same manifest.json serves both lanes. Say it once
		# so a publisher reading the log knows the stanza was seen and skipped.
		print(("[PluginManager] '%s' installed from a release artifact — its `setup` " +
			"stanza is inert on this lane (no source tree to build from)") % def.id)

	# A PATH-resolved entrypoint ("python3") names no packaged file; start_plugin
	# resolves it at launch. Only a "./"-relative entrypoint has an artifact.
	if not def.entrypoint.begins_with("./"):
		return {}

	var plugin_dir: String = ProjectSettings.globalize_path(def.data_directory)
	var artifact_abs: String = plugin_dir.path_join(def.entrypoint.substr(2))
	if _artifact_exists(artifact_abs):
		return {}

	var envelope := {
		"error": "plugin_binary_missing",
		"plugin_id": def.id,
		"lane": PluginDefinition.LANE_MARKETPLACE,
		"entrypoint": def.entrypoint,
		"expected_path": artifact_abs,
		"platform": OS.get_name(),
		"install_hint": ("This release did not include a %s build of the plugin binary. " +
			"Reinstall from the marketplace once a build for this platform is published.") % OS.get_name(),
	}
	_setup_envelopes[def.id] = envelope
	_transition_state(def.id, S_NEEDS_BINARY)
	_save_setup_state()
	push_warning("[PluginManager] '%s' installed but its binary is missing: %s" % [def.id, artifact_abs])
	return {"needs_binary": true, "envelope": envelope}


## Does the entrypoint artifact exist at `abs_path`? Mirrors start_plugin()'s
## own resolution, including the Windows ".exe" suffix a cross-platform manifest
## entrypoint omits — otherwise every Windows release would verify as missing.
func _artifact_exists(abs_path: String) -> bool:
	if FileAccess.file_exists(abs_path) or FileAccess.file_exists(ProjectSettings.localize_path(abs_path)):
		return true
	if OS.get_name() == "Windows":
		return (FileAccess.file_exists(abs_path + ".exe")
			or FileAccess.file_exists(ProjectSettings.localize_path(abs_path + ".exe")))
	return false


## Build + start a SetupPipeline for `id`, transition to S_BUILDING, and wire
## its terminal signal back to _on_setup_pipeline_finished. Shared by
## install_plugin() and rebuild().
func _start_setup_pipeline(id: String) -> void:
	var def = _db.get_by_id(id)
	if def == null:
		return

	_transition_state(id, S_BUILDING)

	var plugin_dir: String = ProjectSettings.globalize_path(def.data_directory)
	# Mirrors start_plugin()'s own "./"-relative entrypoint resolution: only a
	# relative-to-plugin-dir entrypoint has an artifact SetupPipeline can
	# verify; a bare interpreter invocation (e.g. "python3") has nothing to
	# check here (it's resolved against PATH at start_plugin() time, not built).
	var entrypoint_artifact: String = ""
	if def.entrypoint.begins_with("./"):
		entrypoint_artifact = def.entrypoint.substr(2)

	var pipeline: SetupPipeline = setup_pipeline_factory.call() if setup_pipeline_factory.is_valid() else SetupPipeline.new()
	# Never clobber an approver a test already wired up via setup_pipeline_factory;
	# otherwise apply the production seam (see `exec_approver`'s own doc) —
	# and when NO approver is wired at all, FAIL CLOSED (review MF1): plug a
	# deny-all Callable into the seam rather than letting SetupPipeline's
	# auto-approve stub run arbitrary exec argv with zero confirmation on a
	# headless / MCP-driven install (contract §1). The deny default lives HERE,
	# per-pipeline, never in the exec_approver field itself — the UI's
	# "claim the seam only if unclaimed" guard checks that field's validity.
	_unattended_deny_ids.erase(id)
	var unattended := false
	if not pipeline.approver.is_valid():
		if exec_approver.is_valid():
			pipeline.approver = exec_approver
		else:
			unattended = true
			_unattended_deny_ids[id] = true
			pipeline.approver = func(_step: Dictionary, _step_index: int) -> bool: return false
	_setup_pipelines[id] = pipeline
	_build_progress.erase(id)
	_build_logs[id] = []
	var steps_arr: Array = def.setup.get("steps", [])
	var step_count: int = steps_arr.size()
	_append_build_log(id, "build started (%d step%s)" % [step_count, "" if step_count == 1 else "s"])
	if unattended:
		var has_exec := false
		for s in steps_arr:
			if s is Dictionary and str(s.get("type", "")) == "exec":
				has_exec = true
				break
		if has_exec:
			_append_build_log(id, "no exec approver wired — exec steps will be DENIED (unattended fail-closed default; open the Plugin Manager panel and Rebuild to approve interactively)")
	pipeline.step_started.connect(_on_pipeline_step_started.bind(id))
	pipeline.step_finished.connect(_on_pipeline_step_finished.bind(id))
	pipeline.finished.connect(_on_setup_pipeline_finished.bind(id))
	pipeline.run_async(id, def.setup, plugin_dir, entrypoint_artifact)


## SetupPipeline.step_started re-broadcast with `id` correlated in (bound at
## connect time in _start_setup_pipeline — always called on the main thread,
## per SetupPipeline's own THREADING CONTRACT).
func _on_pipeline_step_started(step_index: int, step_type: String, id: String) -> void:
	var def = _db.get_by_id(id)
	var step_count: int = (def.setup.get("steps", []) as Array).size() if def != null else 0
	_build_progress[id] = {"step_index": step_index, "step_count": step_count, "step_type": step_type}
	_append_build_log(id, "step %d/%d %s: started" % [step_index + 1, step_count, step_type])
	plugin_build_step_started.emit(id, step_index, step_count, step_type)


## SetupPipeline.step_finished re-broadcast with `id` correlated in. `detail`
## is SetupExecutors.run_step()'s result Dictionary — {"ok": true, ...} on
## success (no captured stdout; SetupExecutors does not retain it for
## successful steps) or the §3 failure envelope (resolved_argv/exit_code/
## stderr_tail) on failure.
func _on_pipeline_step_finished(step_index: int, step_type: String, ok: bool, detail: Dictionary, id: String) -> void:
	var step_count: int = int(_build_progress.get(id, {}).get("step_count", 0))
	if ok:
		_append_build_log(id, "step %d/%d %s: OK" % [step_index + 1, step_count, step_type])
	else:
		var exit_code = detail.get("exit_code", -1)
		var stderr_tail: String = str(detail.get("stderr_tail", ""))
		var line := "step %d/%d %s: FAILED (exit=%s)" % [step_index + 1, step_count, step_type, str(exit_code)]
		if not stderr_tail.is_empty():
			line += "\n%s" % stderr_tail
		_append_build_log(id, line)
	plugin_build_step_finished.emit(id, step_index, step_count, step_type, ok, detail)


func _append_build_log(id: String, line: String) -> void:
	if not _build_logs.has(id):
		_build_logs[id] = []
	(_build_logs[id] as Array).append(line)


## SetupPipeline's terminal-result handler (always called on the main thread —
## see SetupPipeline's THREADING CONTRACT). Transitions S_BUILDING to its
## final state and persists the envelope (if any) so a restart reports honestly.
func _on_setup_pipeline_finished(result: Dictionary, id: String) -> void:
	_setup_pipelines.erase(id)
	_build_progress.erase(id)
	var was_unattended: bool = _unattended_deny_ids.has(id)
	_unattended_deny_ids.erase(id)

	if result.get("ok", false):
		_setup_envelopes.erase(id)
		_transition_state(id, S_INSTALLED)
		_save_setup_state()
		_append_build_log(id, "build finished: registered")
		print("[PluginManager] Setup pipeline succeeded for '%s' — registered" % id)
		return

	var failed_state: int = S_BUILD_FAILED if str(result.get("state", "")) == "S_BUILD_FAILED" else S_NEEDS_BINARY
	var envelope: Dictionary = result.get("envelope", {})
	# MF1 tail: SetupPipeline stamps every denied exec step detail="exec_denied"
	# (that string is fixed there; the pipeline is out of this round's fence).
	# When the denial came from OUR unattended fail-closed default — the only
	# approver this run had — rewrite the STORED copy to "exec_denied_headless"
	# so UI/MCP consumers can tell "no one was there to ask" from a real user
	# clicking Cancel.
	if was_unattended and str(envelope.get("detail", "")) == "exec_denied":
		envelope = envelope.duplicate(true)
		envelope["detail"] = "exec_denied_headless"
	_setup_envelopes[id] = envelope
	_transition_state(id, failed_state)
	_save_setup_state()
	_append_build_log(id, "build finished: %s" % ("S_BUILD_FAILED" if failed_state == S_BUILD_FAILED else "S_NEEDS_BINARY"))
	push_warning("[PluginManager] Setup pipeline failed for '%s' (state=%d): %s" % [
		id, failed_state, str(result.get("envelope", {})),
	])


## Load persisted S_BUILD_FAILED / S_NEEDS_BINARY state + envelopes from
## setup_state_path and overlay them onto the freshly-loaded DB (which always
## resets every plugin's runtime state to S_INSTALLED — see PluginDB.load_db()).
## Called from _ready(); tests call it directly after pointing _db and
## setup_state_path at scratch fixtures.
func _load_setup_state() -> void:
	if not FileAccess.file_exists(setup_state_path):
		return
	var f := FileAccess.open(setup_state_path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	var parse_err := json.parse(f.get_as_text())
	f.close()
	if parse_err != OK:
		push_warning("[PluginManager] Could not parse setup state file '%s'" % setup_state_path)
		return

	var data: Dictionary = json.data if json.data is Dictionary else {}
	for pid in data:
		var rec: Variant = data[pid]
		if not (rec is Dictionary):
			continue
		var saved_state: int = int((rec as Dictionary).get("state", -1))
		if saved_state != S_BUILD_FAILED and saved_state != S_NEEDS_BINARY:
			continue
		if _db == null or _db.get_by_id(str(pid)) == null:
			continue  # plugin no longer installed — drop the stale entry silently
		_setup_envelopes[str(pid)] = (rec as Dictionary).get("envelope", {})
		_transition_state(str(pid), saved_state)


## Persist every currently S_BUILD_FAILED / S_NEEDS_BINARY plugin's envelope
## to setup_state_path. Called after every setup-pipeline terminal failure (and
## after a success, to drop a now-stale entry).
func _save_setup_state() -> void:
	var data: Dictionary = {}
	for pid in _setup_envelopes:
		var def = _db.get_by_id(str(pid))
		if def == null or (def.state != S_BUILD_FAILED and def.state != S_NEEDS_BINARY):
			continue
		data[pid] = {"state": def.state, "envelope": _setup_envelopes[pid]}

	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(setup_state_path.get_base_dir()))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("[PluginManager] Could not ensure setup state directory: %s" % error_string(dir_err))

	var f := FileAccess.open(setup_state_path, FileAccess.WRITE)
	if f == null:
		push_warning("[PluginManager] Could not write setup state file '%s': %s" % [
			setup_state_path, error_string(FileAccess.get_open_error()),
		])
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


# ---------------------------------------------------------------------------
# Public API — query
# ---------------------------------------------------------------------------

## Return a status snapshot for one plugin.
## Keys: id, state, state_name, uptime_sec, crash_count, running
func get_plugin_status(id: String) -> Dictionary:
	var def = _db.get_by_id(id)
	if def == null:
		return {"error": "Plugin '%s' not found" % id}

	var rt := _ensure_runtime(id)
	var now := Time.get_unix_time_from_system()
	var start_time: float = rt.get("start_time", 0.0)
	var uptime := (now - start_time) if start_time > 0.0 else 0.0

	return {
		"id": id,
		"name": def.name,
		"version": def.version,
		"state": def.state,
		"state_name": [
			"INSTALLED", "STARTING", "RUNNING", "STOPPED", "ERROR", "CRASH_LOOP",
			"BUILDING", "BUILD_FAILED", "NEEDS_BINARY",
		][def.state],
		"uptime_sec": uptime,
		"crash_count": rt.get("crash_count", 0),
		"running": def.state == S_RUNNING,
		"restart_required": not get_restart_required_reason(id).is_empty(),
		"restart_required_reason": get_restart_required_reason(id),
	}


## Return a status snapshot for every installed plugin.
func get_all_plugins() -> Array:
	var result: Array = []
	for def in _db.get_all():
		result.append(get_plugin_status(def.id))
	return result


## Expose the underlying PluginDB for read-only access by other systems.
func get_db():  # -> PluginDB
	return _db


## Return the MCPServerConnection for a running plugin, or null.
func get_connection(id: String) -> MCPServerConnection:
	var rt: Dictionary = _runtime.get(id, {})
	return rt.get("connection", null) as MCPServerConnection


## The private panel channel of plugin `id`'s running process
## (PluginPanelAuthority), or null when it declares none or is not running.
func get_panel_authority(id: String) -> PluginPanelAuthority:
	var rt: Dictionary = _runtime.get(id, {})
	return rt.get("panel_authority", null) as PluginPanelAuthority if rt.get("connection", null) != null else null


## Return the PluginPolicy instance (used by PluginMCPTools).
var _policy_ref = null  # PluginPolicy
func get_policy():  # -> PluginPolicy
	return _policy_ref


## Capabilities that REQUIRE explicit user grant — never auto-granted at install.
## Empty by owner decision: install IS the trust act, so every capability a
## manifest declares is granted at install (the user can revoke any of them
## afterward). Kept as a constant so a future cap can be re-quarantined here
## without touching the grant loop below.
const _NEVER_AUTO_GRANT: Array[String] = []


## Default-grant every capability declared in the plugin's manifest, skipping
## the privilege-escalation denylist. Idempotent: grant_capability is a no-op
## on already-granted caps. Safe to call at install + as a one-time migration
## on plugins installed before this behavior landed.
func _auto_grant_declared_capabilities(def) -> void:
	if def == null:
		return
	if _policy_ref == null:
		push_warning("[PluginManager] _auto_grant: no PluginPolicy reference; skipping for '%s'" % def.id)
		return
	for cap in def.host_capabilities:
		if cap in _NEVER_AUTO_GRANT:
			continue
		_policy_ref.grant_capability(def.id, cap)


## Return the PluginAuditLog instance (used by PluginMCPTools).
var _audit_log_ref = null  # PluginAuditLog
func get_audit_log():  # -> PluginAuditLog
	return _audit_log_ref


# ---------------------------------------------------------------------------
# Public API — bulk operations
# ---------------------------------------------------------------------------

## Enable or disable hot-reload for a plugin.
## When enabled, the plugin is restarted automatically when files in its
## data_directory change (2s poll, 500ms debounce).
func set_auto_reload(id: String, enabled: bool) -> bool:
	return _db.set_auto_reload(id, enabled)


## True once shutdown_all() has run. start_plugin() refuses new starts after
## this: the sequential autostart loop awaits each plugin in turn, so a slow
## FAILING plugin (e.g. drive retrying its connect) can hold the loop past the
## moment the user closes the app — the next iteration then spawned a plugin
## subprocess INTO the tearing-down tree. That subprocess could never be
## parented or stopped, and its live pipes/reader threads kept the dying
## process alive for minutes (the slow-app-close bug, 2026-07-03).
var _shutting_down: bool = false

## plugin_id -> how many times a person (the panel, an MCP call, turning a
## feature off) has asked it to stop this session; stop_plugin's by_person.
var _person_stops: Dictionary = {}


func is_shutting_down() -> bool:
	return _shutting_down


## How many times a person has stopped `id` this session. A start Minerva
## decided on earlier (RequiredPlugins) is dropped if this has changed since.
func person_stops(id: String) -> int:
	return _person_stops.get(id, 0)


## At launch: queue installs of missing required plugins (RequiredPlugins,
## alongside), start the autostart plugins, then queue the opted-in updates
## (PluginAutoUpdater), so an update of a plugin that just started must start
## again before it commits. Minerva does not wait on this.
func start_plugins_at_launch() -> void:
	# Not awaited: autostart does not wait on the network. An editor run (a
	# developer's checkout, and the test harness) never fetches by itself; the
	# plugin panel's "Install required plugins" does it on request.
	RequiredPlugins.move_legacy_relay_state()
	# Installs a crash left half-done were rolled back before Docket was
	# loaded; their seeded skills and knowledge follow now.
	await reconcile_recovered()
	if not OS.has_feature("editor"):
		RequiredPlugins.ensure(self)
	await start_autostart_plugins()
	if not _shutting_down:
		await AutoUpdater.run(self)


## Start all plugins whose autostart flag is true.
## Called by Minerva on boot.
func start_autostart_plugins() -> void:
	var to_start = _db.get_autostart_plugins()
	SingletonObject.verbose_log("[PluginManager] Autostarting %d plugin(s)..." % to_start.size())
	for def in to_start:
		if _shutting_down:
			SingletonObject.verbose_log("[PluginManager] Autostart aborted — shutting down")
			return
		var result := await start_plugin(def.id)
		if result.get("disabled", false):
			SingletonObject.verbose_log("[PluginManager] Autostart skipped for '%s': %s" % [def.id, result.error])
		elif result.get("error"):
			push_error("[PluginManager] Autostart failed for '%s': %s" % [def.id, result.get("error")])


## Stop all running plugins.  Called by Minerva on exit.
func shutdown_all() -> void:
	SingletonObject.verbose_log("[PluginManager] Shutting down all plugins...")
	_shutting_down = true
	var running = _db.get_by_status(S_RUNNING)
	var starting = _db.get_by_status(S_STARTING)
	for def in (running + starting):
		stop_plugin(def.id)
	# An install still downloading or unpacking (a required plugin's repair,
	# a startup update) runs on a worker thread, which must end before exit.
	var workers := InstallWorkers.stop_all()
	if workers > 0:
		print("[PluginManager] Stopped %d plugin install worker(s) before exit" % workers)
	SingletonObject.verbose_log("[PluginManager] All plugins stopped")


# ---------------------------------------------------------------------------
# Crash-loop detection helpers
# ---------------------------------------------------------------------------

## Record a crash timestamp for `id` and return true if the plugin has now
## entered CRASH_LOOP (i.e., hit the threshold within the rolling window).
func _record_crash(id: String) -> bool:
	var rt := _ensure_runtime(id)
	var now := Time.get_unix_time_from_system()

	rt["crash_count"] = rt.get("crash_count", 0) + 1

	# Prune timestamps outside the rolling window.
	var crash_times: Array = rt.get("crash_times", [])
	var cutoff := now - CRASH_LOOP_WINDOW_SEC
	crash_times = crash_times.filter(func(t: float) -> bool: return t >= cutoff)
	crash_times.append(now)
	rt["crash_times"] = crash_times

	return crash_times.size() >= CRASH_LOOP_THRESHOLD


# ---------------------------------------------------------------------------
# Health-check sweep (called from _process)
# ---------------------------------------------------------------------------

func _run_health_checks() -> void:
	for def in _db.get_by_status(S_RUNNING):
		var rt: Dictionary = _runtime.get(def.id, {})
		var conn: MCPServerConnection = rt.get("connection", null)

		# If the connection object is gone or the subprocess is not running,
		# treat it as an unexpected exit.
		var alive := false
		if conn != null and conn.server_connected:
			if is_instance_valid(conn._subprocess) and conn._subprocess.is_running():
				alive = true

		if not alive:
			push_warning("[PluginManager] Health check: plugin '%s' process is gone" % def.id)
			_handle_unexpected_exit(def.id)


# ---------------------------------------------------------------------------
# File-watch sweep (called from _process)
# ---------------------------------------------------------------------------

## Check whether any watched files in installed plugins have been modified.
## Emits plugin_file_changed and starts a debounce timer for auto_reload plugins.
func _run_file_watch_checks() -> void:
	for def in _db.get_all():
		var plugin_dir: String = def.data_directory
		if plugin_dir.is_empty():
			continue

		var current := _scan_plugin_files(plugin_dir)
		if current.is_empty():
			continue

		var stored: Dictionary = _file_mtimes.get(def.id, {})

		# On first scan, just store the baseline — don't trigger a reload.
		if stored.is_empty():
			_file_mtimes[def.id] = current
			continue

		# Compare current times to stored times.
		var changed := false
		for path in current:
			if not stored.has(path) or stored[path] != current[path]:
				changed = true
				break
		# Also detect deletions
		if not changed:
			for path in stored:
				if not current.has(path):
					changed = true
					break

		if changed:
			# Collect the set of changed paths so the debounce handler can apply
			# the correct per-extension reload strategy (design §9.2).
			var changed_paths: Array[String] = []
			for path in current:
				if not stored.has(path) or stored[path] != current[path]:
					changed_paths.append(path)
			for path in stored:
				if not current.has(path):
					changed_paths.append(path)

			_file_mtimes[def.id] = current
			print("[PluginManager] Files changed for plugin '%s'" % def.id)
			plugin_file_changed.emit(def.id)

			if def.auto_reload:
				# Accumulate changed paths for the debounce window (union semantics).
				if not _pending_changed_paths.has(def.id):
					_pending_changed_paths[def.id] = []
				var acc: Array = _pending_changed_paths[def.id]
				for p in changed_paths:
					if not (p in acc):
						acc.append(p)

				if not _reload_pending.has(def.id):
					# Start debounce timer — reload after RELOAD_DEBOUNCE_SEC.
					var timer: SceneTreeTimer = Engine.get_main_loop().create_timer(RELOAD_DEBOUNCE_SEC)
					_reload_pending[def.id] = timer
					var id_copy: String = def.id
					timer.timeout.connect(func(): _on_reload_debounce_expired(id_copy))


## Called when the debounce timer fires for a plugin with auto_reload enabled.
## Implements the hot-reload decision tree (design §9.2):
##   .py/.js/.sh/.json → plugin stop + start (unchanged)
##   .gd/.tscn affecting cached scene code → keep the loaded generation and
##   require an application restart
##   .py/.js/.sh/.json → restart the plugin process after recording that boundary
func _on_reload_debounce_expired(id: String) -> void:
	_reload_pending.erase(id)

	# Collect and clear the accumulated changed paths for this plugin.
	var changed_paths: Array = _pending_changed_paths.get(id, [])
	_pending_changed_paths.erase(id)

	var def = _db.get_by_id(id)
	if def == null or not def.auto_reload:
		return
	# Only reload if the plugin is currently running or in error state.
	if def.state not in [S_RUNNING, S_STARTING, S_ERROR]:
		return

	# Classify changed extensions (union across all changed paths).
	var has_process_ext := false   # py/js/sh/json — always stop+start
	var gd_paths: Array[String] = []
	var tscn_paths: Array[String] = []

	for path in changed_paths:
		var ext: String = (path as String).get_extension().to_lower()
		match ext:
			"py", "js", "sh", "json":
				has_process_ext = true
			"gd":
				gd_paths.append(path)
			"tscn":
				tscn_paths.append(path)

	var scene_restart_required := false
	if not gd_paths.is_empty():
		scene_restart_required = _hot_reload_gd(id, gd_paths)

	if has_process_ext:
		print("[PluginManager] Auto-reloading plugin '%s' (process file change)" % id)
		await restart_plugin(id)

	if scene_restart_required:
		return
	for tscn_path in tscn_paths:
		_hot_reload_tscn(id, tscn_path)


## Return true when a cached or live GDScript generation requires app restart.
func _hot_reload_gd(id: String, gd_paths: Array[String]) -> bool:
	var live_panels: Array = _live_scene_panels.get(id, [])
	var has_cached_script := false
	for path in gd_paths:
		if ResourceLoader.has_cached(path):
			has_cached_script = true
			break
	if live_panels.is_empty() and not has_cached_script:
		return false

	var reason := (
		"Plugin '%s' changed GDScript after scene code was loaded. " +
		"Restart Minerva to load the update safely."
	) % id
	_restart_required[id] = reason
	push_warning("[PluginManager] %s Changed files: %s" % [reason, ", ".join(gd_paths)])
	_surface_restart_required(id, reason)
	return true


func get_restart_required_reason(id: String) -> String:
	return str(_restart_required.get(id, ""))


## Defer a changed live scene to the next application start.
func _hot_reload_tscn(id: String, tscn_path: String) -> void:
	var live_panels: Array = _live_scene_panels.get(id, [])
	if live_panels.is_empty():
		return
	# Replacing a live scene also replaces its broker registration and attached
	# document buffer. Defer the whole scene generation to the next app start.
	_mark_restart_required(id, tscn_path.get_file())


func _mark_restart_required(id: String, subject: String) -> void:
	var reason := (
		"Plugin '%s' changed '%s' while its scene code was loaded. " +
		"Restart Minerva to load the update safely."
	) % [id, subject]
	_restart_required[id] = reason
	push_warning("[PluginManager] %s" % reason)
	_surface_restart_required(id, reason)


func _surface_restart_required(id: String, reason: String) -> void:
	plugin_restart_required.emit(id, reason)
	if SingletonObject and SingletonObject.has_method("create_toast_notification"):
		SingletonObject.call("create_toast_notification", reason, 1, false)


## Marketplace calls this before replacing an installed directory.
func can_replace_plugin_files(id: String) -> Dictionary:
	var def = _db.get_by_id(id)
	if def == null:
		return {"ok": true}
	if not _live_scene_panels.get(id, []).is_empty():
		var live_reason := "Restart Minerva before updating plugin '%s'; its scene is open." % id
		_restart_required[id] = live_reason
		_surface_restart_required(id, live_reason)
		return {"error": "restart_required", "message": live_reason}
	if PluginScenePanelHost.has_loaded_scripts_in_directory(def.data_directory):
		var loaded_reason := "Restart Minerva before updating plugin '%s'; its scene code was loaded." % id
		_restart_required[id] = loaded_reason
		_surface_restart_required(id, loaded_reason)
		return {"error": "restart_required", "message": loaded_reason}
	var prefix: String = str(def.data_directory).simplify_path() + "/"
	for panel in def.ui_panels:
		if not panel is Dictionary:
			continue
		for rel in (panel as Dictionary).get("scripts", []):
			var path := (prefix + str(rel)).simplify_path()
			if ResourceLoader.has_cached(path):
				var reason := "Restart Minerva before updating plugin '%s'; its scene code is loaded." % id
				_restart_required[id] = reason
				_surface_restart_required(id, reason)
				return {"error": "restart_required", "message": reason}
	return {"ok": true}


# ---------------------------------------------------------------------------
# Public API — live scene panel registry
# ---------------------------------------------------------------------------

## Register a live scene panel so hot-reload can find and re-instantiate it.
##
## Called by Editor.create() (or equivalent) after a PLUGIN_SCENE panel is
## successfully mounted.  `tscn_path` is the absolute path to the .tscn file
## so _hot_reload_tscn can match changed paths to live instances.
## `panel_key` is the broker registry key for this mount — unique per open tab,
## where panel_name is shared by every tab showing the same manifest panel.
## Entries are removed by key so closing one tab cannot drop another's record.
func register_live_panel(
		plugin_id: String,
		panel_name: String,
		tscn_path: String,
		vbox: Control,
		root: Control,
		editor,  # Editor — untyped to avoid circular dep
		panel_key: String = ""
) -> void:
	if not _live_scene_panels.has(plugin_id):
		_live_scene_panels[plugin_id] = []
	var entry := {
		"panel_name": panel_name,
		"panel_key":  panel_key if not panel_key.is_empty() else panel_name,
		"tscn_path":  tscn_path,
		"vbox":       vbox,
		"root":       root,
		"editor":     editor,
	}
	_live_scene_panels[plugin_id].append(entry)


## Unregister a live scene panel (called on tab close or plugin stop).
##
## Matched on the entry's key ONLY. The manifest panel name is shared by every
## tab showing that panel, so accepting it here would let one tab closing drop
## every other tab's record — the record hot-reload needs to find them by.
func unregister_live_panel(plugin_id: String, panel_key: String) -> void:
	if not _live_scene_panels.has(plugin_id):
		return
	var panels: Array = _live_scene_panels[plugin_id]
	for i in range(panels.size() - 1, -1, -1):
		var entry: Dictionary = panels[i]
		var key: String = str(entry.get("panel_key", entry.get("panel_name", "")))
		if key == panel_key:
			panels.remove_at(i)


## Return all live panel entries for a plugin (read-only copy).
func get_live_panels(plugin_id: String) -> Array:
	return _live_scene_panels.get(plugin_id, []).duplicate()


## Return a Dictionary of { absolute_path: modified_time_int } for all watched
## files (*.py, *.js, *.sh, *.json) found directly in plugin_dir.
## Does not recurse into sub-directories.
func _scan_plugin_files(plugin_dir: String) -> Dictionary:
	var result: Dictionary = {}
	var dir := DirAccess.open(plugin_dir)
	if dir == null:
		return result

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var ext := file_name.get_extension().to_lower()
			if ext in WATCH_EXTENSIONS:
				var full_path := plugin_dir.path_join(file_name)
				result[full_path] = FileAccess.get_modified_time(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

## Called when MCPServerConnection emits `disconnected` while we did NOT
## initiate the stop (i.e., no stop_plugin call is in progress).
func _on_plugin_disconnected(id: String) -> void:
	var def = _db.get_by_id(id)
	if def == null:
		return

	# If we are already stopping or the state is already STOPPED/ERROR/CRASH_LOOP
	# this signal is expected — ignore it.
	var rt: Dictionary = _runtime.get(id, {})
	if rt.get("stopping", false):
		return

	if def.state in [S_STOPPED,
					 S_ERROR,
					 S_CRASH_LOOP]:
		return

	push_warning("[PluginManager] Plugin '%s' disconnected unexpectedly" % id)
	_handle_unexpected_exit(id)


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Central handler for any unexpected process exit (from health-check or
## disconnect signal).  Updates state and emits signals.
func _handle_unexpected_exit(id: String) -> void:
	var rt := _ensure_runtime(id)

	# Avoid double-handling (health-check and signal may fire close together).
	if rt.get("stopping", false):
		return
	rt["stopping"] = true

	_cleanup_connection(id)
	rt["stopping"] = false
	rt["start_time"] = 0.0

	plugin_crashed.emit(id)

	var entered_crash_loop := _record_crash(id)
	if entered_crash_loop:
		push_error("[PluginManager] Plugin '%s' has crashed %d times in %ds — entering CRASH_LOOP" % [
			id, CRASH_LOOP_THRESHOLD, int(CRASH_LOOP_WINDOW_SEC)
		])
		_transition_state(id, S_CRASH_LOOP)
	else:
		_transition_state(id, S_ERROR)


## Update the DB state and emit plugin_state_changed.
func _transition_state(id: String, new_state: int) -> void:
	var def = _db.get_by_id(id)
	if def == null:
		return
	var old_state: int = def.state
	if old_state == new_state:
		return
	_db.update_state(id, new_state)
	plugin_state_changed.emit(id, old_state, new_state)


## Disconnect and free a connection, leaving the runtime entry intact.
func _cleanup_connection(id: String) -> void:
	var rt: Dictionary = _runtime.get(id, {})
	var conn: MCPServerConnection = rt.get("connection", null)
	if conn == null:
		return

	# Detach signal before disconnecting to avoid re-entrant crash handling.
	if conn.disconnected.is_connected(_on_plugin_disconnected.bind(id)):
		conn.disconnected.disconnect(_on_plugin_disconnected.bind(id))

	if conn.server_connected or is_instance_valid(conn._subprocess):
		conn.disconnect_from_server()
	rt["panel_authority"] = null

	rt["connection"] = null


## Delete a directory and all its contents recursively.
## Returns OK on success, or an error code.
func _delete_directory_recursive(path: String) -> Error:
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
	# If the path itself is a symlink, unlink it — DirAccess.open would
	# resolve through it and delete the link target's contents.
	var parent_dir := DirAccess.open(abs_path.get_base_dir())
	if parent_dir != null and parent_dir.is_link(abs_path):
		return parent_dir.remove(abs_path)
	var dir := DirAccess.open(abs_path)
	if dir == null:
		# Maybe it's a file or doesn't exist
		var fallback_dir := DirAccess.open(abs_path.get_base_dir())
		if fallback_dir != null:
			return fallback_dir.remove(abs_path)
		return DirAccess.get_open_error()
	# Remove all files and subdirectories first. DirAccess hides dotfiles by
	# default; data dirs contain them (.venv, .cache), so include them or the
	# directory can never be fully removed. Entries are snapshotted before
	# deleting (unlinking mid-readdir can skip entries), and symlinks are
	# unlinked, never followed — recursing through one (venvs symlink dirs)
	# would delete the link target's contents.
	dir.include_hidden = true
	var subdirs := PackedStringArray()
	var files := PackedStringArray()
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		if dir.current_is_dir() and not dir.is_link(entry):
			subdirs.append(entry)
		else:
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	for file_name in files:
		dir.remove(abs_path.path_join(file_name))
	for dir_name in subdirs:
		_delete_directory_recursive(abs_path.path_join(dir_name))
	# Now remove the empty directory itself
	var cleanup_dir := DirAccess.open(abs_path.get_base_dir())
	if cleanup_dir != null:
		return cleanup_dir.remove(abs_path)
	return OK


## Return the CapabilityBroker from SingletonObject, or null if unavailable.
func _get_capability_broker():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	return so.get("plugin_capability_broker") if "plugin_capability_broker" in so else null


## Return the PluginEventBroker from SingletonObject, or null if unavailable.
func _get_event_broker():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	return so.get("plugin_event_broker") if "plugin_event_broker" in so else null


## Return the PluginScenePanelBroker from SingletonObject, or null if unavailable.
func _get_scene_panel_broker() -> PluginScenePanelBroker:
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	return so.get("plugin_scene_panel_broker") if "plugin_scene_panel_broker" in so else null


## Return the runtime Dictionary for `id`, creating it if absent.
func _ensure_runtime(id: String) -> Dictionary:
	if not _runtime.has(id):
		_runtime[id] = {
			"connection": null,
			"start_time": 0.0,
			"crash_count": 0,
			"crash_times": [],
			"stopping": false,
		}
	return _runtime[id]
