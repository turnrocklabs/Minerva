class_name PluginExecApprovalGate
extends ConfirmationDialog
## Main-thread bridge for SetupPipeline's exec-step approval seam (DCR
## 019f69428fa0, Docs/design/plugin-setup-pipeline.md §1: "exec is the only
## step requiring explicit user confirmation at install (its argv is shown
## verbatim)"; SetupPipeline.gd's own APPROVAL SEAM doc).
##
## `approve(step, step_index) -> bool` is the Callable a PluginManager's
## `exec_approver` gets pointed at. It is invoked SYNCHRONOUSLY on a
## SetupPipeline WORKER thread (never the main thread) — this class's entire
## job is to marshal that request onto the main thread (call_deferred) to
## show a real dialog, then block the calling worker thread on a Semaphore
## until the user answers, and hand the answer back as this Callable's return
## value. See SetupPipeline.gd lines ~25-35 for the contract this fulfills.
##
## CONCURRENCY: approve() may be called by more than one worker thread at once
## (two plugins mid-build at the same time, each with an exec step). Each call
## gets its OWN Semaphore + decision box and is queued; the dialog is shown for
## one request at a time, FIFO. This avoids two workers racing over shared
## "the" pending-decision state.
##
## CANCELLATION / APP-QUIT: Cancel, closing the dialog (Esc / titlebar X), this
## node leaving the tree, or the app quitting (NOTIFICATION_WM_CLOSE_REQUEST)
## all resolve as DENY and release every blocked worker immediately — a worker
## thread must never be left waiting on a Semaphore that nothing will ever
## post to, since that would hang app shutdown (Godot must join every running
## Thread before the process can actually exit).

## FIFO queue of pending requests. Each entry:
##   {"step": Dictionary, "step_index": int, "sem": Semaphore, "decision": [bool]}
## `decision` is a 1-element Array used as a mutable box so _resolve_current()
## can write the answer somewhere the blocked worker thread (holding the same
## Dictionary by reference) can read it after sem.wait() returns.
var _queue: Array = []

## The request currently on screen (or null). Also lives at _queue[0] while
## pending; kept as a separate ref so _resolve_current() doesn't need to
## re-index the queue.
var _current_request = null

## Guards _closing (read from worker threads in approve(), written from the
## main thread in _force_deny_and_release()) — the only field genuinely shared
## across threads here.
var _mutex := Mutex.new()
var _closing: bool = false

var _step_label: Label = null
var _argv_value: Label = null


func _ready() -> void:
	title = "Confirm plugin build step"
	get_ok_button().text = "Run"
	get_cancel_button().text = "Cancel"
	_build_content()
	confirmed.connect(_on_confirmed)
	canceled.connect(_on_canceled)
	close_requested.connect(_on_close_requested)


func _exit_tree() -> void:
	_force_deny_and_release()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_force_deny_and_release()


func _build_content() -> void:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(480, 0)
	add_child(vbox)

	var intro := Label.new()
	intro.text = "This plugin's setup pipeline wants to run an exec step. Review the exact command below."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(intro)

	_step_label = Label.new()
	_step_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(_step_label)

	var argv_title := Label.new()
	argv_title.text = "Command (argv):"
	argv_title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(argv_title)

	_argv_value = Label.new()
	_argv_value.autowrap_mode = TextServer.AUTOWRAP_OFF
	_argv_value.add_theme_font_size_override("font_size", 13)
	# A monospace-ish look isn't available without a font resource; the raw
	# argv text plus JSON-array framing is unambiguous either way — this is a
	# literal echo, not a stylised rendering.
	vbox.add_child(_argv_value)


# ---------------------------------------------------------------------------
# Worker-thread entry point (this is `PluginManager.exec_approver`).
# ---------------------------------------------------------------------------

## Callable(step: Dictionary, step_index: int) -> bool.
## Called synchronously on a SetupPipeline worker thread. Blocks that thread
## (via Semaphore.wait()) until the user answers or the gate is torn down.
func approve(step: Dictionary, step_index: int) -> bool:
	_mutex.lock()
	var closing_now: bool = _closing
	_mutex.unlock()
	if closing_now:
		return false

	var request := {
		"step": step,
		"step_index": step_index,
		"sem": Semaphore.new(),
		"decision": [false],
	}

	_mutex.lock()
	_queue.append(request)
	var is_only_one: bool = _queue.size() == 1
	_mutex.unlock()

	if is_only_one:
		call_deferred("_process_next_request")

	(request["sem"] as Semaphore).wait()
	return (request["decision"] as Array)[0]


# ---------------------------------------------------------------------------
# Main-thread dispatcher.
# ---------------------------------------------------------------------------

func _process_next_request() -> void:
	_mutex.lock()
	var closing_now: bool = _closing
	var req = _queue[0] if not _queue.is_empty() else null
	_mutex.unlock()

	if req == null:
		return

	if closing_now:
		_resolve_current_locked(req, false)
		return

	_current_request = req
	var step: Dictionary = req["step"]
	var step_index: int = int(req["step_index"])
	var argv: Array = step.get("argv", [])

	_step_label.text = "Step %d — exec" % step_index
	_argv_value.text = JSON.stringify(argv)

	popup_centered(Vector2i(560, 220))


func _on_confirmed() -> void:
	_resolve_current(true)


func _on_canceled() -> void:
	_resolve_current(false)


func _on_close_requested() -> void:
	# ConfirmationDialog emits `canceled` on Esc/titlebar-close already in most
	# builds, but close_requested is the documented catch-all — resolving here
	# too is a no-op (guarded by _current_request == null) if `canceled` beat
	# us to it, and a safety net if it didn't.
	_resolve_current(false)
	hide()


## Resolves whichever request is currently on screen, pops it off the queue,
## and kicks off the next one (if any). Safe to call more than once for the
## same request (idempotent no-op after the first call).
func _resolve_current(decision: bool) -> void:
	if _current_request == null:
		return
	var req = _current_request
	_current_request = null
	_resolve_current_locked(req, decision)


func _resolve_current_locked(req, decision: bool) -> void:
	(req["decision"] as Array)[0] = decision
	(req["sem"] as Semaphore).post()

	_mutex.lock()
	if not _queue.is_empty() and _queue[0] == req:
		_queue.pop_front()
	var has_more: bool = not _queue.is_empty()
	_mutex.unlock()

	if has_more:
		call_deferred("_process_next_request")


## Called on _exit_tree() and NOTIFICATION_WM_CLOSE_REQUEST. Marks the gate
## closing (so any FUTURE approve() call denies immediately without even
## queueing/blocking) and force-resolves every currently-queued and
## currently-displayed request as DENY, releasing every worker thread blocked
## in approve() — this is what keeps an app-quit from hanging on a build's
## exec-step confirmation.
func _force_deny_and_release() -> void:
	_mutex.lock()
	_closing = true
	var pending: Array = _queue.duplicate()
	_queue.clear()
	_mutex.unlock()

	if visible:
		hide()

	if _current_request != null and _current_request not in pending:
		pending.append(_current_request)
	_current_request = null

	for req in pending:
		(req["decision"] as Array)[0] = false
		(req["sem"] as Semaphore).post()
