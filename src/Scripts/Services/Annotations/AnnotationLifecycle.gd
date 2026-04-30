class_name AnnotationLifecycle
extends RefCounted
## Lifecycle state machine for v2 annotations.
##
## Valid states: open, applied, resolved, stale
##
## Legal transitions (from → to):
##   open     → applied   (apply-tool runs)
##   open     → resolved  (user resolves directly)
##   open     → stale     (substrate: anchor breaks)
##   applied  → resolved  (user verifies)
##   resolved → open      (user reopens — only legal back-transition)
##   stale    → open      (repair)
##
## All other transitions are illegal (returns false).
## Self-transitions (same state) are illegal.

## All lifecycle state string constants.
const STATE_OPEN     := "open"
const STATE_APPLIED  := "applied"
const STATE_RESOLVED := "resolved"
const STATE_STALE    := "stale"

## All valid states as a set for quick membership check.
const VALID_STATES: PackedStringArray = ["open", "applied", "resolved", "stale"]

## Legal transitions encoded as a set of "from:to" keys.
## NOTE: stale→resolved is NOT in this set (stale must go via open first).
## NOTE: applied→open is NOT in this set (no rollback from applied).
## NOTE: resolved→applied is NOT in this set.
const _LEGAL: PackedStringArray = [
	"open:applied",
	"open:resolved",
	"open:stale",
	"applied:resolved",
	"resolved:open",
	"stale:open",
]


## Returns true if the transition from → to is legal per the state machine.
## Returns false for illegal transitions, unknown states, and self-transitions.
## Does NOT raise/push_error — callers use the bool to gate behaviour.
static func can_transition(from: String, to: String) -> bool:
	if from == to:
		return false
	var key := "%s:%s" % [from, to]
	return key in _LEGAL


## Returns true if the given string is a valid lifecycle state.
static func is_valid_state(state: String) -> bool:
	return state in VALID_STATES
