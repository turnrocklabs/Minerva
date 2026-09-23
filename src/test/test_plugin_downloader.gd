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
const SIZE := 3 * 1024 * 1024

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

	OS.execute("rm", ["-rf", _dir])
	print("=== %s ===" % ("FAIL" if _fail else "PASS"))
	quit(1 if _fail else 0)


## Serve the source with `server_args`, download it, stop the server.
func _download(server_args: Array, stall_timeout_s: float) -> Dictionary:
	var port := 30000 + randi() % 20000
	_server_pid = OS.create_process("python3", [ProjectSettings.globalize_path(SERVER_PY), _source, str(port)] + server_args)
	for i in 50:
		if OS.execute("bash", ["-c", "exec 3<>/dev/tcp/127.0.0.1/%d" % port]) == 0:
			break
		await create_timer(0.1).timeout
	# The probe alone would accept a port some other process already held.
	if not OS.is_process_running(_server_pid):
		return {"result": {"ok": false, "error": "fixture server failed to start on %d" % port}, "path": ""}
	var downloader = load(DOWNLOADER_GD).new()
	downloader.stall_timeout_s = stall_timeout_s
	var path := "%s/dl_%d.bin" % [_dir, port]
	var result: Dictionary = await downloader.download("http://127.0.0.1:%d/plugin.tar.gz" % port, path, self)
	if _server_pid > 0:
		OS.kill(_server_pid)
	return {"result": result, "path": path}


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1
