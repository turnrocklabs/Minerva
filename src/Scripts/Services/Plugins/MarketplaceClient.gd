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

const PluginDownloader := preload("res://Scripts/Services/Plugins/PluginDownloader.gd")
const PluginArchive := preload("res://Scripts/Services/Plugins/PluginArchive.gd")
const PluginInstallOperation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")

const REGISTRY_URL_DEFAULT := "https://raw.githubusercontent.com/imrans-lab/minerva-plugins/main/registry.json"

const STAGING_DIR := "user://plugins/.staging"
# Inside an operation's staging directory: the install being replaced, and
# which plugin it belongs to.
const PREVIOUS := "previous"
const OP_RECORD := "op.json"
# A running install rewrites its op record this often; the startup sweep
# leaves alone any operation whose record is younger than OP_STALE_SECONDS,
# because another Minerva process (a second instance, a test run) sharing
# this user directory may still own it.
const OP_HEARTBEAT_SECONDS := 10.0
const OP_STALE_SECONDS := 120
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

	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = REGISTRY_HTTP_TIMEOUT_SECONDS
	http.body_size_limit = REGISTRY_MAX_BODY_BYTES
	add_child(http)

	var err := http.request(url)
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
	if not parsed is Dictionary:
		return _err("invalid_json", {"url": url})

	return {"ok": true, "registry": parsed}


# ---------------------------------------------------------------------------
# Platform target resolution
# ---------------------------------------------------------------------------

## Return the canonical target string used in registry `downloads` keys,
## e.g. "linux-x86_64", "linux-arm64", "macos-universal", "windows-x86_64".
## Returns "" on an unsupported platform.
func resolve_platform_target() -> String:
	var os_name := OS.get_name()
	if os_name == "Linux" or os_name == "FreeBSD" or os_name == "BSD":
		if OS.has_feature("arm64"):
			return "linux-arm64"
		return "linux-x86_64"
	if os_name == "macOS":
		return "macos-universal"
	if os_name == "Windows":
		return "windows-x86_64"
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
	var target := resolve_platform_target()
	if target.is_empty():
		return _err("unsupported_platform", {"os": OS.get_name()})
	var downloads: Dictionary = entry.get("downloads", {})
	var url: String = downloads.get(target, "")
	if url.is_empty():
		return _err("no_binary_for_target", {"target": target, "plugin": entry.get("id")})
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
## Any failure puts the old files and the old DB record back. All scratch
## files live in this operation's own staging directory, removed at the end;
## sweep_staging() recovers from a crash in between.
##
## Returns:
##   {ok:true, plugin_id, version, manifest_path, definition?, manager_result?}
##   {ok:false, error, detail}
func install_from_url(tarball_url: String, installer, auto_confirm_skills: bool = false,
		op: PluginInstallOperation = null, expected: Dictionary = {}) -> Dictionary:
	if op == null:
		op = PluginInstallOperation.new()
	op.staging_dir = ProjectSettings.globalize_path(STAGING_DIR).path_join(
		"op_%d_%d" % [Time.get_ticks_usec(), randi()])
	DirAccess.make_dir_recursive_absolute(op.staging_dir)
	_write_op_record(op)
	var heartbeat := Timer.new()
	heartbeat.wait_time = OP_HEARTBEAT_SECONDS
	heartbeat.process_mode = Node.PROCESS_MODE_ALWAYS
	heartbeat.timeout.connect(_write_op_record.bind(op))
	add_child(heartbeat)
	heartbeat.start()
	var result := await _install(tarball_url, installer, auto_confirm_skills, op, expected)
	heartbeat.queue_free()
	# A previous install that could not be moved back stays for sweep_staging.
	if result.get("ok", false) or not DirAccess.dir_exists_absolute(op.staging_dir.path_join(PREVIOUS)):
		_rm_dir_recursive(op.staging_dir)
	return result


func _install(tarball_url: String, installer, auto_confirm_skills: bool,
		op: PluginInstallOperation, expected: Dictionary) -> Dictionary:
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

	var identity := PluginArchive.check_identity(manifest, expected, resolve_platform_target(), extract_abs)
	if not identity.is_empty():
		return identity

	# Host-owned identities are refused HERE, before the replace, not by
	# PluginDB.install() further downstream: by then user://plugins/<id>/
	# would already hold the tarball's files. Anything already sitting at the
	# reserved path is left untouched.
	if InternalPlugins.has(raw_id):
		return _err("reserved_id", {"id": raw_id})

	var plugin_id: String = raw_id
	op.plugin_id = plugin_id
	if installer != null and installer.has_method("can_replace_plugin_files"):
		var replace_check: Dictionary = installer.can_replace_plugin_files(plugin_id)
		if replace_check.has("error"):
			return _err("restart_required", replace_check)

	# Cancellation is honored up to here; replacing and registering either
	# complete or roll back.
	if op.cancelled:
		return _err("cancelled", {})
	op.enter(PluginInstallOperation.STAGE_REGISTER)

	# --- 4. Replace user://plugins/<id>/, keeping the old copy until registered ---
	var final_dir := "%s/%s" % [PLUGINS_DIR, plugin_id]
	var final_abs := ProjectSettings.globalize_path(final_dir)
	var previous_abs := op.staging_dir.path_join(PREVIOUS)
	var db = _installer_db(installer)
	var previous_def = db.get_by_id(plugin_id) if db != null else null
	var had_previous := DirAccess.dir_exists_absolute(final_abs)
	_ensure_dir(PLUGINS_DIR)
	if had_previous:
		_write_op_record(op)  # names the plugin before its files are set aside
		var aside_err := DirAccess.rename_absolute(final_abs, previous_abs)
		if aside_err != OK:
			return _err("install_move_failed", {"godot_err": aside_err})
	var move_err := DirAccess.rename_absolute(extract_abs, final_abs)
	if move_err != OK:
		_roll_back(plugin_id, had_previous, previous_abs, db, previous_def)
		return _err("install_move_failed", {"godot_err": move_err})

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

	# --- 5. Register; a failure restores the previous install ---
	var registered := await _register(plugin_id, "%s/manifest.json" % final_dir, installer, auto_confirm_skills)
	if not registered.get("ok", false):
		_roll_back(plugin_id, had_previous, previous_abs, db, previous_def)
		return registered
	registered["version"] = str(manifest.get("version", ""))
	return registered


## Register the manifest now at `final_manifest` through `installer`:
##   - null              → stop after staging; caller registers
##   - PluginManager     → full install flow (capability grants, runtime,
##                         skill seeding, directory creation)
##   - PluginDB          → minimal registration (used by headless tests)
func _register(plugin_id: String, final_manifest: String, installer, auto_confirm_skills: bool) -> Dictionary:
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
				final_manifest, auto_confirm_skills, lane)
		else:
			pm_result = await installer.install_plugin(
				final_manifest, auto_confirm_skills, lane)
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
			var new_def = LaneCls.from_manifest(final_manifest)
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


## Undo a failed replace: drop the new files, move the previous install back,
## and put the DB record back the way it was before registration.
func _roll_back(plugin_id: String, had_previous: bool, previous_abs: String, db, previous_def) -> void:
	var final_abs := ProjectSettings.globalize_path("%s/%s" % [PLUGINS_DIR, plugin_id])
	_rm_dir_recursive(final_abs)
	if had_previous:
		var err := DirAccess.rename_absolute(previous_abs, final_abs)
		if err != OK:
			push_error("[MarketplaceClient] could not restore %s (error %d); kept at %s" % [final_abs, err, previous_abs])
	if db == null:
		return
	if previous_def != null:
		if db.get_by_id(plugin_id) != previous_def:
			db.update_definition(previous_def)
	elif db.has_plugin(plugin_id):
		db.remove(plugin_id)


## The PluginDB behind `installer` (a PluginManager or a PluginDB), or null.
static func _installer_db(installer):
	if installer == null:
		return null
	if installer.has_method("get_db"):
		return installer.get_db()
	return installer if installer.has_method("get_by_id") else null


## Rewrites the operation's record: which plugin a set-aside `previous`
## belongs to, and (by its modified time) that the operation is alive.
static func _write_op_record(op: PluginInstallOperation) -> void:
	var f := FileAccess.open(op.staging_dir.path_join(OP_RECORD), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"id": op.plugin_id}))


## Run once at startup, before this process begins any install. An operation
## whose record has gone stale belongs to an install that never finished: if
## it stopped between setting the old install aside and committing, it still
## has `previous`, which is moved back while the DB records that version.
## Stale operations are then deleted; live ones are left to their owner.
static func sweep_staging(db) -> void:
	var root_abs := ProjectSettings.globalize_path(STAGING_DIR)
	var root := DirAccess.open(root_abs)
	if root == null:
		return
	root.include_hidden = true
	var now := Time.get_unix_time_from_system()
	for name in root.get_directories():
		var record := root_abs.path_join(name).path_join(OP_RECORD)
		if FileAccess.file_exists(record) and now - FileAccess.get_modified_time(record) < OP_STALE_SECONDS:
			continue
		if not _restore_uncommitted(root_abs.path_join(name), db):
			_rm_dir_recursive(root_abs.path_join(name))
	for name in root.get_files():
		DirAccess.remove_absolute(root_abs.path_join(name))


## Moves an operation's `previous` back when the DB still records its version.
## Returns true when the directory must be kept because that move failed.
static func _restore_uncommitted(op_abs: String, db) -> bool:
	var previous_abs := op_abs.path_join(PREVIOUS)
	var record = JSON.parse_string(FileAccess.get_file_as_string(op_abs.path_join(OP_RECORD)))
	if db == null or not DirAccess.dir_exists_absolute(previous_abs) or not record is Dictionary:
		return false
	var plugin_id := str(record.get("id", ""))
	var def = db.get_by_id(plugin_id)
	var previous = JSON.parse_string(FileAccess.get_file_as_string(previous_abs.path_join("manifest.json")))
	if def == null or not previous is Dictionary or str(previous.get("version", "")) != str(def.version):
		return false
	var final_abs := ProjectSettings.globalize_path("%s/%s" % [PLUGINS_DIR, plugin_id])
	_rm_dir_recursive(final_abs)
	return DirAccess.rename_absolute(previous_abs, final_abs) != OK


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
		"cancelled":
			title = "Install cancelled"
			cause = "The install was cancelled before anything was changed."
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
