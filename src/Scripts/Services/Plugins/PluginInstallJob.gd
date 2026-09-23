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
const OUTCOME_CANCELLED := "cancelled"        # stopped before registration; nothing changed

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


## The actual id once the archive has been read, else the one requested.
func plugin_id() -> String:
	if not str(result.get("plugin_id", "")).is_empty():
		return result.plugin_id
	return op.plugin_id if not op.plugin_id.is_empty() else str(entry.get("id", ""))


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
