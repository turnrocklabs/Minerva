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

# Timeout for the download itself. A 309 MB plugin on a 1 MB/s
# connection takes ~5 minutes; allow 10 minutes for headroom on
# slow links. Network failures inside this window still fail fast
# (cant_connect / tls_handshake fire on the first packet).
const DOWNLOAD_HTTP_TIMEOUT_SECONDS := 600.0


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
## and runtime setup all run — same code path as side-load).
##
## Pass `installer` = SingletonObject.plugin_manager (or null to skip the
## registration step — useful for tests that only exercise the
## download/extract/verify path).
func install_from_registry_entry(entry: Dictionary, installer) -> Dictionary:
	var target := resolve_platform_target()
	if target.is_empty():
		return _err("unsupported_platform", {"os": OS.get_name()})
	var downloads: Dictionary = entry.get("downloads", {})
	var url: String = downloads.get(target, "")
	if url.is_empty():
		return _err("no_binary_for_target", {"target": target, "plugin": entry.get("id")})
	return await install_from_url(url, installer)


## Download a plugin release tarball from `tarball_url`, extract, verify
## SHA256SUMS. If `installer` is a PluginManager (duck-typed via
## install_plugin method), delegate the final registration to it so the
## full side-load code path runs. If `installer` exposes a plain `install`
## method (a PluginDB), call that for a minimal registration (used by
## tests). If null, stop after staging and return the local manifest path.
##
## Returns:
##   {ok:true, plugin_id, manifest_path, definition?}
##   {ok:false, error, detail}
func install_from_url(tarball_url: String, installer) -> Dictionary:
	_ensure_dir(PLUGINS_DIR)
	_ensure_dir(STAGING_DIR)

	# Stage the tarball to disk under a unique-ish name. We don't know the
	# plugin id yet (it's inside manifest.json), so name by url hash.
	var staging_file := "%s/dl_%d.tar.gz" % [STAGING_DIR, Time.get_ticks_msec()]
	var staging_abs := ProjectSettings.globalize_path(staging_file)

	# --- 1. Download ---
	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = DOWNLOAD_HTTP_TIMEOUT_SECONDS
	http.body_size_limit = DOWNLOAD_MAX_BODY_BYTES
	http.download_file = staging_file
	add_child(http)

	var err := http.request(tarball_url)
	if err != OK:
		http.queue_free()
		return _err("download_request_failed", {"godot_err": err, "url": tarball_url})

	var result: Array = await http.request_completed
	http.queue_free()

	var http_result: int = result[0]
	var response_code: int = result[1]

	if http_result != HTTPRequest.RESULT_SUCCESS:
		_rm_file(staging_file)
		return _err("download_http_result", {"http_result": http_result, "url": tarball_url})
	if response_code < 200 or response_code >= 300:
		_rm_file(staging_file)
		return _err("download_bad_status", {"code": response_code, "url": tarball_url})
	if not FileAccess.file_exists(staging_file):
		return _err("download_no_file", {"path": staging_file})

	# --- 2. Extract to a unique extraction dir ---
	var extract_dir := "%s/extract_%d" % [STAGING_DIR, Time.get_ticks_msec()]
	_ensure_dir(extract_dir)
	var extract_abs := ProjectSettings.globalize_path(extract_dir)

	var tar_out := []
	var tar_rc := OS.execute("tar", ["-xzf", staging_abs, "-C", extract_abs], tar_out, true)
	if tar_rc != 0:
		_rm_file(staging_file)
		_rm_dir_recursive(extract_dir)
		return _err("extract_failed", {"rc": tar_rc, "stderr": "\n".join(tar_out)})

	# --- 3. Verify SHA256SUMS ---
	var sums_file := "%s/SHA256SUMS" % extract_dir
	if not FileAccess.file_exists(sums_file):
		_rm_file(staging_file)
		_rm_dir_recursive(extract_dir)
		return _err("missing_sha256sums", {"extract_dir": extract_dir})

	var sha_check := _verify_sha256sums(extract_dir)
	if not sha_check.ok:
		_rm_file(staging_file)
		_rm_dir_recursive(extract_dir)
		return _err("sha256_mismatch", sha_check.detail)

	# --- 4. Read manifest to discover plugin_id ---
	var manifest_path := "%s/manifest.json" % extract_dir
	if not FileAccess.file_exists(manifest_path):
		_rm_file(staging_file)
		_rm_dir_recursive(extract_dir)
		return _err("missing_manifest", {"extract_dir": extract_dir})

	var manifest_text := FileAccess.get_file_as_string(manifest_path)
	var manifest = JSON.parse_string(manifest_text)
	if not manifest is Dictionary or not manifest.has("id"):
		_rm_file(staging_file)
		_rm_dir_recursive(extract_dir)
		return _err("bad_manifest", {"path": manifest_path})

	var plugin_id: String = manifest["id"]

	# --- 5. Move to canonical user://plugins/<id>/ ---
	var final_dir := "%s/%s" % [PLUGINS_DIR, plugin_id]
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(final_dir)):
		_rm_dir_recursive(final_dir)
	var rename_err := DirAccess.rename_absolute(extract_abs, ProjectSettings.globalize_path(final_dir))
	if rename_err != OK:
		_rm_file(staging_file)
		_rm_dir_recursive(extract_dir)
		return _err("install_move_failed", {"godot_err": rename_err})

	# Make the binary executable (extracted files lose +x bit on some
	# filesystems / Windows). manifest.backend.entrypoint is relative to
	# the plugin dir.
	if manifest.has("backend") and manifest.backend.has("entrypoint"):
		var entrypoint_rel: String = manifest.backend.entrypoint
		if entrypoint_rel.begins_with("./"):
			entrypoint_rel = entrypoint_rel.substr(2)
		var entrypoint_abs := "%s/%s" % [ProjectSettings.globalize_path(final_dir), entrypoint_rel]
		if FileAccess.file_exists(entrypoint_abs):
			_chmod_executable(entrypoint_abs)

	# --- 6. Cleanup staging ---
	_rm_file(staging_file)

	# --- 7. Register via installer (duck-typed) ---
	# `installer` may be:
	#   - null              → stop after staging; caller registers
	#   - PluginManager     → full install flow (capability grants, runtime,
	#                         skill seeding, directory creation)
	#   - PluginDB          → minimal registration (used by headless tests)
	var final_manifest := "%s/manifest.json" % final_dir

	if installer == null:
		return {
			"ok": true,
			"plugin_id": plugin_id,
			"manifest_path": final_manifest,
		}

	if installer.has_method("install_plugin"):
		var pm_result: Dictionary = await installer.install_plugin(final_manifest)
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
			var PluginDefinitionCls = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
			var new_def = PluginDefinitionCls.from_manifest(final_manifest)
			if new_def == null:
				return _err("update_parse_failed", {"path": final_manifest})
			if not installer.update_definition(new_def):
				return _err("update_definition_failed", {})
			definition = new_def
		else:
			definition = installer.install(final_manifest)
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


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _err(code: String, detail = {}) -> Dictionary:
	return {"ok": false, "error": code, "detail": detail}


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
## instead of an opaque error code like `download_http_result`.
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
		"http_result_not_success", "download_http_result":
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
					hint = "The download didn't complete within the timeout. Slow network or large archive. Retry once more."
				HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
					hint = "Too many redirects in the download chain. Open the URL in your browser and report the final redirect target."
				_:
					hint = "Retry once; if the same code recurs, copy the URL above and try downloading it in a browser to isolate."
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
		"download_no_file":
			title = "Download finished but the file is missing"
			cause = "Godot reported success but the file wasn't found at %s" % str(detail_dict.get("path", "?"))
			hint = "Disk write may have failed silently. Check available space and try again."
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
			cause = "The archive does not contain a usable manifest.json at the top level."
			hint = "This is a packaging error on the plugin side. Report it to the plugin author."
		"install_move_failed":
			title = "Could not move the extracted plugin into place"
			cause = "Godot returned error %d while renaming the staging directory." % int(detail_dict.get("godot_err", -1))
			hint = "Likely a permission or disk-full issue under user://plugins/."
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


## Parse SHA256SUMS and verify every line's hash matches the on-disk file.
## Returns {ok: bool, detail: Dictionary}.
func _verify_sha256sums(extract_dir: String) -> Dictionary:
	var sums_file := "%s/SHA256SUMS" % extract_dir
	var content := FileAccess.get_file_as_string(sums_file)
	if content.is_empty():
		return {"ok": false, "detail": {"reason": "empty_sums_file"}}
	for raw_line in content.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		# sha256sum format: "<64-char hex>  <filename>"
		var parts := line.split("  ", false, 1)
		if parts.size() != 2:
			# Some shasum variants emit "<hex> *<filename>"; accept that too.
			parts = line.split(" *", false, 1)
		if parts.size() != 2:
			return {"ok": false, "detail": {"reason": "unparseable_line", "line": line}}
		var expected_hex: String = parts[0].strip_edges()
		var filename: String = parts[1].strip_edges()
		var file_path := "%s/%s" % [extract_dir, filename]
		if not FileAccess.file_exists(file_path):
			return {"ok": false, "detail": {"reason": "missing_file", "file": filename}}
		var actual_hex := _sha256_hex(file_path)
		if actual_hex.to_lower() != expected_hex.to_lower():
			return {"ok": false, "detail": {
				"reason": "hash_mismatch",
				"file": filename,
				"expected": expected_hex,
				"actual": actual_hex,
			}}
	return {"ok": true, "detail": {}}


func _sha256_hex(file_path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var chunk := f.get_buffer(64 * 1024)
		if chunk.size() > 0:
			ctx.update(chunk)
	f.close()
	return ctx.finish().hex_encode()


func _ensure_dir(rel_path: String) -> void:
	var abs := ProjectSettings.globalize_path(rel_path)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


func _rm_file(rel_path: String) -> void:
	var abs := ProjectSettings.globalize_path(rel_path)
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)


func _rm_dir_recursive(rel_path: String) -> void:
	var abs := ProjectSettings.globalize_path(rel_path)
	var d := DirAccess.open(abs)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var name := d.get_next()
		if name.is_empty():
			break
		if name == "." or name == "..":
			continue
		var entry_abs := "%s/%s" % [abs, name]
		if d.current_is_dir():
			_rm_dir_recursive("%s/%s" % [rel_path, name])
		else:
			DirAccess.remove_absolute(entry_abs)
	d.list_dir_end()
	DirAccess.remove_absolute(abs)


func _chmod_executable(abs_path: String) -> void:
	# Unix: chmod +x. Windows: no-op (Windows doesn't gate execution by mode bit).
	if OS.get_name() == "Windows":
		return
	var _out := []
	OS.execute("chmod", ["+x", abs_path], _out, true)
