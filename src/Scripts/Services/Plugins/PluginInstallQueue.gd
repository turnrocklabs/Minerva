extends Node
## Runs marketplace installs one at a time and keeps each plugin to one
## outstanding install for a person's requests, however often and from
## wherever they come: a request matching an unfinished install job by plugin
## id or download URL returns that job. A URL-only job's plugin is known once its archive has
## been read; then any queued request for the same plugin joins it when it
## expects that version, and ends as an install_conflict when it expects
## another. An attaching or joining request never changes the choices the
## job was made with, such as confirming skills without a dialog; the first
## request's choices stand. PluginManager owns the
## queue, so a job outlives the dialog or tool call that started it; the last
## MAX_FINISHED finished jobs are kept so a reopened dialog can show how an
## install ended. A start retry is queued in the same serial lane.
##
## A plugin that is running when its install reaches registration is
## stopped just before its files are replaced, then started again: on the
## new version, or on the restored old one if the install fails. The new
## version of a plugin that was running is started inside the install,
## before it commits, so one that fails to start is rolled back to the
## working copy and its data (MarketplaceClient). Any other install is left
## stopped. Either way the job is Ready only once start_plugin has completed
## its handshake. An unattended update (PluginAutoUpdater) or a required
## plugin's repair (RequiredPlugins) may yet be skipped, so it is always a job
## of its own: it attaches to no other job, and no request attaches to it.
##
## Cancelling takes effect while queued, before registration, and while
## starting (an upgrade cancelled while starting is rolled back).
## Registration cannot be interrupted (it completes or rolls back), so
## cancel() refuses it and the job's outcome says what happened.

signal job_changed(job: Job)

const Job := preload("res://Scripts/Services/Plugins/PluginInstallJob.gd")
const Operation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")
const Seeding := preload("res://Scripts/Services/Plugins/PluginContentSeeding.gd")
const MAX_FINISHED := 16

## The PluginManager that installs, registers, and starts plugins.
var manager: Node

var _jobs: Array[Job] = []
var _busy := false
# Job ids are a random per-queue nonce and a counter, so an id handed out by
# another queue (an earlier run's, or another manager's) never names a job
# of this one.
var _nonce := Crypto.new().generate_random_bytes(8).hex_encode()
var _serial := 0


## Install a registry entry for this platform. `unattended` (a startup
## auto-update) and `repair_only` (a required plugin's repair) are set on the
## job's operation before anyone hears of it; such a conditional install is
## always a job of its own, never another request's.
func request(entry: Dictionary, auto_confirm_skills: bool = false, unattended: bool = false,
		repair_only: bool = false) -> Job:
	var downloads: Dictionary = entry.get("downloads", {})
	var url := str(downloads.get(MarketplaceClient.download_target(downloads), ""))
	if unattended or repair_only:
		var job := _new_job(entry, url, auto_confirm_skills)
		job.op.unattended = unattended
		job.op.repair_only = repair_only
		return _submit(job)
	return _enqueue(entry, url, auto_confirm_skills)


## Install from an archive URL (the MCP tool's entry point).
func request_url(url: String, auto_confirm_skills: bool = false) -> Job:
	return _enqueue({}, url, auto_confirm_skills)


## The job with this `id`, finished or not; null once it is no longer kept.
func job_by_id(id: String) -> Job:
	for job in _jobs:
		if job.id == id:
			return job
	return null


## An unfinished job for `plugin_id`, or null; with `skip_unattended`, one
## that is not a startup update.
func pending_for(plugin_id: String, skip_unattended: bool = false) -> Job:
	for job in _jobs:
		if job.state != Job.State.DONE and job.plugin_id() == plugin_id \
				and not (skip_unattended and job.op.unattended):
			return job
	return null


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
	if job.joined != null:
		# Stop following; the install it joined carries on for its own request.
		job.result = {"ok": false, "error": "cancelled", "detail": {}}
		job.joined = null
		_finish(job, Job.OUTCOME_CANCELLED, "Stopped waiting; the install it joined continues.")
		return true
	match job.stage():
		Operation.STAGE_REGISTER:
			return false
		Operation.STAGE_START:
			# An upgrade starting inside the install sees op.cancelled and rolls
			# back; a first install's start (the queue's) sees start_cancelled.
			job.start_cancelled = true
			job.op.cancel()
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
		job.joined = null
		job.op.stage_changed.connect(_on_stage.bind(job))
		_changed(job)
		_run_next.call_deferred()


## A request for a plugin (by id) or URL that an unfinished install already
## covers keeps its own expectations: it attaches when they agree with that
## install's, ends as install_conflict when they contradict it, and follows
## it (checked when the archive is read) when the install cannot tell yet.
func _enqueue(entry: Dictionary, url: String, auto_confirm_skills: bool) -> Job:
	var wanted_id := str(entry.get("id", ""))
	var wanted_version := str(entry.get("version", ""))
	for job in _jobs:
		# A person's request never rides on an unattended update or a repair,
		# which may yet be skipped (op.conditional); it queues as its own install.
		if job.state == Job.State.DONE or job.start_only or job.joined != null or job.op.conditional():
			continue
		var same_url := not url.is_empty() and job.url == url
		if not same_url and (wanted_id.is_empty() or job.plugin_id() != wanted_id):
			continue
		var their_id: String = job.plugin_id()
		var their_version: String = job.expected_version()
		if _differs(wanted_id, their_id) or _differs(wanted_version, their_version):
			var refused := _new_job(entry, url, auto_confirm_skills)
			_conflict(refused, their_id, their_version, wanted_id, wanted_version)
			return refused
		if (not wanted_id.is_empty() and their_id.is_empty()) or (not wanted_version.is_empty() and their_version.is_empty()):
			var follower := _new_job(entry, url, auto_confirm_skills)
			follower.joined = job
			follower.state = Job.State.RUNNING
			_changed(follower)
			return follower
		return job
	return _submit(_new_job(entry, url, auto_confirm_skills))


## Queue a new install `job` and announce it.
func _submit(job: Job) -> Job:
	job.op.stage_changed.connect(_on_stage.bind(job))
	job.op.identified.connect(_on_identified.bind(job))
	_changed(job)
	_run_next.call_deferred()  # the caller holds the job before it starts
	return job


func _new_job(entry: Dictionary, url: String, auto_confirm_skills: bool) -> Job:
	var job := Job.new()
	_serial += 1
	job.id = "%s-%d" % [_nonce, _serial]
	job.entry = entry
	job.url = url
	job.auto_confirm_skills = auto_confirm_skills
	_jobs.append(job)
	return job


static func _differs(wanted: String, theirs: String) -> bool:
	return not wanted.is_empty() and not theirs.is_empty() and wanted != theirs


func _run_next() -> void:
	if _busy or manager.is_shutting_down():
		return
	for job in _jobs:
		if job.state == Job.State.QUEUED and job.joined == null:
			_busy = true
			await _run(job)
			_busy = false
			_run_next()
			return


func _run(job: Job) -> void:
	job.state = Job.State.RUNNING
	_changed(job)
	if job.start_only:
		# Retry against what is installed now, not what this job once installed.
		var current = manager.get_db().get_by_id(job.plugin_id())
		if current == null:
			_finish(job, Job.OUTCOME_START_FAILED, "The plugin is no longer installed.")
			return
		job.result["version"] = str(current.version)
		if current.state == manager.S_RUNNING:
			_finish(job, Job.OUTCOME_READY, "v%s is already running." % current.version)
			return
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
		var rollback: Dictionary = r.get("rollback", {})
		var restored: bool = rollback.is_empty() or MarketplaceClient.rollback_complete(rollback)
		# The old copy restarts only on its own files and data; with either still
		# in staging it waits for the next start's recovery.
		if job.stopped_for_replace and (rollback.is_empty() \
				or (rollback.files_restored and rollback.get("data_restored", true))):
			var restarted: Dictionary = await manager.start_plugin(job.plugin_id())
			if restarted.has("error"):
				message += "\n\nThe previous version is installed but did not restart: %s" % restarted.error
		var outcome := Job.OUTCOME_FAILED if restored else Job.OUTCOME_RECOVERY_NEEDED
		if str(r.get("error", "")) in ["cancelled", "update_not_wanted", "repair_not_needed"]:
			outcome = Job.OUTCOME_CANCELLED
		_finish(job, outcome, message)
		return
	var registered: Dictionary = r.get("manager_result", {})
	# Installed, but its skills and knowledge were not (all) written.
	var content_note := Seeding.content_note(registered)
	if r.get("started", false):
		_finish(job, Job.OUTCOME_READY, content_note)  # the upgrade was started before it committed
		return
	if registered.get("needs_binary", false):
		_finish(job, Job.OUTCOME_START_FAILED, str(registered.get("envelope", {}).get("install_hint", "")))
		return
	# Only a plugin the queue stopped is started again. Any other install is
	# left stopped, whatever its Auto-start: that choice applies when Minerva
	# launches, and an update waits for its first start.
	if job.stopped_for_replace:
		await _start(job)
	else:
		_finish(job, Job.OUTCOME_INSTALLED, content_note)


func _start(job: Job) -> void:
	job.op.enter(Operation.STAGE_START)
	var started: Dictionary = await manager.start_plugin(job.plugin_id())
	# A cancel that landed before start_plugin began had nothing to stop yet.
	if job.start_cancelled and not started.has("error"):
		manager.stop_plugin(job.plugin_id())
		started = {"error": "cancelled"}
	if not started.has("error"):
		_finish(job, Job.OUTCOME_READY, str(started.get("rolled_back", {}).get("message", "")))
	elif job.start_cancelled:
		_finish(job, Job.OUTCOME_INSTALLED, "Installed; starting it was cancelled.")
	else:
		_finish(job, Job.OUTCOME_START_FAILED, str(started.error))


## The archive of `job` holds `plugin_id` at `version`: its followers and
## a person's queued requests for that plugin join it when their expectations
## agree, and end as install_conflict when they do not. A conditional job
## (op.conditional) is never joined or refused here.
func _on_identified(plugin_id: String, version: String, job: Job) -> void:
	job.identified_version = version
	if job.op.conditional():
		return
	for other in _jobs.duplicate():
		if other.op.conditional():
			continue  # an update or repair is always its own job
		var follows: bool = other.joined == job and other.state != Job.State.DONE
		var queued: bool = other != job and other.state == Job.State.QUEUED and not other.start_only \
			and other.joined == null and other.plugin_id() == plugin_id
		if not (follows or queued):
			continue
		var wanted_id := str(other.entry.get("id", ""))
		var wanted_version := str(other.entry.get("version", ""))
		if _differs(wanted_id, plugin_id) or _differs(wanted_version, version):
			other.joined = null
			_conflict(other, plugin_id, version, wanted_id, wanted_version)
		elif queued:
			other.joined = job
			other.state = Job.State.RUNNING
			_changed(other)


## End `job`, whose request expected `wanted_id` v`wanted_version`, as
## refused while an install of `their_id` v`their_version` covers it.
func _conflict(job: Job, their_id: String, their_version: String, wanted_id: String, wanted_version: String) -> void:
	job.result = {"ok": false, "error": "install_conflict", "detail": {"installing_id": their_id,
		"installing_version": their_version, "requested_id": wanted_id, "requested_version": wanted_version}}
	_finish(job, Job.OUTCOME_FAILED, "%s is being installed by another request; %s was not installed." % [
		_describe(their_id if not their_id.is_empty() else "the plugin at that URL", their_version),
		_describe(wanted_id if not wanted_id.is_empty() else their_id, wanted_version)])


static func _describe(id: String, version: String) -> String:
	return id if version.is_empty() else "%s v%s" % [id, version]


func _on_stage(stage: String, job: Job) -> void:
	job.stage_started_msec = Time.get_ticks_msec()
	if stage == Operation.STAGE_REGISTER:
		var def = manager.get_db().get_by_id(job.plugin_id())
		if def != null and def.state in [manager.S_RUNNING, manager.S_STARTING]:
			manager.stop_plugin(def.id)
			job.stopped_for_replace = true
			job.op.start_after_install = true
	_changed(job)


func _finish(job: Job, outcome: String, message: String) -> void:
	job.state = Job.State.DONE
	job.outcome = outcome
	job.message = message
	job.start_only = false
	# The operation holds the job through this binding; drop it so a trimmed
	# job can be freed.
	for connection in job.op.stage_changed.get_connections() + job.op.identified.get_connections():
		if connection.callable.get_object() == self:
			connection.signal.disconnect(connection.callable)
	# Trim (never the job just finished) before announcing, so listeners see
	# which jobs are still kept.
	var finished := _jobs.filter(func(j: Job) -> bool: return j.state == Job.State.DONE and j != job)
	for i in finished.size() + 1 - MAX_FINISHED:
		_jobs.erase(finished[i])
	_changed(job)
	job.finished.emit()
	for other in _jobs.duplicate():
		if other.joined == job and other.state != Job.State.DONE:
			other.result = job.result
			_finish(other, outcome, message)


func _changed(job: Job) -> void:
	job.changed.emit()
	job_changed.emit(job)
