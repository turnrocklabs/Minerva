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
##   - a new install is not started (autostart is the user's persisted
##     preference, off until set, never the manifest's), and an update of a
##     stopped plugin leaves it stopped even with Auto-start on;
##   - reinstalling a running plugin stops it before its files are replaced
##     and ends Ready with it running again; an upgrade that fails to start,
##     or is cancelled while starting, is rolled back to the running copy,
##     its data included;
##   - an update of a stopped plugin stays stopped and keeps the working
##     copy until its first start, which rolls a failing version back and
##     starts the previous one, keeping the user's later choices;
##   - minerva_plugin_marketplace_install (the real MCP handler) attaches to
##     a dialog's queued install, returns its result, and does not change the
##     confirmation choice the dialog's request was made with;
##   - once a URL-only install reveals its plugin, a queued request for the
##     same version joins it and one for another version ends as a conflict;
##   - an MCP install that outlasts its wait answers running with a job id,
##     and minerva_plugin_marketplace_job follows that job to its result
##     without starting another; unknown ids, and ids from another queue,
##     are errors there;
##   - at launch, an opted-in marketplace plugin is updated to a newer
##     registry release, and one not opted in is left alone.
##
## A job outliving the dialog that started it is covered against the real
## dialog scene in test_marketplace_browse.gd.
##
## Run: godot --headless --path src --script test/test_plugin_install_queue.gd

const HELPERS_GD := "res://test/marketplace_test_helpers.gd"
const JOB_GD := "res://Scripts/Services/Plugins/PluginInstallJob.gd"
const MCP_TOOLS_GD := "res://Scripts/Services/Plugins/PluginMCPTools.gd"
const THROTTLED_PY := "res://test/fixtures/throttled_http_server.py"
const PROBE_PY := "res://test/fixtures/capability_probe/capability_probe.py"
const SLOW := "test_queue_slow"
const FAST := "test_queue_fast"
const READY := "test_queue_ready"
const PENDING := "test_queue_pending"
const SLOW_BYTES := 3 * 1024 * 1024
# Bare interpreter names, which the host's SubProcess finds on PATH (Windows
# installs `python`, not `python3`).
var PYTHON: String = load(HELPERS_GD).python_cmd()
var PROBE := {"entrypoint": PYTHON, "args": ["capability_probe.py"]}

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
	var port: int = _h.random_high_port()
	_fast_url = "http://127.0.0.1:%d/%s.tar.gz" % [port, FAST]
	_slow_url = "http://127.0.0.1:%d/%s.tar.gz" % [port + 1, SLOW]
	_pm = await _h.bootstrap_plugin_manager(true)
	var ready: bool = _pm != null and _pack(FAST, 0) and _pack(SLOW, SLOW_BYTES) \
		and _pack(READY, 0, PROBE) \
		and _pack(READY, 0, PROBE, {"version": "1.0.1", "ui": {"panels": ["not-a-panel"], "ipc_messages": []}},
			"ready_unregistrable") \
		and _pack(READY, 0, {"entrypoint": PYTHON, "args": ["crash.py"]}, {"version": "1.0.1"}, "ready_crashes") \
		and _pack(FAST, 0, {"entrypoint": "./test-binary", "args": []}, {"version": "1.0.1"}, "fast_101") \
		and _pack(PENDING, 0, PROBE) \
		and _pack(PENDING, 0, {"entrypoint": PYTHON, "args": ["crash.py"]}, {"version": "1.0.1"}, "pending_bad") \
		and await _h.start_http_server(_temp, port)
	if ready:
		# ~3 s per download of the slow archive.
		_slow_server = OS.create_process(PYTHON, [ProjectSettings.globalize_path(THROTTLED_PY),
			_temp.path_join(SLOW + ".tar.gz"), str(port + 1), "--rate", "1048576"])
		ready = await _port_open(port + 1)
	if not ready:
		print("FAIL: fixture setup")
		_finish(1)
		return

	await _test_serial_order_and_duplicate_collapse()
	await _test_cancel_queued_and_downloading()
	await _test_cancel_refused_during_registration()
	await _test_update_of_stopped_plugin_leaves_it_stopped(port)
	await _test_running_plugin_is_restarted_on_update(port)
	await _test_failed_upgrade_rolls_back_to_the_running_copy(port)
	await _test_stopped_upgrade_waits_for_its_first_start(port)
	await _test_start_cancel_and_failed_restart(port)
	await _test_mcp_attach_keeps_the_first_requests_choices()
	await _test_url_install_absorbs_or_refuses_queued_duplicates()
	await _test_startup_auto_update(port)
	await _test_mcp_install_outlasting_its_wait_is_followed_by_job_id()
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
	await _done(fast)
	queue.job_changed.disconnect(watch)
	_check(slow.state == Job.State.DONE and not overlap[0], "installs never overlapped; the first finished first: %s" % [events])
	_check(slow.outcome == Job.OUTCOME_INSTALLED and fast.outcome == Job.OUTCOME_INSTALLED,
		"both installed: %s / %s" % [slow.summary(), fast.summary()])
	_check(queue.request(_entry(FAST, _fast_url)) != fast, "a request after the job finished starts a new job")
	await _done(queue.job_for(FAST))


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
	await _done(slow)
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
	await _done(job)
	_check(refused[0], "cancel is refused once registration has begun")
	_check(job.outcome == Job.OUTCOME_INSTALLED and job.result.get("plugin_id") == FAST \
		and job.result.get("version") == "1.0.0" and _pm.get_db().has_plugin(FAST),
		"the job reports the install that happened: %s" % [job.summary()])


func _test_update_of_stopped_plugin_leaves_it_stopped(port: int) -> void:
	await _scrub()
	var queue = _pm.install_queue
	var ready_url := "http://127.0.0.1:%d/%s.tar.gz" % [port, READY]
	var first = await _installed_then_autostart(READY, ready_url)
	_check(first.outcome == Job.OUTCOME_INSTALLED and _pm.get_db().get_by_id(READY).state != _pm.S_RUNNING,
		"a new install is installed, not started: %s" % [first.summary()])
	var again = queue.request(_entry(READY, ready_url))
	await _done(again)
	_check(again.outcome == Job.OUTCOME_INSTALLED and _pm.get_db().get_by_id(READY).state != _pm.S_RUNNING,
		"an update of a stopped plugin leaves it stopped, even with Auto-start on: %s" % [again.summary()])


## An upgrade of a running plugin is started before it commits. A new
## version that exits before its handshake is rolled back: the previous
## version is installed and running again, and what its start did to the
## plugin's data (written here when the start stage begins, standing in for
## a migration) is undone.
func _test_failed_upgrade_rolls_back_to_the_running_copy(port: int) -> void:
	var queue = _pm.install_queue
	_pm.start_plugin(READY)
	await _until(func() -> bool: return _pm.get_db().get_by_id(READY).state == _pm.S_RUNNING)
	var data := ProjectSettings.globalize_path("user://plugins/data").path_join(READY)
	DirAccess.make_dir_recursive_absolute(data)
	_write_text(data.path_join("state.txt"), "before")
	var job = queue.request_url("http://127.0.0.1:%d/ready_crashes.tar.gz" % port)
	job.op.stage_changed.connect(func(stage: String) -> void:
		if stage == "start":
			_write_text(data.path_join("state.txt"), "migrated")
			_write_text(data.path_join("added.txt"), "new"))
	await _done(job)
	var def = _pm.get_db().get_by_id(READY)
	_check(job.stopped_for_replace and job.outcome == Job.OUTCOME_FAILED and "did not start" in job.message \
		and def.version == "1.0.0" and def.state == _pm.S_RUNNING,
		"a new version that fails to start leaves the previous one installed and running: %s" % [job.summary()])
	_check(FileAccess.get_file_as_string(data.path_join("state.txt")) == "before" \
		and not FileAccess.file_exists(data.path_join("added.txt")),
		"and the data its start changed is put back")
	_pm.stop_plugin(READY)


## An update of a plugin the user left stopped keeps it stopped and keeps
## the working copy it replaced. The first start then decides: here the new
## version exits before its handshake, so the previous version is put back
## and started, and a choice the user made after the update (autostart)
## survives the rollback.
func _test_stopped_upgrade_waits_for_its_first_start(port: int) -> void:
	var queue = _pm.install_queue
	await _done(queue.request(_entry(PENDING, "http://127.0.0.1:%d/%s.tar.gz" % [port, PENDING])))
	var update = queue.request_url("http://127.0.0.1:%d/pending_bad.tar.gz" % port)
	await _done(update)
	_check(update.outcome == Job.OUTCOME_INSTALLED and _pm.get_db().get_by_id(PENDING).state != _pm.S_RUNNING,
		"an update of a stopped plugin installs without starting it: %s" % [update.summary()])
	_check(_pm.get_db().set_autostart(PENDING, true), "the user turns autostart on after the update")
	var started: Dictionary = await _pm.start_plugin(PENDING)
	var def = _pm.get_db().get_by_id(PENDING)
	_check(not started.has("error") and str(started.get("rolled_back", {}).get("version", "")) == "1.0.1" \
		and def.version == "1.0.0" and def.state == _pm.S_RUNNING and def.autostart,
		"its first start fails, so the previous version is put back and started, autostart kept: %s" % [started])
	_pm.stop_plugin(PENDING)


## Cancel an update of a running plugin while its new version starts, and a
## rollback whose restart of the old version fails, with the real probe
## plugin.
func _test_start_cancel_and_failed_restart(port: int) -> void:
	var queue = _pm.install_queue
	var ready_url := "http://127.0.0.1:%d/%s.tar.gz" % [port, READY]
	_pm.start_plugin(READY)
	await _until(func() -> bool: return _pm.get_db().get_by_id(READY).state == _pm.S_RUNNING)
	var cancelled = queue.request(_entry(READY, ready_url))
	cancelled.op.stage_changed.connect(func(stage: String) -> void:
		if stage == "start":
			queue.cancel(cancelled))
	await _done(cancelled)
	_check(cancelled.outcome == Job.OUTCOME_CANCELLED and "while it started" in cancelled.message \
		and _pm.get_db().get_by_id(READY).state == _pm.S_RUNNING,
		"cancelling an update of a running plugin while it starts puts the previous copy back, running: %s" % [cancelled.summary()])

	# The installed copy breaks, so putting it back cannot start it again.
	var installed_probe := ProjectSettings.globalize_path("user://plugins/%s/capability_probe.py" % READY)
	var f := FileAccess.open(installed_probe, FileAccess.WRITE)
	f.store_string("raise SystemExit(1)\n")
	f.close()
	var broken = queue.request_url("http://127.0.0.1:%d/ready_unregistrable.tar.gz" % port)
	await _done(broken)
	_check(broken.stopped_for_replace and broken.outcome == Job.OUTCOME_FAILED and "did not restart" in broken.message \
		and _pm.get_db().get_by_id(READY).version == "1.0.0" and _pm.get_db().get_by_id(READY).state != _pm.S_RUNNING,
		"a failed update restores the old version and says it did not restart: %s" % [broken.summary()])


func _test_running_plugin_is_restarted_on_update(port: int) -> void:
	var queue = _pm.install_queue
	var ready_url := "http://127.0.0.1:%d/%s.tar.gz" % [port, READY]
	# This first start also settles the update the previous case left waiting.
	_pm.start_plugin(READY)
	await _until(func() -> bool: return _pm.get_db().get_by_id(READY).state == _pm.S_RUNNING)
	var second = queue.request(_entry(READY, ready_url))
	await _done(second)
	_check(second.stopped_for_replace and second.outcome == Job.OUTCOME_READY \
		and _pm.get_db().get_by_id(READY).state == _pm.S_RUNNING,
		"a running plugin is stopped for the update and running again after it: %s" % [second.summary()])
	_pm.stop_plugin(READY)


func _test_mcp_attach_keeps_the_first_requests_choices() -> void:
	await _scrub()
	var queue = _pm.install_queue
	var blocker = queue.request(_entry(SLOW, _slow_url))
	var dialog_job = queue.request(_entry(FAST, _fast_url), false)
	var count_before: int = queue.jobs().size()
	var tools = load(MCP_TOOLS_GD).new(_pm)
	var box := [null]
	(func() -> void: box[0] = await tools.handle_tool_call("minerva_plugin_marketplace_install",
		{"url": _fast_url, "auto_confirm_skills": true})).call()
	await process_frame
	_check(queue.jobs().size() == count_before and dialog_job.auto_confirm_skills == false,
		"the MCP request attached without changing the first request's confirmation choice")
	await _done(dialog_job)
	await _until(func() -> bool: return box[0] != null)
	_check(box[0] != null and box[0].get("outcome") == dialog_job.outcome and box[0].get("plugin_id") == FAST,
		"the MCP call returns the attached install's result: %s" % [box[0]])
	await _done(blocker)


func _test_url_install_absorbs_or_refuses_queued_duplicates() -> void:
	await _scrub()
	var queue = _pm.install_queue
	var by_url = queue.request_url(_slow_url)  # its plugin is unknown until the archive is read
	# The same plugin from the registry, under a different URL string.
	var other_url := _slow_url.replace("127.0.0.1", "localhost")
	var same = queue.request(_entry(SLOW, other_url))
	var entry := _entry(SLOW, other_url)
	entry["version"] = "9.0.0"
	var conflicting = queue.request(entry)
	_check(same != by_url and conflicting != same and conflicting.result.get("error") == "install_conflict",
		"a request contradicting a queued one for the same URL is refused at once")
	# Registry requests for the URL-only job's own URL follow it until its
	# archive shows what it holds.
	var follows_ok = queue.request(_entry(SLOW, _slow_url))
	var wrong := _entry(SLOW, _slow_url)
	wrong["version"] = "9.0.0"
	var follows_wrong = queue.request(wrong)
	_check(follows_ok != by_url and follows_ok.joined == by_url and follows_wrong.joined == by_url,
		"constrained requests follow the URL-only install instead of losing their expectations")
	await _done(by_url)
	await process_frame
	_check(follows_ok.outcome == by_url.outcome and follows_ok.result == by_url.result,
		"a follower whose expectations the archive meets ends with the install")
	_check(follows_wrong.outcome == Job.OUTCOME_FAILED and follows_wrong.result.get("error") == "install_conflict",
		"a follower expecting another version ends as a conflict: %s" % [follows_wrong.summary()])
	_check(same.state == Job.State.DONE and same.result == by_url.result and same.outcome == by_url.outcome,
		"the same-version request joined the running install and ended with it: %s" % [same.summary()])
	_check(conflicting.outcome == Job.OUTCOME_FAILED and conflicting.result.get("error") == "install_conflict",
		"the other-version request ends as a conflict: %s" % [conflicting.summary()])


# The install tool's wait stands in for the MCP request deadline: a short
# wait over the ~3 s slow archive has the call answer while it still runs.
func _test_mcp_install_outlasting_its_wait_is_followed_by_job_id() -> void:
	await _scrub()
	var queue = _pm.install_queue
	var tools = load(MCP_TOOLS_GD).new(_pm)
	var ids_before: Array = queue.jobs().map(func(j) -> String: return j.id)
	var first: Dictionary = await tools.handle_tool_call("minerva_plugin_marketplace_install",
		{"url": _slow_url, "auto_confirm_skills": true, "wait_seconds": 0.5})
	var job_id := str(first.get("job_id", ""))
	_check(first.get("done") == false and first.get("outcome") == "running" and not job_id.is_empty(),
		"an install outlasting the wait answers running with a job id: %s" % [first])
	var outcomes: Array = []
	var last := first
	var give_up := Time.get_ticks_msec() + 60000
	while last.get("done") != true and Time.get_ticks_msec() < give_up:
		last = await tools.handle_tool_call("minerva_plugin_marketplace_job", {"job_id": job_id, "wait_seconds": 0.5})
		outcomes.append(last.get("outcome"))
	_check(outcomes.has("running") and last.get("done") == true and last.get("job_id") == job_id
		and last.get("outcome") == Job.OUTCOME_INSTALLED and last.get("plugin_id") == SLOW,
		"polling the job reports it running, then its installed result: %s, %s" % [outcomes, last])
	var new_jobs: Array = queue.jobs().filter(func(j) -> bool: return not ids_before.has(j.id))
	_check(new_jobs.size() == 1 and new_jobs[0].id == job_id and _pm.get_db().has_plugin(SLOW),
		"polling never started another install: %d new job(s)" % new_jobs.size())
	var unknown: Dictionary = await tools.handle_tool_call("minerva_plugin_marketplace_job", {"job_id": "0-0"})
	_check(unknown.has("error") and not unknown.has("done"), "an unknown job id is an error: %s" % [unknown])
	# Two queues made back to back each number their first job 1; their ids
	# must still differ, so one queue never answers for another's job.
	var others: Array = []
	for i in 2:
		var other = queue.get_script().new()
		other.manager = _pm
		var queued = other.request(_entry(FAST, _fast_url))
		other.cancel(queued)  # before its deferred start
		others.append([other, queued])
	var a_id: String = others[0][1].id
	var b_id: String = others[1][1].id
	_check(a_id != b_id and others[1][0].job_by_id(a_id) == null and queue.job_by_id(a_id) == null
		and others[0][0].job_by_id(a_id) == others[0][1],
		"job ids from different queues never alias: %s / %s" % [a_id, b_id])
	await process_frame  # let the deferred starts find nothing queued
	for pair in others:
		pair[0].free()
	var fast: Dictionary = await tools.handle_tool_call("minerva_plugin_marketplace_install",
		{"url": _fast_url, "auto_confirm_skills": true})
	_check(fast.get("done") == true and fast.get("outcome") == Job.OUTCOME_INSTALLED
		and queue.job_by_id(str(fast.get("job_id", ""))) != null,
		"an install inside the wait answers with its result and job id: %s" % [fast])


## PluginAutoUpdater at launch: a marketplace plugin is updated to the
## registry's newer release only when the user opted in, keeps that choice
## across the update, and versions compare numerically.
func _test_startup_auto_update(port: int) -> void:
	await _scrub()
	var AutoUpdater = load("res://Scripts/Services/Plugins/PluginAutoUpdater.gd")
	await _done(_pm.install_queue.request(_entry(FAST, _fast_url)))
	var registry := _temp.path_join("registry.json")
	var newer := _entry(FAST, "http://127.0.0.1:%d/fast_101.tar.gz" % port)
	newer["version"] = "1.0.1"
	var f := FileAccess.open(registry, FileAccess.WRITE)
	f.store_string(JSON.stringify({"registry_version": 2, "plugins": [newer]}))
	f.close()
	var registry_url := "http://127.0.0.1:%d/registry.json" % port
	var off: Dictionary = await AutoUpdater.run(_pm, registry_url)
	_check(off.is_empty() and _pm.get_db().get_by_id(FAST).version == "1.0.0",
		"a plugin not opted in is left at its version: %s" % [off])
	_check(_pm.get_db().set_auto_update(FAST, true), "the opt-in is saved")
	var on: Dictionary = await AutoUpdater.run(_pm, registry_url)
	if on.has(FAST):
		await _done(on[FAST])
	var def = _pm.get_db().get_by_id(FAST)
	_check(on.has(FAST) and def.version == "1.0.1" and def.auto_update,
		"an opted-in plugin is updated to the newer release and stays opted in: %s" % [on])
	_check(AutoUpdater.compare_versions("1.10.0", "1.9.0") == 1 \
		and AutoUpdater.compare_versions("1.2.0", "1.2.0-rc.1") == 1 \
		and AutoUpdater.compare_versions("1.2", "1.2.0") == 0,
		"versions compare numerically, and a release is newer than its pre-release")


## Wait for `job` to finish, at most 60 s (a finished signal already emitted
## is not replayed, so the state is checked first).
func _done(job) -> void:
	await _until(func() -> bool: return job.state == Job.State.DONE, 60.0)


func _until(ready: Callable, seconds: float = 30.0) -> void:
	var give_up := Time.get_ticks_msec() + int(seconds * 1000)
	while not ready.call() and Time.get_ticks_msec() < give_up:
		await process_frame


## Install `id` as a user first gets it, then set its persisted autostart
## preference, as the plugin panel's switch does.
func _installed_then_autostart(id: String, url: String):
	var job = _pm.install_queue.request(_entry(id, url))
	await _done(job)
	if not _pm.get_db().set_autostart(id, true):
		_check(false, "%s is set to autostart" % id)
	return job


func _entry(id: String, url: String) -> Dictionary:
	return {"id": id, "version": "1.0.0",
		"downloads": {MarketplaceClient.resolve_platform_target(): url}}


func _scrub() -> void:
	for id in [SLOW, FAST, READY, PENDING]:
		await _h.scrub_plugin(_pm, id)


func _port_open(port: int) -> bool:
	for i in 50:
		if _h.port_open(port):
			return true
		await create_timer(0.1).timeout
	return false


## Archive `<archive>.tar.gz` (default `<id>`) in the temp dir: manifest
## (with `overrides` applied), placeholder binary (or the capability probe
## when `backend` launches Python), optional random payload, SHA256SUMS.
func _pack(id: String, payload_bytes: int,
		backend: Dictionary = {"entrypoint": "./test-binary", "args": []},
		overrides: Dictionary = {}, archive: String = "") -> bool:
	archive = id if archive.is_empty() else archive
	var dir := _temp.path_join(archive)
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest := {
		"id": id, "name": id, "version": "1.0.0", "host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": backend.entrypoint, "args": backend.args},
		"tools": [], "ui": {"panels": [], "ipc_messages": []},
		"permissions": {"host_capabilities": []}, "auto_reload": false,
	}
	manifest.merge(overrides, true)
	var f := FileAccess.open(dir.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest))
	f.close()
	if backend.entrypoint == PYTHON and backend.args[0] == "capability_probe.py":
		DirAccess.copy_absolute(ProjectSettings.globalize_path(PROBE_PY), dir.path_join("capability_probe.py"))
	elif backend.entrypoint == PYTHON:
		f = FileAccess.open(dir.path_join(backend.args[0]), FileAccess.WRITE)
		f.store_string("raise SystemExit(1)\n")  # exits before the MCP handshake
		f.close()
	elif backend.entrypoint == "./test-binary":
		f = FileAccess.open(dir.path_join("test-binary"), FileAccess.WRITE)
		f.store_string("PLACEHOLDER")
		f.close()
	if payload_bytes > 0:
		f = FileAccess.open(dir.path_join("payload.bin"), FileAccess.WRITE)
		f.store_buffer(Crypto.new().generate_random_bytes(payload_bytes))
		f.close()
	return _h.pack_plugin_dir(dir, dir.get_base_dir().path_join(archive + ".tar.gz"))


func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1


func _finish(code: int) -> void:
	if _pm != null:
		for id in [SLOW, FAST, READY, PENDING]:
			if _pm.get_db().has_plugin(id):
				_pm.stop_plugin(id)
				_pm.get_db().remove(id)
			_h.rm_dir_recursive("user://plugins/" + id)
	if _slow_server > 0:
		OS.kill(_slow_server)
	_h.teardown()
	_h.remove_tree(_temp)
	print("=== %s ===" % ("FAIL" if code else "PASS"))
	quit(code)
