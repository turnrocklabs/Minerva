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
# codetools local-bundle fixture
#
# Shared by the two codetools functional tests
# (test_marketplace_install_start_codetools.gd + test_codetools_panel_gate.gd).
# Both build the SAME artifact a user installs — a host go binary that embeds
# the PBS runtime bundle, packed with manifest.json + SHA256SUMS into
# codetools-fixture.tar.gz at the temp-dir root. The only divergence is
# include_ui, which stages the ui/ panel scripts the panel gate mounts (the
# pure-backend install test omits them). DRY-debt 019e7b86ab.
# ---------------------------------------------------------------------------

func have_cmd(name: String) -> bool:
	return OS.execute("bash", ["-c", "command -v %s >/dev/null 2>&1" % name], [], true) == 0


func file_ge(path: String, min_bytes: int) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var sz := f.get_length()
	f.close()
	return sz >= min_bytes


# Map host OS+arch to the EMBEDDED-bundle triple (NOT the macos-universal
# release name — local single-arch builds embed one arch's bundle). Returns ""
# when the host has no codetools target (e.g. linux-arm64 ships no
# embed_linux_arm64.go), so callers SKIP cleanly rather than fail go build.
func host_bundle_triple() -> String:
	match OS.get_name():
		"macOS":
			return "macos-arm64" if OS.has_feature("arm64") else "macos-amd64"
		"Linux":
			return "" if OS.has_feature("arm64") else "linux-x86_64"
		"Windows":
			return "windows-x86_64"
	return ""


# Resolve the plugin data dir the way the Go shim's runtime.DataDir() does, then
# remove the extracted-runtime cache under it so the next start re-extracts the
# freshly-built bundle (defeats the version-keyed EnsureRuntime cache).
func clear_runtime_cache(plugin_id: String) -> void:
	var data_dir := OS.get_environment("MINERVA_PLUGIN_DATA_DIR")
	if data_dir == "":
		var base := ""
		match OS.get_name():
			"Windows":
				base = OS.get_environment("APPDATA")
			"macOS":
				base = OS.get_environment("HOME") + "/Library/Application Support"
			_:
				var xdg := OS.get_environment("XDG_DATA_HOME")
				base = xdg if xdg != "" else OS.get_environment("HOME") + "/.local/share"
		data_dir = "%s/Minerva/plugins/%s" % [base, plugin_id]
	if data_dir != "":
		OS.execute("rm", ["-rf", data_dir + "/runtime"], [], true)


# Build the codetools install fixture into temp_dir (caller owns temp_dir
# lifecycle). Returns {ok: true} on success, {ok: false, skip: <reason>} when
# the host can't produce a bundle (caller should SKIP), or {ok: false,
# fail: <reason>} on a real build error (caller should FAIL).
func build_codetools_fixture(src_dir: String, triple: String, temp_dir: String,
		binary_name: String, include_ui: bool = false) -> Dictionary:
	# Ensure an embedded bundle exists so go:embed compiles a real (Tier-1)
	# binary — the exact artifact users install. Build it if absent (PBS
	# download is cached after the first run).
	var bundle := "%s/internal/runtime/bundle/runtime-bundle-%s.tar.zst" % [src_dir, triple]
	if not file_ge(bundle, 1024 * 1024):
		var repo_root := src_dir.get_base_dir()  # ~/github/minerva-plugins
		var build_script := "%s/scripts/build-python-runtime-bundle.sh" % repo_root
		print("  bundle absent — building %s (cached PBS after first run)…" % triple)
		if not run_cmd("bash", [build_script, src_dir, triple]):
			return {"ok": false, "skip": "could not build embedded bundle for %s" % triple}
		if not file_ge(bundle, 1024 * 1024):
			return {"ok": false, "skip": "bundle build produced no usable tarball at %s" % bundle}

	if not mkdir_recursive(temp_dir):
		return {"ok": false, "fail": "could not make temp dir %s" % temp_dir}
	var pack := "%s/pack" % temp_dir
	mkdir_recursive(pack)

	# go build the real binary (host GOOS/GOARCH, embeds the bundle).
	print("  go build %s (embeds %s bundle)…" % [binary_name, triple])
	if not run_cmd("bash", ["-c",
			"cd '%s' && go build -o '%s/%s' ." % [src_dir, pack, binary_name]]):
		return {"ok": false, "fail": "go build"}
	if not run_cmd("cp", ["-p", src_dir + "/manifest.json", pack.path_join("manifest.json")]):
		return {"ok": false, "fail": "copy manifest"}

	# Stage the ui/ panel scripts only when the consumer mounts a panel.
	if include_ui:
		if DirAccess.dir_exists_absolute(src_dir + "/ui"):
			if not run_cmd("cp", ["-r", src_dir + "/ui", pack.path_join("ui")]):
				return {"ok": false, "fail": "copy ui/ directory"}
			print("  copied ui/ directory to fixture")
		else:
			print("  WARN: no ui/ directory in source — panel mount will fail")

	# SHA256SUMS in the marketplace-verifier format (works on Linux + macOS).
	if not run_cmd("bash", ["-c",
			"cd '%s' && (command -v sha256sum >/dev/null 2>&1 && sha256sum %s manifest.json || shasum -a 256 %s manifest.json) > SHA256SUMS"
			% [pack, binary_name, binary_name]]):
		return {"ok": false, "fail": "sha256sum"}

	# Pack into ../codetools-fixture.tar.gz (served at the temp-dir root).
	if not run_cmd("bash", ["-c",
			"cd '%s' && tar -czf ../codetools-fixture.tar.gz ." % pack]):
		return {"ok": false, "fail": "tar"}
	return {"ok": true}


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
