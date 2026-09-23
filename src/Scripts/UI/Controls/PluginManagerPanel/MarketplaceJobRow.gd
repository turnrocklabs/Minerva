extends PanelContainer
## One marketplace install job, as a row in MarketplaceBrowseDialog.
##
## Mirrors a PluginInstallJob: its stage while running, with a progress bar
## when the stage has a byte total and the stage's elapsed time when it has
## none; then its outcome. Cancel is offered while a cancel can still take
## effect; retry only after a failed start, and only while the queue still
## keeps the job.

const Job := preload("res://Scripts/Services/Plugins/PluginInstallJob.gd")
const Operation := preload("res://Scripts/Services/Plugins/PluginInstallOperation.gd")

const STAGE_NAMES := {
	Operation.STAGE_DOWNLOAD: "Downloading",
	Operation.STAGE_EXTRACT: "Extracting",
	Operation.STAGE_VERIFY: "Verifying files",
	Operation.STAGE_CONFIRM: "Waiting for your confirmation",
	Operation.STAGE_REGISTER: "Registering",
	Operation.STAGE_START: "Starting",
}

var job: Job
var queue: Node

@onready var _name: Label = %Name
@onready var _status: Label = %Status
@onready var _progress: ProgressBar = %Progress
@onready var _detail: Label = %Detail
@onready var _cancel: Button = %Cancel
@onready var _retry: Button = %Retry


func bind(bound_job: Job, install_queue: Node) -> void:
	job = bound_job
	queue = install_queue


func _ready() -> void:
	_cancel.pressed.connect(_on_cancel)
	_retry.pressed.connect(func() -> void: queue.retry_start(job))
	job.changed.connect(_render)
	_render()


## Re-render after something outside the job changed (the queue trimmed it).
func refresh() -> void:
	_render()


func _process(_delta: float) -> void:
	_render_running()


func _render() -> void:
	_name.text = job.plugin_id() if not job.plugin_id().is_empty() else job.url.get_file()
	set_process(job.state == Job.State.RUNNING)
	_retry.visible = false
	_detail.text = ""
	match job.state:
		Job.State.QUEUED:
			_status.text = "Waiting for other installs to finish"
			_progress.visible = false
			_cancel.visible = true
		Job.State.RUNNING:
			_render_running()
		Job.State.DONE:
			_render_outcome()


func _render_running() -> void:
	# A joined request shows the install it is waiting on.
	var source: Job = job.joined if job.joined != null else job
	var stage_name: String = STAGE_NAMES.get(source.stage(), "Preparing")
	var measurable: bool = source.op.total > 0
	_progress.visible = measurable
	if measurable:
		_progress.max_value = source.op.total
		_progress.value = source.op.done
		_status.text = "%s — %s of %s" % [stage_name, String.humanize_size(source.op.done),
			String.humanize_size(source.op.total)]
	else:
		_status.text = "%s… %d s" % [stage_name, int(source.stage_elapsed_seconds())]
	# Registration commits or rolls back; offering cancel there would lie.
	_cancel.visible = job.joined != null or source.stage() != Operation.STAGE_REGISTER
	if job.joined != null:
		_detail.text = "Joined the install of this plugin already running."
	elif source.stage() == Operation.STAGE_REGISTER:
		_detail.text = "Finishing the install; this step cannot be cancelled."


func _render_outcome() -> void:
	_progress.visible = false
	_cancel.visible = false
	var version := str(job.result.get("version", ""))
	match job.outcome:
		Job.OUTCOME_READY:
			_status.text = "Ready — v%s is running" % version
		Job.OUTCOME_INSTALLED:
			_status.text = "Installed v%s — starts when used" % version
		Job.OUTCOME_START_FAILED:
			_status.text = "Installed v%s, but it failed to start" % version
			_retry.visible = job in queue.jobs()
		Job.OUTCOME_FAILED:
			_status.text = "Install failed — nothing was changed"
		Job.OUTCOME_RECOVERY_NEEDED:
			_status.text = "Install failed — the previous version is not fully back yet"
		Job.OUTCOME_CANCELLED:
			_status.text = "Cancelled — nothing was changed"
	_detail.text = job.message


func _on_cancel() -> void:
	if not queue.cancel(job) and job.state == Job.State.RUNNING:
		_detail.text = "Too late to cancel: the install is being finished. Its result will show here."
