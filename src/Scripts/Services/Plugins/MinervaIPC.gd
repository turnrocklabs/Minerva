class_name MinervaIPC
extends Node
## Helper node attached to plugin scene roots by PluginScenePanelBroker.
##
## Enables coroutine-based (await-style) IPC replies for plugin scenes.
## The broker attaches one instance of this node as "$_MinervaIPC" on every
## registered scene root, then calls _reply() when a result arrives from the
## plugin backend or a capability handler.
##
## Scene-side usage:
##
##   # Emit a request and await its result:
##   var reply_id := str(randi())
##   request.emit("my_plugin.do_thing", {"key": "value"}, reply_id)
##   var result := await $_MinervaIPC.await_reply(reply_id)
##   if result.get("success"):
##       # handle result["result"]
##   else:
##       # handle result["error_code"] / result["error_message"]
##
## Stale reply IDs (result arrives after the coroutine timed out or was
## discarded) are logged and dropped — they never raise an error.

## Child-node name used by the broker when attaching this helper.
## Scenes access via `$_MinervaIPC` (GDScript shorthand for `get_node("_MinervaIPC")`).
## The `$` is NOT part of the node name — it is node-path syntax.
const HELPER_NODE_NAME := "_MinervaIPC"

## Default timeout in milliseconds if no timeout is specified by the caller.
const DEFAULT_TIMEOUT_MS := 10000


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

## Per-reply-id state for in-flight awaits.
## reply_id -> _ReplyObserver
## Reference is kept here to prevent GC before the coroutine resumes.
var _pending: Dictionary = {}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Await the result for a specific reply_id, with an optional timeout.
##
## Parameters:
##   reply_id   — must match the reply_id emitted in the `request` signal.
##   timeout_ms — milliseconds to wait before returning a timeout error.
##                Defaults to DEFAULT_TIMEOUT_MS (10 000 ms).
##
## Returns a standard result Dictionary:
##   Success:  {"success": true, "result": {...}}
##   Failure:  {"success": false, "error_code": "...", "error_message": "...", ...}
##   Timeout:  {"success": false, "error_code": "timeout",
##              "error_message": "No reply received within <N> ms",
##              "reply_id": reply_id}
##
## This is a coroutine — callers must use `await`:
##   var result := await $_MinervaIPC.await_reply("my-id-123")
func await_reply(reply_id: String, timeout_ms: int = DEFAULT_TIMEOUT_MS) -> Dictionary:
	if reply_id.is_empty():
		push_warning("[MinervaIPC] await_reply: reply_id must not be empty")
		return {
			"success": false,
			"error_code": "invalid_reply_id",
			"error_message": "reply_id must not be empty",
		}

	if _pending.has(reply_id):
		push_warning("[MinervaIPC] await_reply: reply_id '%s' is already being awaited" % reply_id)

	# Create a per-reply observer. Held in _pending to keep it alive.
	var observer := _ReplyObserver.new()
	_pending[reply_id] = observer

	# Schedule a timeout that fires the observer with a timeout sentinel if
	# the real reply has not arrived first.
	var timer := get_tree().create_timer(timeout_ms / 1000.0)
	timer.timeout.connect(func() -> void:
		if _pending.get(reply_id) == observer:
			observer._fire({
				"success": false,
				"error_code": "timeout",
				"error_message": "No reply received within %d ms" % timeout_ms,
				"reply_id": reply_id,
			})
	, CONNECT_ONE_SHOT)

	# Await the observer's one-shot signal. _pending holds the ref alive.
	var result: Dictionary = await observer.resolved

	# Clean up: erase only if still ours (re-entrancy guard).
	if _pending.get(reply_id) == observer:
		_pending.erase(reply_id)

	if result.get("error_code", "") == "timeout":
		push_warning(
			"[MinervaIPC] await_reply: timed out after %d ms for reply_id '%s'" % [
				timeout_ms, reply_id
			]
		)

	return result


# ---------------------------------------------------------------------------
# Broker-facing API (called by PluginScenePanelBroker, not by scenes)
# ---------------------------------------------------------------------------

## Called by the broker to deliver a reply to a pending await_reply coroutine.
##
## If reply_id has no pending awaiter (stale reply), the call is logged and
## dropped — it never raises an error.
func _reply(reply_id: String, result: Dictionary) -> void:
	if reply_id.is_empty():
		push_warning("[MinervaIPC] _reply: ignoring empty reply_id")
		return

	var observer: _ReplyObserver = _pending.get(reply_id, null)
	if observer == null:
		# Stale reply — the await_reply already timed out or was never started.
		push_warning(
			"[MinervaIPC] _reply: stale reply_id '%s' — no pending awaiter; dropping" % reply_id
		)
		return

	observer._fire(result)


# ---------------------------------------------------------------------------
# Private inner class: per-reply signal carrier
# ---------------------------------------------------------------------------

## Lightweight RefCounted that carries a single `resolved` signal for one
## in-flight await_reply call. Created per call, freed automatically when
## all references drop (after _pending erases it and the coroutine resumes).
class _ReplyObserver extends RefCounted:
	## Emitted exactly once when the reply (or timeout sentinel) is ready.
	signal resolved(result: Dictionary)

	## True once _fire() has been called; prevents double-fire.
	var _fired: bool = false

	## Fire the signal with a result. Idempotent after the first call.
	func _fire(result: Dictionary) -> void:
		if _fired:
			return
		_fired = true
		resolved.emit(result)
