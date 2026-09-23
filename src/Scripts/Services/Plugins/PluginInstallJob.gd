extends RefCounted
## One requested marketplace install, from request to final outcome, as
## PluginInstallQueue tracks it. Whoever asked (the marketplace dialog, the
## MCP tool) holds the job to follow it; the queue owns it.
##
## While RUNNING, stage() names the current step (PluginInstallOperation's
## stages, then STAGE_START when the plugin is started). op.done/op.total
## count that step's bytes; with total -1 there is no denominator, so show
## stage_elapsed_seconds() instead. `changed` fires on state, stage and
## outcome changes; byte progress is polled.

const Operation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")

signal changed
signal finished

enum State { QUEUED, RUNNING, DONE }

const OUTCOME_READY := "ready"                # installed and started
const OUTCOME_INSTALLED := "installed"        # installed; starts when used
const OUTCOME_START_FAILED := "start_failed"  # installed; starting it failed (retry_start)
const OUTCOME_FAILED := "failed"              # not installed; any previous install kept
const OUTCOME_RECOVERY_NEEDED := "failed_needs_recovery"  # not installed; the previous install is not fully back yet
const OUTCOME_CANCELLED := "cancelled"        # stopped before registration; nothing changed

## Stable handle for this job (set by the queue), for asking how it stands
## after the request that started it has returned.
var id := ""
## The registry entry asked for, or {} when only a URL was given.
var entry := {}
var url := ""
var auto_confirm_skills := false
var op := Operation.new()
var state := State.QUEUED
var outcome := ""
## MarketplaceClient's install result: plugin_id and version are what was
## actually installed.
var result := {}
## Readable reason for a failed, cancelled, or unstarted outcome.
var message := ""
var stage_started_msec := Time.get_ticks_msec()
# Set by the queue: the plugin was stopped for the replace, or a start
# was cancelled.
var stopped_for_replace := false
var start_cancelled := false
## This run only starts the installed plugin again (PluginInstallQueue.retry_start).
var start_only := false
## The running install of the same plugin this request joined, if any; this
## job then ends as that one does.
var joined = null
## The version this job's archive turned out to hold, once read.
var identified_version := ""


## The actual id once the archive has been read, else the one requested
## ("" for a URL-only request until then).
func plugin_id() -> String:
	if not str(result.get("plugin_id", "")).is_empty():
		return result.plugin_id
	return op.plugin_id if not op.plugin_id.is_empty() else str(entry.get("id", ""))


## The version this job will install: the registry entry's, or the one its
## archive declared; "" while unknown.
func expected_version() -> String:
	var wanted := str(entry.get("version", ""))
	return wanted if not wanted.is_empty() else identified_version


func stage() -> String:
	return op.stage


func stage_elapsed_seconds() -> float:
	return (Time.get_ticks_msec() - stage_started_msec) / 1000.0


## The install result plus how the job ended, for callers that report it.
func summary() -> Dictionary:
	var out := result.duplicate()
	out["outcome"] = outcome
	if not message.is_empty():
		out["message"] = message
	return out


## How the job stands for a caller polling it: once DONE, its summary with
## job_id and done:true; before that {job_id, done:false, outcome, plugin_id,
## stage, bytes_done, bytes_total, stage_seconds}, where outcome is queued
## (waiting behind another install) or running, and a joined request reports
## the install it follows.
func status() -> Dictionary:
	if state == State.DONE:
		var ended := summary()
		ended["job_id"] = id
		ended["done"] = true
		return ended
	var running = joined if joined != null else self
	var waiting: bool = running.state == State.QUEUED
	return {"job_id": id, "done": false, "outcome": "queued" if waiting else "running", "plugin_id": plugin_id(),
		"stage": running.stage(), "bytes_done": running.op.done, "bytes_total": running.op.total,
		"stage_seconds": snappedf(running.stage_elapsed_seconds(), 0.1)}
