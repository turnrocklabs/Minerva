extends Node
## Runs marketplace installs one at a time and keeps each plugin to one
## outstanding install, however often and from wherever it is requested: a
## request matching an unfinished install job by plugin id or download URL
## returns that job (a URL-only job is known by its URL until its archive has
## been read). An attaching request cannot change choices the job was made
## with, such as confirming skills without a dialog. PluginManager owns the
## queue, so a job outlives the dialog or tool call that started it; the last
## MAX_FINISHED finished jobs are kept so a reopened dialog can show how an
## install ended. A start retry is queued in the same serial lane.
##
## A plugin that is running when its install reaches registration is
## stopped just before its files are replaced, then started again: on the
## new version, or on the restored old one if the install fails. After a
## successful install the plugin is started when that is expected (it was
## running, or it autostarts), and the job is Ready only once start_plugin
## has completed its handshake.
##
## Cancelling takes effect while queued, before registration, and while
## starting. Registration cannot be interrupted (it completes or rolls
## back), so cancel() refuses it and the job's outcome says what happened.

signal job_changed(job: Job)

const Job := preload("res://Scripts/Services/Plugins/PluginInstallJob.gd")
const Operation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")
const MAX_FINISHED := 16

## The PluginManager that installs, registers, and starts plugins.
var manager: Node

var _jobs: Array[Job] = []
var _busy := false


## Install a registry entry for this platform.
func request(entry: Dictionary, auto_confirm_skills: bool = false) -> Job:
	var url := str(entry.get("downloads", {}).get(MarketplaceClient.resolve_platform_target(), ""))
	return _enqueue(entry, url, auto_confirm_skills)


## Install from an archive URL (the MCP tool's entry point).
func request_url(url: String, auto_confirm_skills: bool = false) -> Job:
	return _enqueue({}, url, auto_confirm_skills)


## The most recent job for `plugin_id`, finished or not; null if none is kept.
func job_for(plugin_id: String) -> Job:
	for i in range(_jobs.size() - 1, -1, -1):
		if _jobs[i].plugin_id() == plugin_id:
			return _jobs[i]
	return null


func jobs() -> Array[Job]:
	return _jobs.duplicate()


## Returns whether the cancel will take effect (see the class comment).
func cancel(job: Job) -> bool:
	if job.state == Job.State.QUEUED:
		if job.start_only:
			_finish(job, Job.OUTCOME_INSTALLED, "Installed; starting it was cancelled.")
			return true
		job.result = {"ok": false, "error": "cancelled", "detail": {}}
		_finish(job, Job.OUTCOME_CANCELLED, "Cancelled before it started.")
		return true
	if job.state != Job.State.RUNNING:
		return false
	match job.stage():
		Operation.STAGE_REGISTER:
			return false
		Operation.STAGE_START:
			job.start_cancelled = true
			manager.stop_plugin(job.plugin_id())
		_:
			job.op.cancel()
	return true


## Queue another start of an installed plugin after OUTCOME_START_FAILED.
func retry_start(job: Job) -> void:
	if job in _jobs and job.state == Job.State.DONE and job.outcome == Job.OUTCOME_START_FAILED:
		job.state = Job.State.QUEUED
		job.outcome = ""
		job.message = ""
		job.start_only = true
		job.start_cancelled = false
		job.op.stage_changed.connect(_on_stage.bind(job))
		_changed(job)
		_run_next.call_deferred()


func _enqueue(entry: Dictionary, url: String, auto_confirm_skills: bool) -> Job:
	var plugin_id := str(entry.get("id", ""))
	for job in _jobs:
		if job.state != Job.State.DONE and not job.start_only \
				and ((not plugin_id.is_empty() and job.plugin_id() == plugin_id) or (not url.is_empty() and job.url == url)):
			job.auto_confirm_skills = job.auto_confirm_skills or auto_confirm_skills
			return job
	var job := Job.new()
	job.entry = entry
	job.url = url
	job.auto_confirm_skills = auto_confirm_skills
	job.op.stage_changed.connect(_on_stage.bind(job))
	_jobs.append(job)
	_changed(job)
	_run_next.call_deferred()  # the caller holds the job before it starts
	return job


func _run_next() -> void:
	if _busy:
		return
	for job in _jobs:
		if job.state == Job.State.QUEUED:
			_busy = true
			await _run(job)
			_busy = false
			_run_next()
			return


func _run(job: Job) -> void:
	job.state = Job.State.RUNNING
	_changed(job)
	if job.start_only:
		await _start(job)
		return
	var client: Node = MarketplaceClient.new()
	add_child(client)
	var r: Dictionary
	if job.entry.is_empty():
		r = await client.install_from_url(job.url, manager, job.auto_confirm_skills, job.op)
	else:
		r = await client.install_from_registry_entry(job.entry, manager, job.auto_confirm_skills, job.op)
	client.queue_free()
	job.result = r
	if not r.get("ok", false):
		var message := MarketplaceClient.format_install_error(r)
		if job.stopped_for_replace:
			var restarted: Dictionary = await manager.start_plugin(job.plugin_id())  # the old files are back
			if restarted.has("error"):
				message += "\n\nThe previous version is installed but did not restart: %s" % restarted.error
		var cancelled := str(r.get("error", "")) == "cancelled"
		_finish(job, Job.OUTCOME_CANCELLED if cancelled else Job.OUTCOME_FAILED, message)
		return
	var registered: Dictionary = r.get("manager_result", {})
	if registered.get("needs_binary", false):
		_finish(job, Job.OUTCOME_START_FAILED, str(registered.get("envelope", {}).get("install_hint", "")))
		return
	var def = manager.get_db().get_by_id(job.plugin_id())
	if job.stopped_for_replace or (def != null and def.autostart):
		await _start(job)
	else:
		_finish(job, Job.OUTCOME_INSTALLED, "")


func _start(job: Job) -> void:
	job.op.enter(Operation.STAGE_START)
	var started: Dictionary = await manager.start_plugin(job.plugin_id())
	# A cancel that landed before start_plugin began had nothing to stop yet.
	if job.start_cancelled and not started.has("error"):
		manager.stop_plugin(job.plugin_id())
		started = {"error": "cancelled"}
	if not started.has("error"):
		_finish(job, Job.OUTCOME_READY, "")
	elif job.start_cancelled:
		_finish(job, Job.OUTCOME_INSTALLED, "Installed; starting it was cancelled.")
	else:
		_finish(job, Job.OUTCOME_START_FAILED, str(started.error))


func _on_stage(stage: String, job: Job) -> void:
	job.stage_started_msec = Time.get_ticks_msec()
	if stage == Operation.STAGE_REGISTER:
		var def = manager.get_db().get_by_id(job.plugin_id())
		if def != null and def.state in [manager.S_RUNNING, manager.S_STARTING]:
			manager.stop_plugin(def.id)
			job.stopped_for_replace = true
	_changed(job)


func _finish(job: Job, outcome: String, message: String) -> void:
	job.state = Job.State.DONE
	job.outcome = outcome
	job.message = message
	job.start_only = false
	# The operation holds the job through this binding; drop it so a trimmed
	# job can be freed.
	for connection in job.op.stage_changed.get_connections():
		if connection.callable.get_object() == self and connection.callable.get_method() == "_on_stage":
			job.op.stage_changed.disconnect(connection.callable)
	# Trim (never the job just finished) before announcing, so listeners see
	# which jobs are still kept.
	var finished := _jobs.filter(func(j: Job) -> bool: return j.state == Job.State.DONE and j != job)
	for i in finished.size() + 1 - MAX_FINISHED:
		_jobs.erase(finished[i])
	_changed(job)
	job.finished.emit()


func _changed(job: Job) -> void:
	job.changed.emit()
	job_changed.emit(job)
