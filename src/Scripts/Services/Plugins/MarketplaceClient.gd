class_name MarketplaceClient
extends Node
## Plugin marketplace client — fetches the registry, resolves the platform
## target, downloads + verifies + extracts a plugin tarball, and delegates
## final registration to the existing PluginDB.install(manifest_path).
##
## Side-load (PluginDB.install with a developer-local manifest path) is
## unchanged and still works.
##
## Returned shape from every public method:
##   {ok: bool, ...op-specific fields}, with ok=false carrying
##   `error` (short string code) and `detail` (free-form).

const AutoUpdater := preload("res://Scripts/Services/Plugins/PluginAutoUpdater.gd")
const PluginDownloader := preload("res://Scripts/Services/Plugins/PluginDownloader.gd")
const PluginArchive := preload("res://Scripts/Services/Plugins/PluginArchive.gd")
const PluginInstallOperation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")
const PluginInstallTransaction := preload("res://Scripts/Services/Plugins/PluginInstallTransaction.gd")

const REGISTRY_URL_DEFAULT := "https://raw.githubusercontent.com/imrans-lab/minerva-plugins/main/registry.json"

const STAGING_DIR := "user://plugins/.staging"
const PLUGINS_DIR := "user://plugins"

# Defensive caps on the small registry JSON. Anything beyond a couple
# hundred KiB suggests something is wrong with the registry, not a
# legitimate growth — fail fast.
const REGISTRY_MAX_BODY_BYTES := 4 * 1024 * 1024  # 4 MiB
const REGISTRY_HTTP_TIMEOUT_SECONDS := 30.0

# Plugin download cap. The CAD plugin alone is 309 MB (embedded Python
# runtime + build123d + cadquery-ocp), and similar "bundled runtime"
# plugins are likely. Allow 2 GiB headroom; legitimate plugins with
# native binaries + interpreter envs can run hundreds of MB. Any
# legitimate cap below the largest expected plugin is a footgun.
const DOWNLOAD_MAX_BODY_BYTES := 2 * 1024 * 1024 * 1024  # 2 GiB

# A download fails only when no byte arrives for this long; a slow link that
# keeps making progress is never cut off (PluginDownloader).
const DOWNLOAD_STALL_TIMEOUT_SECONDS := 30.0


# ---------------------------------------------------------------------------
# Registry fetch
# ---------------------------------------------------------------------------

## Fetch the marketplace registry JSON from `url` (defaults to the
## canonical raw.githubusercontent.com URL). Returns:
##   {ok:true, registry: Dictionary} or
##   {ok:false, error: String, detail: Dictionary}
func fetch_registry(url: String = "") -> Dictionary:
	if url.is_empty():
		url = REGISTRY_URL_DEFAULT
	var fetched := await fetch_json(url)
	if not fetched.ok:
		return fetched
	if not fetched.json is Dictionary:
		return _err("invalid_json", {"url": url})
	return {"ok": true, "registry": fetched.json}


## GET `url` and parse its body as JSON, within the registry's time and size
## bounds. Returns {ok:true, json} or {ok:false, error, detail}.
func fetch_json(url: String, headers: PackedStringArray = PackedStringArray()) -> Dictionary:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = REGISTRY_HTTP_TIMEOUT_SECONDS
	http.body_size_limit = REGISTRY_MAX_BODY_BYTES
	add_child(http)

	var err := http.request(url, headers)
	if err != OK:
		http.queue_free()
		return _err("request_failed", {"godot_err": err, "url": url})

	var result: Array = await http.request_completed
	http.queue_free()

	var http_result: int = result[0]
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]

	if http_result != HTTPRequest.RESULT_SUCCESS:
		return _err("http_result_not_success", {"http_result": http_result, "url": url})
	if response_code != 200:
		return _err("bad_response_code", {"code": response_code, "url": url})

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null:
		return _err("invalid_json", {"url": url})
	return {"ok": true, "json": parsed}


## A registry entry as callers outside the marketplace see it: its listing
## (a release published before listings existed has no description, and says
## so), whether this computer has a build, and what is installed.
static func describe_entry(entry: Dictionary, installed_version: String) -> Dictionary:
	var target := resolve_platform_target()
	var downloads: Dictionary = entry.get("downloads", {})
	var described := {
		"id": entry.get("id", ""),
		"name": entry.get("name", entry.get("id", "")),
		"version": entry.get("version", ""),
		"description": str(entry.get("description", "")),
		"description_missing": str(entry.get("description", "")).is_empty(),
		"platforms": downloads.keys(),
		"this_platform": target,
		"available_here": not download_target(downloads).is_empty(),
		"installed_version": installed_version,
		"release_tag": entry.get("release_tag", ""),
		"manifest_url": entry.get("manifest_url", ""),
	}
	if not described.available_here:
		described["unavailable_reason"] = "Minerva does not support this operating system (%s)." % OS.get_name() \
			if target.is_empty() else "No build of this release is published for %s." % target
	return described


# ---------------------------------------------------------------------------
# Platform target resolution
# ---------------------------------------------------------------------------

## This machine's preferred target in registry `downloads` keys, e.g.
## "linux-x86_64", "linux-arm64", "macos-arm64", "macos-amd64",
## "windows-x86_64"; "" on an unsupported platform. See platform_targets.
static func resolve_platform_target() -> String:
	var targets := platform_targets()
	return targets[0] if not targets.is_empty() else ""


## Every registry target a build for this machine may be published under, in
## order of preference: a Mac takes its own architecture first, then a
## universal build.
static func platform_targets() -> Array[String]:
	var os_name := OS.get_name()
	if os_name == "Linux" or os_name == "FreeBSD" or os_name == "BSD":
		return ["linux-arm64" if OS.has_feature("arm64") else "linux-x86_64"]
	if os_name == "macOS":
		var architecture := Engine.get_architecture_name()
		return ["macos-arm64" if architecture in ["arm64", "aarch64"] else "macos-amd64", "macos-universal"]
	if os_name == "Windows":
		return ["windows-x86_64"]
	return []


## The first of platform_targets that `downloads` (a registry entry's
## target -> URL map) has a build for, or "".
static func download_target(downloads: Dictionary) -> String:
	for target in platform_targets():
		if downloads.has(target):
			return target
	return ""


# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

## High-level: install a plugin given a registry entry. Picks the right URL
## for the current platform, downloads + verifies + extracts, then registers
## via PluginManager.install_plugin (so capability auto-grant, skill seeding,
## and runtime setup all run — same code path as side-load). The archive must
## hold the entry's plugin id and version, built for this platform.
##
## Pass `installer` = SingletonObject.plugin_manager (or null to skip the
## registration step — useful for tests that only exercise the
## download/extract/verify path). `op` is as for install_from_url.
func install_from_registry_entry(entry: Dictionary, installer, auto_confirm_skills: bool = false,
		op: PluginInstallOperation = null) -> Dictionary:
	if platform_targets().is_empty():
		return _err("unsupported_platform", {"os": OS.get_name()})
	var downloads: Dictionary = entry.get("downloads", {})
	var url: String = downloads.get(download_target(downloads), "")
	if url.is_empty():
		return _err("no_binary_for_target", {"target": resolve_platform_target(), "plugin": entry.get("id")})
	var expected := {}
	for field in ["id", "version"]:
		if not str(entry.get(field, "")).is_empty():
			expected[field] = entry[field]
	return await install_from_url(url, installer, auto_confirm_skills, op, expected)


## Download a plugin release tarball from `tarball_url`, extract, verify
## SHA256SUMS. If `installer` is a PluginManager (duck-typed via
## install_plugin method), delegate the final registration to it so the
## full side-load code path runs. If `installer` exposes a plain `install`
## method (a PluginDB), call that for a minimal registration (used by
## tests). If null, stop after staging and return the local manifest path.
##
## `auto_confirm_skills` is forwarded to PluginManager.install_plugin: when true,
## skill seeding runs without popping the interactive confirmation dialog. MCP /
## headless callers MUST pass true — there is no user to dismiss the dialog, and
## awaiting it deadlocks the install (the install otherwise succeeds, then hangs).
##
## `op` reports stage and progress and can cancel (see PluginInstallOperation).
## `expected` holds the id and/or version the archive must declare.
##
## An installed plugin is replaced as a transaction: its directory is set
## aside, the new one moved in, and only a successful registration commits.
## When the replaced plugin was running (the caller stopped it for the
## replacement and set op.start_after_install), its data is saved and the new
## version must start before the replacement commits. A plugin the user had
## stopped stays stopped: its working copy is kept (awaits_first_start) until
## the new version's first start, which commits the update or rolls it back
## (PluginPendingUpgrade). Any failure puts the old files, the old DB record
## and the saved data back. All scratch files live in this
## operation's own staging directory, removed at the end; sweep_staging()
## recovers from a crash in between.
##
## Returns:
##   {ok:true, plugin_id, version, manifest_path, started, awaits_first_start,
##    definition?, manager_result?} (started: the new version was started
##    before the install committed; awaits_first_start: the working copy is
##    kept until its first start)
##   {ok:false, error, detail}
func install_from_url(tarball_url: String, installer, auto_confirm_skills: bool = false,
		op: PluginInstallOperation = null, expected: Dictionary = {}) -> Dictionary:
	if op == null:
		op = PluginInstallOperation.new()
	var staging_root := ProjectSettings.globalize_path(STAGING_DIR)
	DirAccess.make_dir_recursive_absolute(staging_root)
	var txn := PluginInstallTransaction.begin(staging_root)
	if txn == null:
		if not ClassDB.class_exists("ProcessFileLock"):
			return _err("install_lock_unavailable", {})
		return _err("staging_failed", {"dir": staging_root})
	op.staging_dir = txn.op_dir
	var result := await _install(tarball_url, installer, auto_confirm_skills, op, expected, txn)
	txn.leave()
	# An incomplete rollback keeps the operation (and its backup) for a later
	# recovery pass.
	var rollback: Dictionary = result.get("rollback", {})
	if result.get("awaits_first_start", false):
		pass  # the operation directory holds the kept working copy
	elif rollback.is_empty() or rollback_complete(rollback):
		_rm_dir_recursive(op.staging_dir)
	return result


func _install(tarball_url: String, installer, auto_confirm_skills: bool,
		op: PluginInstallOperation, expected: Dictionary, txn) -> Dictionary:
	# --- 1. Download ---
	op.enter(PluginInstallOperation.STAGE_DOWNLOAD)
	var archive := op.staging_dir.path_join("download.tar.gz")
	var downloader := PluginDownloader.new()
	downloader.stall_timeout_s = DOWNLOAD_STALL_TIMEOUT_SECONDS
	downloader.max_bytes = DOWNLOAD_MAX_BODY_BYTES
	downloader.op = op
	var fetched: Dictionary = await downloader.download(tarball_url, archive, get_tree())
	if not fetched.ok:
		return fetched

	# --- 2. Extract and verify SHA256SUMS off the main thread ---
	var extract_abs := op.staging_dir.path_join("extract")
	DirAccess.make_dir_recursive_absolute(extract_abs)
	var unpacked: Dictionary = await PluginArchive.new().unpack(archive, extract_abs, op, get_tree())
	if not unpacked.ok:
		return unpacked
	DirAccess.remove_absolute(archive)  # the extracted copy is all that is needed now

	# --- 3. Read the manifest and check it is what was asked for ---
	var manifest_path := extract_abs.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return _err("missing_manifest", {"extract_dir": extract_abs})
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest is Dictionary or not manifest.has("id"):
		return _err("bad_manifest", {"path": manifest_path})

	# Guard before the destructive replace below: a hostile manifest id like
	# "../.." would aim it outside user://plugins/, and registration-time
	# validation (PluginDefinition) runs too late to protect it. Checked
	# before the typed assignment — a non-String id would throw there. "data"
	# is reserved: user://plugins/data/ is the shared per-plugin data root,
	# not a plugin slot.
	var raw_id: Variant = manifest["id"]
	var PluginDefCls = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	if not (raw_id is String) or not PluginDefCls._is_valid_id(raw_id) or raw_id == "data":
		return _err("bad_manifest", {"path": manifest_path, "reason": "invalid_id"})

	var identity := PluginArchive.check_identity(manifest, expected, platform_targets(), extract_abs)
	if not identity.ok:
		return identity

	var plugin_id: String = raw_id
	op.identify(plugin_id, str(manifest.get("version", "")))
	if installer != null and installer.has_method("can_replace_plugin_files"):
		var replace_check: Dictionary = installer.can_replace_plugin_files(plugin_id)
		if replace_check.has("error"):
			return _err("restart_required", replace_check)

	# --- 4. Ask the user everything registration will need, while nothing
	# has been replaced and cancelling is still free ---
	var consent := {}
	if installer != null and installer.has_method("collect_skill_consent"):
		op.enter(PluginInstallOperation.STAGE_CONFIRM)
		consent = await installer.collect_skill_consent(manifest_path, auto_confirm_skills, op)
	# Cancellation is honored up to here; replacing and registering either
	# commit or roll back.
	if op.cancelled:
		return _err("cancelled", {})

	# --- 5. Replace user://plugins/<id>/, keeping the old copy until the new
	# registration is saved (PluginInstallTransaction) ---
	var final_dir := "%s/%s" % [PLUGINS_DIR, plugin_id]
	var final_abs := ProjectSettings.globalize_path(final_dir)
	var db = _installer_db(installer)
	txn.plugin_id = plugin_id
	# Holds the staging lock from here to the end of the install (released by
	# install_from_url); waiting for another process's install is cancellable.
	op.enter(PluginInstallOperation.STAGE_WAIT)
	var entered: Dictionary = await txn.enter(ProjectSettings.globalize_path(STAGING_DIR), db, op, get_tree())
	if not entered.is_empty():
		return entered
	# Entering may have undone other installs; their Docket content follows.
	if installer != null and installer.has_method("reconcile_recovered"):
		await installer.reconcile_recovered()
	# Read under the lock: entering may have just recovered this record.
	var previous_def = db.get_by_id(plugin_id) if db != null else null
	# An unattended update stands only while the plugin still wants it, judged
	# under the lock: a user who opted out, removed the plugin, moved it to the
	# developer lane or installed another version meanwhile is not overridden.
	if op.unattended and not AutoUpdater.wants_update(previous_def, str(manifest.get("version", ""))):
		return _err("update_not_wanted", {"id": plugin_id})
	# Likewise a repair: a copy fixed, or a developer copy registered, while
	# it was queued or downloading is left alone.
	if op.repair_only and not RequiredPlugins.needs_repair(previous_def):
		return _err("repair_not_needed", {"id": plugin_id})
	txn.db_before = previous_def.to_dict() if previous_def != null else null
	op.enter(PluginInstallOperation.STAGE_REGISTER)
	_ensure_dir(PLUGINS_DIR)
	txn.had_previous = DirAccess.dir_exists_absolute(final_abs)
	if not txn.publish(PluginInstallTransaction.PHASE_REPLACING):
		return _err("staging_failed", {"dir": op.staging_dir})
	# A running plugin (stopped for this replacement at STAGE_REGISTER) is
	# upgraded only if the new version starts (step 7). Its data is saved now,
	# before anything of the new version is registered or run, so a rollback
	# restores it as it was.
	var verify_start: bool = txn.had_previous and op.start_after_install and installer != null \
		and installer.has_method("start_plugin")
	if verify_start and not txn.save_data(PluginInstallTransaction.data_directory(plugin_id)):
		return _failed_replace(_err("data_backup_failed", {"id": plugin_id}), txn, final_abs, db, previous_def)
	if txn.had_previous:
		var aside_err := DirAccess.rename_absolute(final_abs, op.staging_dir.path_join(PluginInstallTransaction.PREVIOUS))
		if aside_err != OK:
			return _failed_replace(_err("install_move_failed", {"godot_err": aside_err}), txn, final_abs, db, previous_def)
	var move_err := DirAccess.rename_absolute(extract_abs, final_abs)
	if move_err != OK:
		return _failed_replace(_err("install_move_failed", {"godot_err": move_err}), txn, final_abs, db, previous_def)

	# Make the binary executable (extracted files lose +x bit on some
	# filesystems / Windows). manifest.backend.entrypoint is relative to
	# the plugin dir.
	if manifest.has("backend") and manifest.backend.has("entrypoint"):
		var entrypoint_rel: String = manifest.backend.entrypoint
		if entrypoint_rel.begins_with("./"):
			entrypoint_rel = entrypoint_rel.substr(2)
		var entrypoint_abs := final_abs.path_join(entrypoint_rel)
		if FileAccess.file_exists(entrypoint_abs):
			_chmod_executable(entrypoint_abs)

	# --- 6. Register; commit only once the DB is saved ---
	consent["journal_dir"] = op.staging_dir
	var registered := await _register(plugin_id, "%s/manifest.json" % final_dir, installer, auto_confirm_skills, consent)
	if registered.get("ok", false) and db != null and not db.save():
		registered = _err("register_not_saved", {"id": plugin_id})
	if not registered.get("ok", false):
		return await _failed_after_register(registered, txn, final_abs, db, previous_def, installer, plugin_id)
	# --- 7. An upgrade of a plugin that was running starts BEFORE it
	# commits (its data was saved in step 5): a new version that fails to
	# start, or is cancelled while starting, goes back to the working copy's
	# files, record and data. Any other install commits here and its start,
	# if any, is the caller's.
	registered["started"] = false
	if verify_start:
		var started := await _start_before_commit(installer, plugin_id, op)
		if not started.get("ok", false):
			return await _failed_after_register(started, txn, final_abs, db, previous_def, installer, plugin_id)
		registered["started"] = true
	# An update of a plugin the user had stopped is not started to test it.
	# Its working copy is kept (pending_first_start) until the new version's
	# first start shows it runs (PluginPendingUpgrade); if an earlier update
	# is already waiting, that one holds the last known-good copy and this
	# one's previous files, which never ran, are not kept.
	var awaits_first_start: bool = txn.had_previous and not verify_start and installer != null \
		and installer.has_method("start_plugin") \
		and PluginInstallTransaction.pending_for(ProjectSettings.globalize_path(STAGING_DIR), plugin_id) == null
	# The install commits only once this record is saved too; until then a
	# crash rolls back to the previous install, DB record and data together.
	var phase := PluginInstallTransaction.PHASE_PENDING if awaits_first_start else PluginInstallTransaction.PHASE_COMMITTED
	if not txn.publish(phase):
		if registered.started:
			installer.stop_plugin(plugin_id)  # it runs on the files being rolled back
		return await _failed_after_register(_err("staging_failed", {"dir": op.staging_dir}), txn, final_abs, db,
			previous_def, installer, plugin_id)
	if not awaits_first_start and installer != null and installer.has_method("content_committed"):
		installer.content_committed(op.staging_dir, plugin_id)
	registered["awaits_first_start"] = awaits_first_start
	if not awaits_first_start:
		_rm_dir_recursive(op.staging_dir.path_join(PluginInstallTransaction.PREVIOUS))
	registered["version"] = str(manifest.get("version", ""))
	registered["platform_verified"] = identity.platform_verified
	return registered


## Start the just-registered version. Returns {ok:true} once it runs, or a
## failure with the plugin stopped again.
func _start_before_commit(installer, plugin_id: String, op: PluginInstallOperation) -> Dictionary:
	op.enter(PluginInstallOperation.STAGE_START)
	var started: Dictionary = await installer.start_plugin(plugin_id, true)
	if op.cancelled or started.has("error"):
		installer.stop_plugin(plugin_id)
		if op.cancelled:
			return _err("cancelled", {"while": "starting"})
		return _err("start_failed", {"id": plugin_id, "reason": str(started.error)})
	return {"ok": true}


## Whether a rollback (PluginInstallTransaction.roll_back) put everything
## back: files, the DB record and, when it was saved, the data.
static func rollback_complete(rollback: Dictionary) -> bool:
	return rollback.files_restored and rollback.db_restored and rollback.get("data_restored", true)


## `failure` plus what rolling the replacement back restored.
func _failed_replace(failure: Dictionary, txn, final_abs: String, db, previous_def) -> Dictionary:
	failure["rollback"] = txn.roll_back(final_abs, db, previous_def)
	return failure


## _failed_replace once registration may have seeded the new version's skills
## and knowledge: after the rollback, that Docket content is queued for repair
## and `installer` (a PluginManager) puts it back in line with what is
## installed again (a repair that does not finish is retried later).
func _failed_after_register(failure: Dictionary, txn, final_abs: String, db, previous_def, installer,
		plugin_id: String) -> Dictionary:
	var attempted = db.get_by_id(plugin_id) if db != null else null
	var registered_new: bool = attempted != null and attempted != previous_def
	_failed_replace(failure, txn, final_abs, db, previous_def)
	if registered_new and failure.rollback.db_restored and installer != null \
			and installer.has_method("reconcile_recovered"):
		if PluginInstallTransaction.queue_content(ProjectSettings.globalize_path(STAGING_DIR), txn.op_dir,
				plugin_id).is_empty():
			push_error("[MarketplaceClient] '%s' was rolled back, but the repair of its skills and knowledge could not be queued" % plugin_id)
		else:
			await installer.reconcile_recovered()
	return failure


## Register the manifest now at `final_manifest` through `installer`:
##   - null              → stop after staging; caller registers
##   - PluginManager     → full install flow (capability grants, runtime,
##                         skill seeding, directory creation)
##   - PluginDB          → minimal registration (used by headless tests)
func _register(plugin_id: String, final_manifest: String, installer, auto_confirm_skills: bool,
		consent: Dictionary) -> Dictionary:
	if installer == null:
		return {
			"ok": true,
			"plugin_id": plugin_id,
			"manifest_path": final_manifest,
		}

	# Every registration below declares the marketplace lane: what landed in
	# final_dir is a SHA-pinned release artifact, not a source checkout, so a
	# `setup` stanza in the shipped manifest must not be built (design §1).
	var LaneCls = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var lane: String = LaneCls.LANE_MARKETPLACE

	if installer.has_method("install_plugin"):
		var pm_result: Dictionary
		var manager_db = installer.get_db() if installer.has_method("get_db") else null
		if manager_db != null and manager_db.has_plugin(plugin_id) \
				and installer.has_method("update_plugin"):
			pm_result = await installer.update_plugin(
				final_manifest, auto_confirm_skills, lane, consent)
		else:
			pm_result = await installer.install_plugin(
				final_manifest, auto_confirm_skills, lane, consent)
		if pm_result.has("error"):
			return _err("manager_install_failed", pm_result)
		return {
			"ok": true,
			"plugin_id": plugin_id,
			"manifest_path": final_manifest,
			"manager_result": pm_result,
		}

	if installer.has_method("install"):
		# PluginDB path — handle install vs update_definition.
		var definition
		if installer.has_method("has_plugin") and installer.has_plugin(plugin_id):
			var new_def = LaneCls.from_manifest(final_manifest, lane)
			if new_def == null:
				return _err("update_parse_failed", {"path": final_manifest})
			new_def.install_lane = lane
			if not installer.update_definition(new_def):
				return _err("update_definition_failed", {})
			definition = new_def
		else:
			definition = installer.install(final_manifest, lane)
			if definition == null:
				var last_err = installer.get_last_install_error() if installer.has_method("get_last_install_error") else {}
				return _err("register_failed", last_err)
		return {
			"ok": true,
			"plugin_id": plugin_id,
			"manifest_path": final_manifest,
			"definition": definition,
		}

	return _err("invalid_installer", {"got": typeof(installer)})


## The PluginDB behind `installer` (a PluginManager or a PluginDB), or null.
static func _installer_db(installer):
	if installer == null:
		return null
	if installer.has_method("get_db"):
		return installer.get_db()
	return installer if installer.has_method("get_by_id") else null


## Run once at startup, before this process begins any install: undoes
## every install another (exited) process left half-done. Returns the
## operations that need a person ({dir, id, reason}); what it rolled back is
## queued for Docket repair (PluginInstallTransaction.content_pending).
static func sweep_staging(db) -> Array:
	return PluginInstallTransaction.sweep(ProjectSettings.globalize_path(STAGING_DIR), db)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _err(code: String, detail = {}) -> Dictionary:
	return {"ok": false, "error": code, "detail": detail}


## "12.5 MB", or "an unknown size" when the server stated no length.
static func _size_or_unknown(detail: Dictionary) -> String:
	var total := int(detail.get("total", -1))
	return String.humanize_size(total) if total >= 0 else "an unknown size"


## Translate Godot HTTPRequest.RESULT_* enum to a human label.
## Returns "Unknown HTTP error (<n>)" for values we don't recognize.
static func _http_result_label(code: int) -> String:
	match code:
		HTTPRequest.RESULT_SUCCESS: return "Success"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: return "Chunked body size mismatch"
		HTTPRequest.RESULT_CANT_CONNECT: return "Can't connect (network unreachable, port blocked, or server refused)"
		HTTPRequest.RESULT_CANT_RESOLVE: return "Can't resolve hostname (DNS failure or no internet)"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "Connection error (interrupted mid-transfer)"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS handshake failed (cert / network filtering issue)"
		HTTPRequest.RESULT_NO_RESPONSE: return "No response from server"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "Response body exceeded size limit"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED: return "Body decompression failed"
		HTTPRequest.RESULT_REQUEST_FAILED: return "Request failed"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: return "Can't open download file (path permission / disk full)"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: return "Write error on download file (disk full?)"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "Too many redirects (GitHub releases chain often needs >8)"
		HTTPRequest.RESULT_TIMEOUT: return "Request timed out"
		_: return "Unknown HTTP error (%d)" % code


## Format an install/registry error dict into a user-readable multi-line
## message. Returns "" if `result` looks like a success or is empty.
##
## Use from any UI surface that surfaces install failures so users see
## what actually went wrong (e.g. "TLS handshake failed" + the URL)
## instead of an opaque error code like `download_connection_failed`.
static func format_install_error(result: Dictionary) -> String:
	if result.is_empty() or result.get("ok") == true:
		return ""

	var code: String = str(result.get("error", "unknown"))
	var detail: Variant = result.get("detail", null)
	var detail_dict: Dictionary = detail if detail is Dictionary else {}

	var title := ""
	var cause := ""
	var hint := ""

	match code:
		"request_failed", "download_request_failed":
			title = "Could not start the network request"
			cause = "Godot rejected the request before it was sent (error %d)" % int(detail_dict.get("godot_err", -1))
			hint = "Check that the URL is valid and that no firewall is blocking outbound HTTPS."
		"http_result_not_success":
			var http_code: int = int(detail_dict.get("http_result", -1))
			title = "Download failed before the server responded"
			cause = _http_result_label(http_code)
			# Hints tailored to the specific failure mode.
			match http_code:
				HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
					hint = "On macOS this often means Godot's bundled TLS roots are out of date. Try again on another network, or update Minerva to a newer build."
				HTTPRequest.RESULT_CANT_RESOLVE:
					hint = "Confirm you have internet access — try opening the URL in your browser."
				HTTPRequest.RESULT_CANT_CONNECT:
					hint = "The host is reachable in DNS but the connection was refused. Check VPN / proxy settings."
				HTTPRequest.RESULT_TIMEOUT:
					hint = "The server didn't answer in time. Retry once more."
				HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
					hint = "Too many redirects in the download chain. Open the URL in your browser and report the final redirect target."
				_:
					hint = "Retry once; if the same code recurs, copy the URL above and try downloading it in a browser to isolate."
		"download_connection_failed":
			title = "Could not connect to the download server"
			match int(detail_dict.get("status", -1)):
				HTTPClient.STATUS_CANT_RESOLVE:
					cause = "The host name could not be resolved (DNS failure or no internet)."
					hint = "Confirm you have internet access — try opening the URL in your browser."
				HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
					cause = "The secure connection could not be established (TLS handshake failed)."
					hint = "Try again on another network, or update Minerva to a newer build."
				_:
					cause = "The connection was refused or could not be opened."
					hint = "Check VPN / proxy / firewall settings and retry."
		"download_stalled":
			title = "Download stalled"
			cause = "The server stopped sending after %s of %s, and still sent nothing when Minerva retried from where it stopped (it waits %d seconds each time)." % [
				String.humanize_size(int(detail_dict.get("bytes", 0))), _size_or_unknown(detail_dict), int(detail_dict.get("seconds", 0))]
			hint = "Check your connection and install again."
		"download_interrupted":
			title = "Download was interrupted"
			cause = "The connection kept dropping after %s of %s, even when Minerva retried from where it stopped." % [
				String.humanize_size(int(detail_dict.get("bytes", 0))), _size_or_unknown(detail_dict)]
			hint = "Check your connection and install again."
		"download_resume_unsupported":
			title = "Download was interrupted and could not resume"
			cause = "The connection dropped after %s, and the server does not support resuming, so the partial file was deleted." % \
				String.humanize_size(int(detail_dict.get("bytes", 0)))
			hint = "Install again to restart the download from the beginning."
		"download_too_large":
			title = "Plugin archive is too large"
			cause = "The archive exceeds the %s download limit." % String.humanize_size(int(detail_dict.get("limit", 0)))
			hint = "This is a packaging problem on the plugin side. Report it to the plugin author."
		"download_redirect_limit":
			title = "Too many redirects"
			cause = "The download URL redirected more times than Minerva follows."
			hint = "Open the URL in your browser and report the final redirect target."
		"download_write_failed":
			title = "Could not save the download"
			cause = "Writing %s failed (error %d)." % [str(detail_dict.get("path", "?")), int(detail_dict.get("godot_err", -1))]
			hint = "Check available disk space and permissions, then try again."
		"bad_response_code", "download_bad_status":
			var status: int = int(detail_dict.get("code", -1))
			title = "Server returned HTTP %d" % status
			match status:
				404: cause = "The plugin archive was not found at that URL."
				403: cause = "Access was denied (private repo, expired token, or rate-limited)."
				429: cause = "Rate-limited by GitHub. Wait a minute and try again."
				500, 502, 503, 504: cause = "GitHub is having problems. Try again shortly."
				_: cause = "Server returned a non-2xx status."
			hint = "Try downloading the URL below in your browser to confirm whether the asset is reachable."
		"extract_failed":
			title = "Could not extract the plugin archive"
			cause = "`tar -xzf` returned exit code %d" % int(detail_dict.get("rc", -1))
			var stderr := str(detail_dict.get("stderr", "")).strip_edges()
			if not stderr.is_empty():
				cause += "\n\nstderr:\n%s" % stderr
			hint = "The archive may be corrupt or truncated. Retry the install."
		"missing_sha256sums":
			title = "Plugin archive is missing SHA256SUMS"
			cause = "The archive extracted, but did not contain the integrity manifest required for verification."
			hint = "This is a packaging error on the plugin side. Report it to the plugin author."
		"sha256_mismatch":
			title = "Plugin integrity check failed"
			cause = "One or more files in the archive don't match the SHA256SUMS manifest:\n%s" % JSON.stringify(detail_dict)
			hint = "Archive may have been corrupted in transit, or tampered with. Retry once; if the failure recurs, report to the plugin author."
		"missing_manifest", "bad_manifest":
			title = "Plugin manifest is missing or invalid"
			if str(detail_dict.get("reason", "")) == "invalid_id":
				cause = "manifest.json exists, but its \"id\" is not a valid plugin id (a lowercase letter followed by lowercase letters, digits, or underscores; \"data\" is reserved)."
			else:
				cause = "The archive does not contain a usable manifest.json at the top level."
			hint = "This is a packaging error on the plugin side. Report it to the plugin author."
		"install_move_failed":
			title = "Could not move the extracted plugin into place"
			cause = "Godot returned error %d while renaming the staging directory." % int(detail_dict.get("godot_err", -1))
			hint = "Likely a permission or disk-full issue under user://plugins/. Any previous version was put back, or will be on a later start of Minerva."
		"identity_mismatch":
			var field := str(detail_dict.get("field", "?"))
			title = "The downloaded plugin is not the one requested"
			cause = "Its %s is %s, but %s was expected." % [field, str(detail_dict.get("actual", "?")),
				str(detail_dict.get("expected", "?"))]
			hint = "Nothing was changed. This is a packaging or registry error; report it to the plugin author."
		"archive_unsafe":
			title = "The plugin archive is unsafe to unpack"
			cause = "Entry %s: %s." % [str(detail_dict.get("entry", "?")), str(detail_dict.get("reason", "?"))]
			hint = "Nothing was changed. Report this archive to the plugin author."
		"archive_too_large":
			title = "The plugin archive unpacks to too much data"
			cause = "It would expand past the %s limit." % String.humanize_size(int(detail_dict.get("limit", 0)))
			hint = "Nothing was changed. Report this archive to the plugin author."
		"archive_corrupt":
			title = "The plugin archive is damaged"
			cause = str(detail_dict.get("reason", "The archive could not be read."))
			hint = "Nothing was changed. Retry the install; the download may have been corrupted."
		"insufficient_disk_space":
			title = "Not enough disk space to install"
			cause = "Unpacking needs %s but only %s is free." % [String.humanize_size(int(detail_dict.get("needed", 0))),
				String.humanize_size(int(detail_dict.get("free", 0)))]
			hint = "Free some disk space and install again. Nothing was changed."
		"install_lock_failed":
			title = "Could not lock plugin installs"
			cause = "Minerva cannot use %s (%s)." % [str(detail_dict.get("path", "?")), str(detail_dict.get("reason", "?"))]
			hint = "Check permissions and free space under user://plugins/. Nothing was changed."
		"plugin_db_stale":
			title = "Another Minerva changed your plugins"
			cause = "The plugin list on disk changed since this Minerva read it."
			hint = "Restart Minerva, then install again. Nothing was changed."
		"install_lock_unavailable":
			title = "Plugin installs are unavailable in this build"
			cause = "Minerva's native file-lock support (ProcessFileLock) is missing, so an install could not be protected."
			hint = "Update or rebuild Minerva's native libraries. Nothing was changed."
		"recovery_pending":
			title = "An earlier install of this plugin is not undone yet"
			cause = str(detail_dict.get("reason", "An unfinished install left files Minerva could not restore."))
			hint = "Resolve that first (restart Minerva to retry automatically), then install again. Nothing was changed."
		"staging_failed":
			title = "Could not prepare the install"
			cause = "Minerva could not write its install record in %s." % str(detail_dict.get("dir", "?"))
			hint = "Check free disk space and permissions under user://plugins/. Nothing was changed."
		"register_not_saved":
			title = "The install could not be saved"
			cause = "Minerva registered '%s' but could not write its plugin database." % str(detail_dict.get("id", "?"))
			hint = "Check free disk space and permissions under user://plugins/."
		"cancelled":
			title = "Install cancelled"
			if str(detail_dict.get("while", "")) == "starting":
				cause = "The new version was cancelled while it started, so the update was not applied."
			else:
				cause = "The install was cancelled before anything was changed."
		"start_failed":
			title = "The new version did not start"
			cause = "'%s' failed to start: %s" % [str(detail_dict.get("id", "?")), str(detail_dict.get("reason", "?"))]
			hint = "The update was not applied. Report the reason above to the plugin's author."
		"repair_not_needed":
			title = "Repair skipped"
			cause = "'%s' was repaired, or replaced by a developer copy, before this repair could run, so it was left as it is." % str(detail_dict.get("id", "?"))
		"update_not_wanted":
			title = "Automatic update skipped"
			cause = "'%s' is no longer set to update at startup, was removed or replaced, or is already at this version, so it was left as it is." % str(detail_dict.get("id", "?"))
		"data_backup_failed":
			title = "Could not save the plugin's data before updating"
			cause = "Minerva could not copy the data of '%s' aside, so it did not start the new version." % str(detail_dict.get("id", "?"))
			hint = "Check free disk space under user://plugins/."
		"manager_install_failed":
			title = "PluginManager refused the install"
			cause = str(detail_dict.get("error", JSON.stringify(detail_dict)))
		"unsupported_platform":
			title = "Plugin doesn't support this OS"
			cause = "Detected OS: %s" % str(detail_dict.get("os", "?"))
			hint = "Check the plugin's registry entry — it may need an updated build for this platform."
		"no_binary_for_target":
			title = "No matching binary for this platform"
			cause = "Plugin '%s' has no binary built for target '%s'" % [str(detail_dict.get("plugin", "?")), str(detail_dict.get("target", "?"))]
			hint = "Wait for the plugin author to publish a build for your platform, or use a side-loaded copy if available."
		"invalid_installer":
			title = "Internal error: invalid installer"
			cause = "Got type %d instead of a PluginManager." % int(detail_dict.get("got", -1))
		_:
			title = "Plugin install failed"
			cause = "Error code: %s" % code

	var url := str(detail_dict.get("url", ""))
	var lines := PackedStringArray()
	lines.append(title)
	if not cause.is_empty():
		lines.append("")
		lines.append(cause)
	if not url.is_empty():
		lines.append("")
		lines.append("URL: %s" % url)
	if not hint.is_empty():
		lines.append("")
		lines.append(hint)
	var rollback: Dictionary = result.get("rollback", {})
	if not rollback.is_empty():
		lines.append("")
		if rollback_complete(rollback):
			lines.append("The previously installed version was put back%s." % (
				", with its data as it was" if rollback.get("data_saved", false) else ""))
		elif not rollback.files_restored:
			lines.append("The previous version could not be put back yet; it is kept at %s and Minerva will restore it when it next starts." % rollback.kept_at)
		else:
			if not rollback.get("data_restored", true):
				lines.append("The previous version is back, but its data could not be put back yet; it is kept at %s and Minerva will restore it when it next starts." % rollback.kept_at)
			if not rollback.db_restored:
				lines.append("The previous files were put back, but the plugin database could not be restored; restart Minerva.")
	lines.append("")
	lines.append("(internal code: %s)" % code)
	return "\n".join(lines)


func _ensure_dir(rel_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(rel_path)
	if not DirAccess.dir_exists_absolute(abs_path):
		DirAccess.make_dir_recursive_absolute(abs_path)


static func _rm_dir_recursive(rel_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(rel_path)
	# If the path itself is a symlink (e.g. a side-loaded dev checkout linked
	# into user://plugins/), unlink it — DirAccess.open would resolve through
	# it and the walk would delete the link target's contents.
	var parent := DirAccess.open(abs_path.get_base_dir())
	if parent != null and parent.is_link(abs_path):
		DirAccess.remove_absolute(abs_path)
		return
	var d := DirAccess.open(abs_path)
	if d == null:
		return
	# DirAccess hides dotfiles by default; without this, hidden files survive
	# the walk, the dir can't be removed, and the install rename fails.
	d.include_hidden = true
	# Snapshot entries before deleting — unlinking mid-readdir can skip
	# entries on some filesystems. Symlinks are unlinked, never followed:
	# current_is_dir() stats through the link, and recursing would delete
	# the link target's contents.
	var subdirs := PackedStringArray()
	var files := PackedStringArray()
	d.list_dir_begin()
	while true:
		var entry_name := d.get_next()
		if entry_name.is_empty():
			break
		if entry_name == "." or entry_name == "..":
			continue
		if d.current_is_dir() and not d.is_link(entry_name):
			subdirs.append(entry_name)
		else:
			files.append(entry_name)
	d.list_dir_end()
	for file_name in files:
		DirAccess.remove_absolute("%s/%s" % [abs_path, file_name])
	for dir_name in subdirs:
		_rm_dir_recursive("%s/%s" % [rel_path, dir_name])
	DirAccess.remove_absolute(abs_path)


func _chmod_executable(abs_path: String) -> void:
	# Unix: chmod +x. Windows: no-op (Windows doesn't gate execution by mode bit).
	if OS.get_name() == "Windows":
		return
	var _out := []
	OS.execute("chmod", ["+x", abs_path], _out, true)
