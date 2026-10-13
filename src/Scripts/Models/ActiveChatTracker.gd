class_name ActiveChatTracker
extends RefCounted
## Decides when the chat on screen has really changed, for ChatPane's
## chat_active_changed. The pane asks for a check whenever the visible chat
## might have changed and runs it once, a frame later; a change is reported
## only when the whole payload (ChatEventPayloads.active_chat) differs from the
## last one reported. So re-selects and a switch-and-restore inside one frame
## report nothing, while a rename or regroup of the visible chat does. The
## first check only records the starting chat: start-up is not a change.

var _pending := false
var _reported: Dictionary = {}
var _has_reported := false


## True when the caller should schedule the check: none is pending yet.
func request_check() -> bool:
	if _pending:
		return false
	_pending = true
	return true


## Settles the pending check against the payload now; true when it is a change
## to report.
func settle(payload: Dictionary) -> bool:
	_pending = false
	if _has_reported and payload == _reported:
		return false
	var first := not _has_reported
	_reported = payload.duplicate()
	_has_reported = true
	return not first
