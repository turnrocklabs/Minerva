extends VBoxContainer
## The Jobs section of the Agent Sessions panel: lists the selected session's
## planned jobs (newest first) with their class — running, succeeded, failed,
## timed_out, interrupted, unknown — revision and command, shows the selected
## job's result and log tail, and drains the session (no new jobs; its
## running jobs are stopped and end interrupted, never retried) or lifts the
## drain. The GUI twin of minerva_agent_session_job_status, _job_log and
## _drain; jobs start from MCP (minerva_agent_session_run_job). All drive
## AgentSessionStore. Scene: res://Scenes/AgentSessionJobs.tscn, placed in
## AgentSessionsPanel.tscn, which calls show_session() on selection.

const AgentSessionStore := preload("res://Scripts/Services/AgentSessions/AgentSessionStore.gd")

enum Column { JOB, CLASS, REVISION, COMMAND }

const OK_COLOR := Color(0.2, 0.8, 0.2)
const ERROR_COLOR := Color(0.9, 0.3, 0.3)
const WARN_COLOR := Color(0.9, 0.7, 0.2)
const MUTED_COLOR := Color(0.7, 0.7, 0.7)
const CLASS_COLORS := {
	"succeeded": OK_COLOR, "failed": ERROR_COLOR, "timed_out": WARN_COLOR,
	"interrupted": WARN_COLOR, "unknown": MUTED_COLOR, "running": MUTED_COLOR,
}
## Bytes of log shown for the selected job.
const LOG_TAIL := 16384

var _store: RefCounted
var _session: String = ""
var _draining: bool = false
var _busy: bool = false
## Bumped by every refresh; an answer for an older one is dropped.
var _generation: int = 0

@onready var _jobs: Tree = %JobList
@onready var _status: Label = %JobsStatus
@onready var _drain: Button = %Drain
@onready var _lift: Button = %LiftDrain
@onready var _show_log: Button = %ShowLog
@onready var _log: RichTextLabel = %JobLog


func _ready() -> void:
	_store = AgentSessionStore.shared()
	for column: int in Column.values():
		_jobs.set_column_title(column, Column.keys()[column].capitalize())
	_jobs.set_column_expand(Column.COMMAND, true)
	for column: int in [Column.JOB, Column.CLASS, Column.REVISION]:
		_jobs.set_column_expand(column, false)
		_jobs.set_column_custom_minimum_width(column, 120)
	_jobs.item_selected.connect(_update_buttons)
	%RefreshJobs.pressed.connect(refresh)
	_drain.pressed.connect(_on_drain_pressed.bind(false))
	_lift.pressed.connect(_on_drain_pressed.bind(true))
	_show_log.pressed.connect(_on_show_log_pressed)
	_update_buttons()


## Shows session `id`'s jobs, re-listed on every call ("" clears the section).
func show_session(id: String) -> void:
	if id != _session:
		_session = id
		_log.text = ""
		_log.visible = false
	refresh()


func refresh() -> void:
	_generation += 1
	var mine: int = _generation
	if _session.is_empty():
		_jobs.clear()
		_set_status("Select a session to see its jobs.", MUTED_COLOR)
		_update_buttons()
		return
	var listing: Dictionary = await _store.job_status(_session)
	if not is_inside_tree() or mine != _generation:
		return
	_jobs.clear()
	_jobs.create_item()
	if not bool(listing.get("ok", false)):
		_set_status(str(listing.get("error", "could not list jobs")), ERROR_COLOR)
		_update_buttons()
		return
	_draining = bool(listing.get("draining", false))
	var jobs: Array = listing.get("jobs", []) if listing.get("jobs") is Array else []
	var root: TreeItem = _jobs.get_root()
	for job: Variant in jobs:
		if not job is Dictionary:
			continue
		var entry: Dictionary = job
		var item: TreeItem = _jobs.create_item(root)
		var cls: String = str(entry.get("class", ""))
		var revision: String = str(entry.get("revision", ""))
		item.set_text(Column.JOB, str(entry.get("job", "")))
		item.set_text(Column.CLASS, cls)
		item.set_custom_color(Column.CLASS, CLASS_COLORS.get(cls, MUTED_COLOR))
		item.set_tooltip_text(Column.CLASS, str(entry.get("detail", "")))
		item.set_text(Column.REVISION, revision.left(12) if not revision.is_empty()
			else str(entry.get("revision_requested", "")))
		item.set_text(Column.COMMAND, str(entry.get("command", "")))
	var count: String = "%d job(s)" % jobs.size()
	if _draining:
		_set_status("%s is draining: no new jobs until the drain is lifted. %s." % [_session, count], WARN_COLOR)
	else:
		_set_status("%s. Jobs start from MCP (minerva_agent_session_run_job)." % count, MUTED_COLOR)
	_update_buttons()


func _selected_job() -> String:
	var item: TreeItem = _jobs.get_selected()
	return item.get_text(Column.JOB) if item != null else ""


func _update_buttons() -> void:
	var has_session: bool = not _session.is_empty()
	_drain.disabled = _busy or not has_session or _draining
	_lift.disabled = _busy or not has_session or not _draining
	_show_log.disabled = _busy or _selected_job().is_empty()


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _on_drain_pressed(lift: bool) -> void:
	var id: String = _session
	_busy = true
	_update_buttons()
	_set_status("Lifting the drain of %s…" % id if lift else "Draining %s: stopping its running jobs…" % id, MUTED_COLOR)
	var result: Dictionary = await _store.drain(id, 0, lift)
	_busy = false
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("error", "the launcher failed")), ERROR_COLOR)
		_update_buttons()
		return
	await refresh()
	if lift:
		_set_status("%s takes new jobs again." % id, OK_COLOR)
		return
	var ended := PackedStringArray()
	var jobs: Array = result.get("jobs", []) if result.get("jobs") is Array else []
	for job: Variant in jobs:
		if job is Dictionary:
			ended.append("%s %s" % [str((job as Dictionary).get("job", "")), str((job as Dictionary).get("class", ""))])
	_set_status("%s is draining. %s" % [id, ", ".join(ended) if not ended.is_empty() else "No job was running."], WARN_COLOR)


func _on_show_log_pressed() -> void:
	var job: String = _selected_job()
	_busy = true
	_update_buttons()
	var status: Dictionary = await _store.job_status(_session, job)
	var tail: Dictionary = await _store.job_log(_session, job, LOG_TAIL)
	_busy = false
	_update_buttons()
	if not bool(tail.get("ok", false)):
		_set_status(str(tail.get("error", "the launcher failed")), ERROR_COLOR)
		return
	_log.text = _result_text(status) + "\n[b]Log[/b]%s:\n%s" % [
		" (last %d bytes)" % LOG_TAIL if bool(tail.get("truncated", false)) else "", _esc(str(tail.get("log", "")))]
	_log.visible = true


static func _result_text(status: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("[b]%s[/b] %s — %s" % [_esc(str(status.get("job", ""))), _esc(str(status.get("class", ""))),
		_esc(str(status.get("detail", "")))])
	var result: Dictionary = status.get("result", {}) if status.get("result") is Dictionary else {}
	lines.append("Revision: %s (asked %s)" % [_esc(str(result.get("revision", ""))),
		_esc(str(status.get("revision_requested", "")))])
	var source: Dictionary = result.get("source", {}) if result.get("source") is Dictionary else {}
	if bool(source.get("known", false)):
		lines.append("Clone: %s (%s modified, %s untracked; uncommitted changes never reach a job)" % [
			"dirty" if bool(source.get("dirty", false)) else "clean",
			str(source.get("modified", 0)), str(source.get("untracked", 0))])
	var artifacts: Array = result.get("artifacts", []) if result.get("artifacts") is Array else []
	for artifact: Variant in artifacts:
		if artifact is Dictionary:
			var a: Dictionary = artifact
			lines.append("Artifact %s: %s" % [_esc(str(a.get("path", ""))),
				_esc(str(a.get("host_path", ""))) if bool(a.get("complete", false)) else "not complete"])
	return "\n".join(lines)


## Launcher and job text shown literally, never as BBCode.
static func _esc(text: String) -> String:
	return text.replace("[", "[lb]")
