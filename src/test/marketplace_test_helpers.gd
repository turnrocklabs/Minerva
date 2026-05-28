## Shared helpers for the marketplace-install functional tests
## (test_marketplace_install_start_scansort.gd and
## test_marketplace_install_start_cad_evaluate.gd).
##
## Factored 2026-05-27 (DCR 019e6a4bcb0c W2 scope amendment). Owns the
## boilerplate that BOTH tests need: HTTP fixture server, shell-cmd wrappers,
## PluginManager bootstrap, MarketplaceClient install + start, real-release
## tarball download with GH-redirect handling, and cleanup. Per-test logic
## (RED-vs-GREEN assertions, plugin-specific tool calls) stays in the test
## files themselves.
##
## Usage:
##   var h = preload("res://test/marketplace_test_helpers.gd").new(self)
##   if not await h.start_http_server(serve_dir, port): return
##   var dl = await h.download_release_tarball("imrans-lab/minerva-plugins",
##           "cad-v0.1.0", "cad-0.1.0-macos-universal.tar.gz", "user://test_fixtures/")
##   ...
##   h.teardown()
##
## Helper takes a SceneTree on init so async ops (await tree.create_timer)
## work without globals. Helper holds onto resources it creates (HTTP server
## pid, temp dirs) and cleans them in teardown(). Per-test cleanup of
## PluginManager DB state stays in the test files.

extends RefCounted

var _tree: SceneTree
var _server_pid: int = -1
var _http_dir: String = ""

const PLUGIN_MANAGER_GD := "res://Scripts/Services/Plugins/PluginManager.gd"
const MARKETPLACE_GD := "res://Scripts/Services/Plugins/MarketplaceClient.gd"

# Plugin state enum values (mirrors PluginDefinition.State; intentionally
# inlined so tests don't need to import the definition).
const S_RUNNING: int = 2
const S_STOPPED: int = 3


func _init(tree: SceneTree) -> void:
	_tree = tree


# ---------------------------------------------------------------------------
# Shell + filesystem helpers
# ---------------------------------------------------------------------------

func run_cmd(cmd: String, args: Array) -> bool:
	var out: Array = []
	var rc := OS.execute(cmd, args, out, true)
	if rc != 0:
		print("  cmd %s %s failed (rc=%d): %s" % [cmd, args, rc, "\n".join(out)])
		return false
	return true


func mkdir_recursive(path: String) -> bool:
	if path.begins_with("user://") or path.begins_with("res://"):
		return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path)) == OK
	return DirAccess.make_dir_recursive_absolute(path) == OK


func rm_dir_recursive(rel_path: String) -> void:
	var abs: String = rel_path
	if rel_path.begins_with("user://") or rel_path.begins_with("res://"):
		abs = ProjectSettings.globalize_path(rel_path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	OS.execute("rm", ["-rf", abs], [], true)


# ---------------------------------------------------------------------------
# HTTP fixture server
# ---------------------------------------------------------------------------

# start_http_server boots python3 -m http.server in directory, binds to
# 127.0.0.1:port, waits for the TCP port to accept connections, and probes
# HTTP via HTTPRequest. The two-stage probe (OS socket then HTTPRequest) is
# what cad's test discovered the hard way — full-singleton boot starves
# create_timer enough that pure HTTPRequest polling can miss.
#
# Returns true on success. Server pid is stored for teardown.
func start_http_server(directory: String, port: int, timeout_sec: float = 15.0) -> bool:
	_http_dir = directory
	_server_pid = OS.create_process("python3", [
		"-m", "http.server", str(port),
		"--directory", directory,
		"--bind", "127.0.0.1",
	])
	if _server_pid <= 0:
		print("  http.server: spawn failed")
		return false

	# Stage 1: TCP socket open?
	var iters: int = max(1, int(timeout_sec * 10))
	var sock_up := false
	for i in range(iters):
		await _tree.create_timer(0.1).timeout
		var out: Array = []
		var rc := OS.execute("bash", ["-c",
			"exec 3<>/dev/tcp/127.0.0.1/%d 2>/dev/null && echo up && exec 3<&-" % port],
			out, true)
		if rc == 0 and out.size() > 0 and "up" in str(out[0]):
			sock_up = true
			break
	if not sock_up:
		print("  http.server: TCP port %d didn't accept connections in %.1fs" % [port, timeout_sec])
		return false

	# Stage 2: HTTP request returns 200/403/404 (proves the server is HTTP,
	# not a leftover process from a different protocol).
	var probe := HTTPRequest.new()
	probe.timeout = 5.0
	_tree.root.add_child(probe)
	var err := probe.request("http://127.0.0.1:%d/" % port)
	if err != OK:
		probe.queue_free()
		print("  http.server: HTTPRequest.request returned %d" % err)
		return false
	var result: Array = await probe.request_completed
	probe.queue_free()
	if result[1] in [200, 403, 404]:
		return true
	print("  http.server: HTTP probe returned status %d (expected 200/403/404)" % result[1])
	return false


func stop_http_server() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		_server_pid = -1


# Pick a port in the 30000-50000 ephemeral-ish range, time-seeded to avoid
# collision with orphaned http.server processes from prior killed test runs.
func random_high_port() -> int:
	return 30000 + (Time.get_ticks_msec() % 20000)


# ---------------------------------------------------------------------------
# Real-release tarball download (GH redirect-aware)
# ---------------------------------------------------------------------------

# download_release_tarball downloads
#   https://github.com/<repo>/releases/download/<tag>/<asset_name>
# to cache_dir/<asset_name>, following GH's redirect to S3. Cache-by-existence:
# if the file already exists at the destination it's reused (size > 0 check).
#
# Returns Dictionary {ok: bool, path?: String, error?: String}.
func download_release_tarball(repo: String, tag: String, asset_name: String,
		cache_dir: String, timeout_sec: float = 120.0) -> Dictionary:
	mkdir_recursive(cache_dir)
	var dest_rel := cache_dir.rstrip("/") + "/" + asset_name
	var dest_abs := ProjectSettings.globalize_path(dest_rel) if dest_rel.begins_with("user://") or dest_rel.begins_with("res://") else dest_rel

	# Cache hit?
	if FileAccess.file_exists(dest_abs):
		var f := FileAccess.open(dest_abs, FileAccess.READ)
		if f != null:
			var sz := f.get_length()
			f.close()
			if sz > 1024:  # > 1KB sanity (real bundles are 10MB+)
				return {"ok": true, "path": dest_abs, "cached": true}
		# Otherwise fall through and re-download

	var url := "https://github.com/%s/releases/download/%s/%s" % [repo, tag, asset_name]
	var req := HTTPRequest.new()
	req.timeout = timeout_sec
	req.download_file = dest_abs
	_tree.root.add_child(req)
	var err := req.request(url)
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "HTTPRequest.request init failed: %d" % err}
	var result: Array = await req.request_completed
	# result = [result_code, http_status, headers, body]
	var result_code: int = result[0]
	var http_status: int = result[1]
	req.queue_free()

	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "HTTPRequest result_code=%d status=%d url=%s" % [result_code, http_status, url]}
	if http_status != 200:
		# 404 means the asset doesn't exist (wrong tag/name).
		return {"ok": false, "error": "HTTP %d url=%s" % [http_status, url]}
	# Verify the downloaded file looks real (size > 1KB).
	var f2 := FileAccess.open(dest_abs, FileAccess.READ)
	if f2 == null:
		return {"ok": false, "error": "downloaded file missing at %s" % dest_abs}
	var sz2 := f2.get_length()
	f2.close()
	if sz2 < 1024:
		return {"ok": false, "error": "downloaded file too small: %d bytes" % sz2}
	return {"ok": true, "path": dest_abs, "cached": false, "size": sz2}


# Map current host platform to the release-asset triple used by minerva-plugins
# release names. The plugins repo's cad.yml currently produces:
#   cad-<ver>-linux-x86_64.tar.gz
#   cad-<ver>-linux-arm64.tar.gz
#   cad-<ver>-macos-universal.tar.gz   (lipo'd arm64+amd64)
#   cad-<ver>-windows-x86_64.tar.gz
# Returns "" if the host platform doesn't have a corresponding release asset.
func release_triple_for_host() -> String:
	var os_name := OS.get_name()
	if os_name == "Linux":
		return "linux-arm64" if OS.has_feature("arm64") else "linux-x86_64"
	if os_name == "macOS":
		# CAD ships a universal binary that runs on both arm64 and amd64.
		return "macos-universal"
	if os_name == "Windows":
		return "windows-x86_64"
	return ""


# ---------------------------------------------------------------------------
# PluginManager / MarketplaceClient bootstrap
# ---------------------------------------------------------------------------

# bootstrap_plugin_manager waits for SingletonObject to be available, then
# instantiates a PluginManager attached to the tree root. Returns the
# PluginManager instance or null on failure.
func bootstrap_plugin_manager() -> Node:
	await _tree.process_frame
	var so = _tree.root.get_node_or_null("SingletonObject")
	if so != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await _tree.create_timer(0.1).timeout

	var pm_cls = load(PLUGIN_MANAGER_GD)
	if pm_cls == null:
		print("  bootstrap: could not load PluginManager.gd")
		return null
	var pm = pm_cls.new()
	_tree.root.add_child(pm)
	await _tree.process_frame
	if pm._db == null:
		print("  bootstrap: PluginManager did not initialise (no _db)")
		return null
	return pm


# Scrub any prior registration for plugin_id so a fresh install runs clean.
# Stops the plugin if it's running; removes the DB entry; nukes the install dir.
func scrub_plugin(pm: Node, plugin_id: String) -> void:
	if pm._db.has_plugin(plugin_id):
		print("  scrubbing pre-existing %s registration" % plugin_id)
		if pm._db.get_by_id(plugin_id).state == S_RUNNING:
			await pm.stop_plugin(plugin_id)
		pm._db.remove(plugin_id)
	rm_dir_recursive("user://plugins/%s" % plugin_id)


# Instantiate MarketplaceClient attached to tree root. Returns the instance.
func make_marketplace_client() -> Node:
	var mc_cls = load(MARKETPLACE_GD)
	var mc = mc_cls.new()
	_tree.root.add_child(mc)
	return mc


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

# Clean up resources owned by the helper. Test files should also scrub their
# own plugin DB entries via scrub_plugin() before exit.
func teardown() -> void:
	stop_http_server()
	if not _http_dir.is_empty():
		# Only rm if the dir looks like a temp staging dir (under
		# OS.get_user_data_dir or user://). Don't rm a user-supplied serve dir.
		var udd := OS.get_user_data_dir()
		if _http_dir.begins_with(udd) or _http_dir.begins_with(ProjectSettings.globalize_path("user://")):
			OS.execute("rm", ["-rf", _http_dir], [], true)
