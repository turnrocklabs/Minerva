class_name MCPMonotonicDeadline
extends RefCounted
## A small wall-clock deadline for MCP transport and helper operations. Engine
## timers provide wakeups; monotonic ticks decide expiry and correct early wakes.

signal expired

var deadline_ms := 0
var _timer: SceneTreeTimer
var _callback: Callable
var _cancelled := false


func start(timeout_sec: float) -> bool:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or timeout_sec <= 0.0:
		return false
	deadline_ms = Time.get_ticks_msec() + int(ceil(timeout_sec * 1000.0))
	_arm(tree)
	return true


func cancel() -> void:
	_cancelled = true
	if _timer != null and _callback.is_valid() \
			and _timer.timeout.is_connected(_callback):
		_timer.timeout.disconnect(_callback)
	_timer = null
	_callback = Callable()


func _arm(tree: SceneTree) -> void:
	if _cancelled:
		return
	var remaining_ms := deadline_ms - Time.get_ticks_msec()
	if remaining_ms <= 0:
		_cancelled = true
		expired.emit()
		return
	_timer = tree.create_timer(float(remaining_ms) / 1000.0, true, false, true)
	_callback = _on_wake.bind(tree)
	_timer.timeout.connect(_callback)


func _on_wake(tree: SceneTree) -> void:
	_timer = null
	_callback = Callable()
	_arm(tree)
