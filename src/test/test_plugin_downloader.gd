extends SceneTree
## PluginDownloader against a real local server that throttles, drops, and
## stalls (test/fixtures/throttled_http_server.py):
##
##   - a throttled transfer lasting longer than the stall timeout, dropped once
##     mid-stream, resumes by Range and the file's SHA-256 matches the source;
##   - a server that stops sending fails with download_stalled and leaves no
##     partial file;
##   - a drop from a server that ignores Range fails with
##     download_resume_unsupported and leaves no partial file.
##
## Run: godot --headless --path src --script test/test_plugin_downloader.gd

const DOWNLOADER_GD := "res://Scripts/Services/Plugins/PluginDownloader.gd"
const SERVER_PY := "res://test/fixtures/throttled_http_server.py"
const HELPERS_GD := "res://test/marketplace_test_helpers.gd"
const SIZE := 3 * 1024 * 1024
const FIXTURE_READY_MS := 30000

var _dir := ""
var _source := ""
var _server_pid := -1
var _fail := 0


func _init() -> void:
	# A regressed stall timeout would otherwise hang the run instead of failing it.
	create_timer(120.0).timeout.connect(func() -> void:
		print("FAIL: timed out")
		if _server_pid > 0:
			OS.kill(_server_pid)  # kill(-1) would signal every process we own
		quit(1))
	await process_frame
	_dir = "%s/test_plugin_downloader_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	DirAccess.make_dir_recursive_absolute(_dir)
	_source = _dir + "/source.bin"
	var f := FileAccess.open(_source, FileAccess.WRITE)
	f.store_buffer(Crypto.new().generate_random_bytes(SIZE))
	f.close()

	# ~3 s at 1 MiB/s against a 1.5 s stall timeout: only a stall timeout,
	# never a total one, lets this finish.
	var resumed := await _download(["--rate", "1048576", "--drop-after", "1048576"], 1.5)
	_check(resumed.result.get("ok", false), "throttled + dropped transfer completes: %s" % resumed.result)
	_check(FileAccess.get_sha256(resumed.path) == FileAccess.get_sha256(_source), "resumed file matches the source SHA-256")

	var stalled := await _download(["--stall-after", "262144"], 1.0)
	_check(stalled.result.get("error", "") == "download_stalled", "stalled server reports download_stalled: %s" % stalled.result)
	_check(not FileAccess.file_exists(stalled.path), "stalled download leaves no partial file")

	var no_range := await _download(["--no-range", "--drop-after", "1048576"], 5.0)
	_check(no_range.result.get("error", "") == "download_resume_unsupported", "drop without Range support reports download_resume_unsupported: %s" % no_range.result)
	_check(not FileAccess.file_exists(no_range.path), "unresumable download leaves no partial file")

	load(HELPERS_GD).remove_tree(_dir)
	print("=== %s ===" % ("FAIL" if _fail else "PASS"))
	quit(1 if _fail else 0)


## Serve the source with `server_args`, download it, stop the server.
func _download(server_args: Array, stall_timeout_s: float) -> Dictionary:
	var helpers = load(HELPERS_GD)
	# Let the OS reserve the port, rather than racing a random port selection.
	var ready_path := "%s/fixture-ready-%d.json" % [_dir, Time.get_ticks_msec()]
	var process: Dictionary = OS.execute_with_pipe(helpers.python_cmd(),
		[ProjectSettings.globalize_path(SERVER_PY), _source, "0", "--ready-file", ready_path] + server_args, false)
	_server_pid = process.get("pid", -1)
	var port := 0
	var stderr := ""
	var began := Time.get_ticks_msec()
	while _server_pid > 0 and Time.get_ticks_msec() - began < FIXTURE_READY_MS:
		stderr = (stderr + _fixture_output(process.stderr)).right(4096)
		if not OS.is_process_running(_server_pid):
			break
		# macOS does not reliably expose pipe bytes while the server is alive.
		if FileAccess.file_exists(ready_path):
			var ready: Variant = JSON.parse_string(FileAccess.get_file_as_string(ready_path))
			if ready is Dictionary:
				port = int(ready.get("port", 0))
			if port > 0 and port <= 65535:
				break
		await create_timer(0.1).timeout
	print("Fixture startup: port=%d elapsed_ms=%d" % [port, Time.get_ticks_msec() - began])
	if port <= 0 or port > 65535 or not OS.is_process_running(_server_pid):
		var error := "fixture server failed to start: pid=%d stderr=%s" % [_server_pid, stderr]
		_close_fixture(process, ready_path)
		return {"result": {"ok": false, "error": error}, "path": ""}
	var downloader = load(DOWNLOADER_GD).new()
	downloader.stall_timeout_s = stall_timeout_s
	var path := "%s/dl_%d.bin" % [_dir, port]
	var result: Dictionary = await downloader.download("http://127.0.0.1:%d/plugin.tar.gz" % port, path, self)
	_close_fixture(process, ready_path)
	return {"result": result, "path": path}


func _fixture_output(pipe: FileAccess) -> String:
	var available := mini(pipe.get_length(), 4096)
	return pipe.get_buffer(available).get_string_from_utf8() if available > 0 else ""


func _close_fixture(process: Dictionary, ready_path: String) -> void:
	if _server_pid > 0 and OS.is_process_running(_server_pid):
		OS.kill(_server_pid)
	_server_pid = -1
	for key in ["stdio", "stderr"]:
		if process.has(key):
			process[key].close()
	for path in [ready_path, ready_path + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1
