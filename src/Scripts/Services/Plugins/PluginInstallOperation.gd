extends RefCounted
## One marketplace install in flight: which stage it is in, how far along
## that stage is, a cancel switch, and the staging directory only it owns.
##
## A caller that wants progress or cancellation creates one and passes it to
## MarketplaceClient.install_from_url; otherwise the client makes its own.
## `done`/`total` count the current stage's units (bytes while downloading
## and verifying); `total` is -1 while the size is unknown (extracting).
## Cancellation is honored until registration begins, and again while an
## upgrade is starting (which rolls it back); otherwise from registration on
## the install commits or rolls back. STAGE_REGISTER is entered immediately
## before the installed files are replaced, after every user decision. Main-thread only; a worker
## thread may read `cancelled`.

signal stage_changed(stage: String)
## The archive has been read: it holds `plugin_id` at `version`.
signal identified(plugin_id: String, version: String)
## cancel() was called; a dialog waiting on the user closes on it.
signal cancel_requested

const STAGE_DOWNLOAD := "download"
const STAGE_EXTRACT := "extract"
const STAGE_VERIFY := "verify"
## Waiting for the user's decisions (skill consent) before anything changes.
const STAGE_CONFIRM := "confirm"
## Waiting for another Minerva process to finish replacing a plugin.
const STAGE_WAIT := "wait"
const STAGE_REGISTER := "register"
## Starting the plugin: an upgrade of a running plugin is started by the
## install before it commits (a failure rolls it back); any other install
## that is to run is started by PluginInstallQueue after it commits.
const STAGE_START := "start"

var stage := ""
var done := 0
var total := -1
var cancelled := false
## The plugin id the archive declares, once it has been read.
var plugin_id := ""
## Absolute path of this operation's directory under the staging root.
var staging_dir := ""
## Nobody is there to ask (a startup auto-update): no skill question is
## asked, so a skill the user customised keeps their version.
var unattended := false
## Set by the caller that stopped the running plugin for the replacement, so
## the new version is started (and must start) before the install commits.
var start_after_install := false


func cancel() -> void:
	cancelled = true
	cancel_requested.emit()


func identify(id: String, version: String) -> void:
	plugin_id = id
	identified.emit(id, version)


func enter(new_stage: String) -> void:
	stage = new_stage
	done = 0
	total = -1
	stage_changed.emit(new_stage)
