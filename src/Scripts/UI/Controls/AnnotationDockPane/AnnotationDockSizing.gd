class_name AnnotationDockSizing
extends RefCounted
## Height policy for the annotation dock pane.
##
## One place for the rules the dock must never violate: it opens at a third of
## the host editor's height and may never take more than half of it — whether
## that height came from the opening default, a user drag of the grip, or a
## window resize. Pure math (no node access) so the pane and its tests read the
## same rules, and so the policy can be checked without a live layout.

## Share of the editor's height the dock takes when it is first expanded.
const OPEN_FRACTION := 1.0 / 3.0
## Hard cap: the document keeps at least the other half at all times.
const MAX_FRACTION := 0.5
## Floor for the whole pane — below this the grip, chevron and toolbar stop
## being usable, so a very short editor gets a pane at the cap instead.
const MIN_HEIGHT := 110.0
## Floor for the pane's scrolling region, so a squeezed pane still shows a row
## and its scrollbar rather than a zero-height slit.
const MIN_LIST_HEIGHT := 44.0


## Height the dock takes the first time it expands in a given editor.
static func opening_height(available: float) -> float:
	return clamp_height(available * OPEN_FRACTION, available)


## Clamps a wanted height into [MIN_HEIGHT, half the editor]. The cap wins when
## the two fight: in an editor too short for MIN_HEIGHT the pane gets exactly
## half rather than overrunning the document.
static func clamp_height(desired: float, available: float) -> float:
	if available <= 0.0:
		return maxf(desired, MIN_HEIGHT)
	var cap := available * MAX_FRACTION
	if cap <= MIN_HEIGHT:
		return cap
	return clampf(desired, MIN_HEIGHT, cap)
