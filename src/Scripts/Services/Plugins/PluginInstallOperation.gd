extends RefCounted
## One marketplace install in flight: which stage it is in, how far along
## that stage is, a cancel switch, and the staging directory only it owns.
##
## A caller that wants progress or cancellation creates one and passes it to
## MarketplaceClient.install_from_url; otherwise the client makes its own.
## `done`/`total` count the current stage's units (bytes while downloading
## and verifying); `total` is -1 while the size is unknown (extracting).
## Cancellation is honored until registration begins; from then on the
## install runs to completion or rolls back. STAGE_REGISTER is entered
## immediately before the installed files are replaced. Main-thread only; a worker
## thread may read `cancelled`.

signal stage_changed(stage: String)

const STAGE_DOWNLOAD := "download"
const STAGE_EXTRACT := "extract"
const STAGE_VERIFY := "verify"
const STAGE_REGISTER := "register"
## Entered by PluginInstallQueue after a successful install that should run.
const STAGE_START := "start"

var stage := ""
var done := 0
var total := -1
var cancelled := false
## The plugin id the archive declares, once it has been read.
var plugin_id := ""
## Absolute path of this operation's directory under the staging root.
var staging_dir := ""


func cancel() -> void:
	cancelled = true


func enter(new_stage: String) -> void:
	stage = new_stage
	done = 0
	total = -1
	stage_changed.emit(new_stage)
