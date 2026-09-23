extends SceneTree
## PluginInstallQueue with a real PluginManager and PluginDB, archives served
## over local HTTP (one throttled so installs overlap in time if the queue
## let them):
##
##   - installs run one at a time, in request order;
##   - a repeat request by registry entry or by URL attaches to the
##     unfinished job instead of starting another;
##   - cancelling a queued job ends it without creating staging; cancelling
##     a downloading job removes its staging;
##   - cancel is refused once registration begins, and the job then reports
##     the install that actually happened (id, version, outcome);
##   - an autostarting plugin ends Ready only once it is running; one whose
##     binary is missing ends start_failed, and its retry runs in the queue
##     without capturing a new install request.
##
## A job outliving the dialog that started it is covered against the real
## dialog scene in test_marketplace_browse.gd.
##
## Run: godot --headless --path src --script test/test_plugin_install_queue.gd

const HELPERS_GD := "res://test/marketplace_test_helpers.gd"
const JOB_GD := "res://Scripts/Services/Plugins/PluginInstallJob.gd"
const THROTTLED_PY := "res://test/fixtures/throttled_http_server.py"
const PROBE_PY := "res://test/fixtures/capability_probe/capability_probe.py"
const SLOW := "test_queue_slow"
const FAST := "test_queue_fast"
const READY := "test_queue_ready"
const NO_BINARY := "test_queue_no_binary"
const SLOW_BYTES := 3 * 1024 * 1024

var _h
var _pm: Node
var _temp := ""
var _fast_url := ""
var _slow_url := ""
var _slow_server := -1
var _fail := 0
var Job = load(JOB_GD)


func _init() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL: timed out")
		_finish(1))
	await process_frame
	_h = load(HELPERS_GD).new(self)
	_temp = "%s/test_install_queue_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	var sha := "sha256sum" if _h.have_cmd("sha256sum") else "shasum -a 256"
	var port: int = _h.random_high_port()
	_fast_url = "http://127.0.0.1:%d/%s.tar.gz" % [port, FAST]
	_slow_url = "http://127.0.0.1:%d/%s.tar.gz" % [port + 1, SLOW]
	_pm = await _h.bootstrap_plugin_manager()
	var ready: bool = _pm != null and _pack(FAST, 0, sha) and _pack(SLOW, SLOW_BYTES, sha) \
		and _pack(READY, 0, sha, {"entrypoint": "python3", "args": ["capability_probe.py"]}, true) \
		and _pack(NO_BINARY, 0, sha, {"entrypoint": "./missing-binary", "args": []}) \
		and await _h.start_http_server(_temp, port)
	if ready:
		# ~3 s per download of the slow archive.
		_slow_server = OS.create_process("python3", [ProjectSettings.globalize_path(THROTTLED_PY),
			_temp.path_join(SLOW + ".tar.gz"), str(port + 1), "--rate", "1048576"])
		ready = await _port_open(port + 1)
	if not ready:
		print("FAIL: fixture setup")
		_finish(1)
		return

	await _test_serial_order_and_duplicate_collapse()
	await _test_cancel_queued_and_downloading()
	await _test_cancel_refused_during_registration()
	await _test_start_outcomes_and_retry(port)
	_finish(1 if _fail else 0)


func _test_serial_order_and_duplicate_collapse() -> void:
	await _scrub()
	var queue = _pm.install_queue
	var events: Array[String] = []
	var overlap := [false]
	var watch := func(job) -> void:
		events.append("%s:%s" % [job.plugin_id(), job.state])
		var running: Array = queue.jobs().filter(func(j) -> bool: return j.state == Job.State.RUNNING)
		overlap[0] = overlap[0] or running.size() > 1
	queue.job_changed.connect(watch)

	var slow = queue.request(_entry(SLOW, _slow_url))
	var fast = queue.request(_entry(FAST, _fast_url))
	_check(queue.request(_entry(SLOW, _slow_url)) == slow, "a repeat registry request attaches to the unfinished job")
	_check(queue.request_url(_slow_url, true) == slow, "an MCP URL request attaches to the same job")
	await fast.finished
	queue.job_changed.disconnect(watch)
	_check(slow.state == Job.State.DONE and not overlap[0], "installs never overlapped; the first finished first: %s" % [events])
	_check(slow.outcome == Job.OUTCOME_INSTALLED and fast.outcome == Job.OUTCOME_INSTALLED,
		"both installed: %s / %s" % [slow.summary(), fast.summary()])
	_check(queue.request(_entry(FAST, _fast_url)) != fast, "a request after the job finished starts a new job")
	await queue.job_for(FAST).finished


func _test_cancel_queued_and_downloading() -> void:
	await _scrub()
	var queue = _pm.install_queue
	var slow = queue.request(_entry(SLOW, _slow_url))
	var fast = queue.request(_entry(FAST, _fast_url))
	_check(queue.cancel(fast), "a queued job can be cancelled")
	_check(fast.outcome == Job.OUTCOME_CANCELLED and fast.op.staging_dir.is_empty(),
		"it ends cancelled without ever creating staging")
	var give_up := Time.get_ticks_msec() + 20000
	while slow.op.done < 65536 and Time.get_ticks_msec() < give_up:
		await process_frame
	_check(queue.cancel(slow), "a downloading job can be cancelled")
	await slow.finished
	_check(slow.outcome == Job.OUTCOME_CANCELLED and not DirAccess.dir_exists_absolute(slow.op.staging_dir),
		"it ends cancelled and its staging is gone: %s" % [slow.summary()])
	_check(not _pm.get_db().has_plugin(SLOW) and not _pm.get_db().has_plugin(FAST), "nothing was registered")


func _test_cancel_refused_during_registration() -> void:
	await _scrub()
	var queue = _pm.install_queue
	var job = queue.request(_entry(FAST, _fast_url))
	var refused := [true]
	job.op.stage_changed.connect(func(stage: String) -> void:
		if stage == "register":
			refused[0] = not queue.cancel(job))
	await job.finished
	_check(refused[0], "cancel is refused once registration has begun")
	_check(job.outcome == Job.OUTCOME_INSTALLED and job.result.get("plugin_id") == FAST \
		and job.result.get("version") == "1.0.0" and _pm.get_db().has_plugin(FAST),
		"the job reports the install that happened: %s" % [job.summary()])


func _test_start_outcomes_and_retry(port: int) -> void:
	await _scrub()
	var queue = _pm.install_queue
	var ready_url := "http://127.0.0.1:%d/%s.tar.gz" % [port, READY]
	var nobin_url := "http://127.0.0.1:%d/%s.tar.gz" % [port, NO_BINARY]
	var started = queue.request(_entry(READY, ready_url))
	await started.finished
	_check(started.outcome == Job.OUTCOME_READY and _pm.get_db().get_by_id(READY).state == _pm.S_RUNNING,
		"an autostarting plugin is Ready once it runs: %s" % [started.summary()])
	_pm.stop_plugin(READY)

	var failed = queue.request(_entry(NO_BINARY, nobin_url))
	await failed.finished
	_check(failed.outcome == Job.OUTCOME_START_FAILED and not failed.message.is_empty(),
		"a missing binary ends start_failed with the reason: %s" % [failed.summary()])
	queue.retry_start(failed)
	var reinstall = queue.request(_entry(NO_BINARY, nobin_url))
	_check(reinstall != failed, "a new install request does not attach to a start retry")
	await failed.finished
	_check(failed.outcome == Job.OUTCOME_START_FAILED, "the retry ran and reported again")
	await reinstall.finished


func _entry(id: String, url: String) -> Dictionary:
	return {"id": id, "version": "1.0.0",
		"downloads": {MarketplaceClient.resolve_platform_target(): url}}


func _scrub() -> void:
	for id in [SLOW, FAST, READY, NO_BINARY]:
		await _h.scrub_plugin(_pm, id)


func _port_open(port: int) -> bool:
	for i in 50:
		if OS.execute("bash", ["-c", "exec 3<>/dev/tcp/127.0.0.1/%d" % port]) == 0:
			return true
		await create_timer(0.1).timeout
	return false


## Archive `<id>.tar.gz` in the temp dir: manifest, placeholder binary
## (or the capability probe when `backend` launches python3), optional random
## payload, SHA256SUMS.
func _pack(id: String, payload_bytes: int, sha: String,
		backend: Dictionary = {"entrypoint": "./test-binary", "args": []}, autostart: bool = false) -> bool:
	var dir := _temp.path_join(id)
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"id": id, "name": id, "version": "1.0.0", "host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": backend.entrypoint, "args": backend.args},
		"tools": [], "ui": {"panels": [], "ipc_messages": []},
		"permissions": {"host_capabilities": []}, "autostart": autostart, "auto_reload": false,
	}))
	f.close()
	if backend.entrypoint == "python3":
		DirAccess.copy_absolute(ProjectSettings.globalize_path(PROBE_PY), dir.path_join("capability_probe.py"))
	elif backend.entrypoint == "./test-binary":
		f = FileAccess.open(dir.path_join("test-binary"), FileAccess.WRITE)
		f.store_string("PLACEHOLDER")
		f.close()
	if payload_bytes > 0:
		f = FileAccess.open(dir.path_join("payload.bin"), FileAccess.WRITE)
		f.store_buffer(Crypto.new().generate_random_bytes(payload_bytes))
		f.close()
	return _h.run_cmd("bash", ["-c", "cd '%s' && %s $(ls) > SHA256SUMS && tar -czf ../%s.tar.gz ." % [dir, sha, id]])


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1


func _finish(code: int) -> void:
	if _pm != null:
		for id in [SLOW, FAST, READY, NO_BINARY]:
			if _pm.get_db().has_plugin(id):
				_pm.stop_plugin(id)
				_pm.get_db().remove(id)
			_h.rm_dir_recursive("user://plugins/" + id)
	if _slow_server > 0:
		OS.kill(_slow_server)
	_h.teardown()
	OS.execute("rm", ["-rf", _temp])
	print("=== %s ===" % ("FAIL" if code else "PASS"))
	quit(code)
