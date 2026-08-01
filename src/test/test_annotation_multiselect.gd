extends SceneTree
## Boundary suite — annotation MULTI-SELECT substrate (campaign 2, round A8 unit 1,
## docket item 019fb59b45f3). Plan entries BT-32 … BT-36.
## Run: timeout 120 godot --headless --path src --script test/test_annotation_multiselect.gd
##
## These are not re-statements of the round's own asserts. Each case is written
## against a representation the production code does not itself consult:
##
##   BT-32  ghost-set resurrection   → the SIDECAR-SHAPED document envelope's
##                                     annotation count, never the set's size
##   BT-33  shift-click-miss         → set size + an independent `cancelled`
##                                     signal observer
##   BT-34  legacy-signal coherence  → a consumer wired to the OLD single-id
##                                     signal ONLY, compared to the set's primary
##   BT-35  multi-drag offsets       → serialized arrow endpoints in the stored
##                                     document, vs the pre-drag serialization
##                                     plus exactly one delta
##   BT-36  sub-gesture disarm       → a PAIR: a 2-set must disarm, and the 1-set
##                                     path must stay byte-identical to a host
##                                     that never touched the multi API at all
##
## Deliberate omission: the marquee's feel and the selection halo are perceptual
## and belong to the owner's HITL register (C2-CHECK 8 / BT-37), not here.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Annotation Multi-Select Boundary Tests ===\n")

	print("-- BT-32: ghost-set cannot resurrect --")
	test_ghost_set_two_single_writes_delete_removes_exactly_one()
	test_ghost_set_empty_primary_does_not_revive()

	print("\n-- BT-33: shift-click that misses --")
	test_additive_zero_travel_release_is_a_noop()
	test_plain_zero_travel_release_still_clears_and_cancels()

	print("\n-- BT-34: legacy selection_changed stays coherent --")
	test_legacy_only_consumer_never_sees_a_stale_primary()

	print("\n-- BT-35: multi-drag applies ONE delta to every member --")
	test_group_drag_serialized_offsets_are_one_shared_delta()
	test_group_drag_below_threshold_writes_nothing()

	print("\n-- BT-36: sub-gesture disarm pair --")
	test_sub_gesture_disarms_on_two_and_fires_on_one()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


func check_approx(description: String, actual: float, expected: float, tol: float = 0.001) -> void:
	if absf(actual - expected) <= tol:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected ~%.4f, got %.4f" % [description, expected, actual])


# ── Host ──────────────────────────────────────────────────────────────────────

## A host that stores its annotations INSIDE a sidecar-shaped envelope — the
## same {substrate_version, document, annotations, unknown_kinds} dict
## AnnotationSidecar.write_sidecar serialises. Assertions read `envelope`, so the
## oracle is the document representation rather than any selection state.
class SidecarMockHost extends AnnotationHost:
	## AnnotationOverlay/set_host connects to this unguarded; the AnnotationHost
	## base does not declare it, so every concrete host declares its own.
	signal annotations_changed()

	var envelope: Dictionary = {
		"substrate_version": 1,
		"document": {"path": "probe.mintxt", "kind": "mintxt"},
		"annotations": [],
		"unknown_kinds": [],
	}
	var registry: AnnotationRegistry = AnnotationRegistry.new()
	var removed_ids: Array = []

	var _selected: String = ""

	func get_registry() -> AnnotationRegistry:
		return registry

	func get_annotations() -> Array:
		return envelope["annotations"]

	func add_annotation(annotation: Dictionary) -> String:
		var id := str(annotation.get("id", "ann_%02d" % (envelope["annotations"] as Array).size()))
		var stored := annotation.duplicate(true)
		stored["id"] = id
		(envelope["annotations"] as Array).append(stored)
		annotations_changed.emit()
		return id

	func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
		var anns: Array = envelope["annotations"]
		for i in anns.size():
			if str((anns[i] as Dictionary).get("id", "")) == annotation_id:
				var stored := new_annotation.duplicate(true)
				stored["id"] = annotation_id
				anns[i] = stored
				annotations_changed.emit()
				return true
		return false

	## Mirrors the real hosts: removing the PRIMARY clears the primary, and
	## nothing else. Whether the multi-set survives that is precisely what the
	## substrate is on the hook for.
	func remove_annotation(annotation_id: String) -> bool:
		removed_ids.append(annotation_id)
		var anns: Array = envelope["annotations"]
		for i in anns.size():
			if str((anns[i] as Dictionary).get("id", "")) == annotation_id:
				anns.remove_at(i)
				if _selected == annotation_id:
					set_selected_annotation_id("")
				annotations_changed.emit()
				return true
		return false

	## Same unchanged-id early return the base has — real overriding hosts all
	## keep it, and BT-32's scenario depends on it being there.
	func set_selected_annotation_id(annotation_id: String) -> void:
		if annotation_id == _selected:
			return
		_selected = annotation_id
		selection_changed.emit(annotation_id)

	func get_selected_annotation_id() -> String:
		return _selected

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p


## Records every id handed to the OLD single-id signal, and nothing else. This is
## the stand-in for cad / presentation / hello / nametag consumers, none of which
## know the multi API exists.
class LegacySignalConsumer extends RefCounted:
	var last_seen: String = "<never subscribed>"
	var calls: int = 0

	func on_selection_changed(annotation_id: String) -> void:
		last_seen = annotation_id
		calls += 1


## A stand-in for the pcb route-hint sub-gestures (bend-handle drag, via insert).
## It consults the SAME substrate predicate those tools do —
## AnnotationHost.multi_selected_for — and refuses to act when it cannot name one
## unambiguous target. Nothing about the check lives in this class; mutate
## multi_selected_for and this tool changes its mind.
class SubGestureProbe extends RefCounted:
	var disarmed: bool = false
	var acted_on: String = ""

	func attempt(host: AnnotationHost) -> Dictionary:
		disarmed = false
		acted_on = ""
		if AnnotationHost.multi_selected_for(host):
			disarmed = true
			return {"fired": false, "reason": "needs exactly one hint"}
		var ids := AnnotationHost.selected_ids_for(host)
		if ids.is_empty():
			return {"fired": false, "reason": "nothing selected"}
		acted_on = ids[0]
		return {"fired": true, "target": acted_on}


# ── Fixtures ──────────────────────────────────────────────────────────────────

## Arrows, not stub boxes: AnnotationKind.transform_primitives moves an arrow's
## `from`/`to`, so BT-35 can read real coordinates back out of the document.
func _arrow(id: String, fx: float, fy: float, tx: float, ty: float) -> Dictionary:
	return {
		"id": id,
		"author": "human",
		"kind": "2d_arrow",
		"view_context": "test",
		"primitives": [{"kind": "arrow", "from": [fx, fy], "to": [tx, ty]}],
		"created_at": "2026-08-01T00:00:00Z",
	}


## Three arrows, well apart, so a hit-test at one never reaches another.
##   ann_a  (0,0)   → (40,0)
##   ann_b  (0,200) → (40,200)
##   ann_c  (0,400) → (40,400)
func _make_host() -> SidecarMockHost:
	var host := SidecarMockHost.new()
	BuiltinKinds.register_all(host.registry)
	host.add_annotation(_arrow("ann_a", 0.0, 0.0, 40.0, 0.0))
	host.add_annotation(_arrow("ann_b", 0.0, 200.0, 40.0, 200.0))
	host.add_annotation(_arrow("ann_c", 0.0, 400.0, 40.0, 400.0))
	return host


func _make_tool(host: SidecarMockHost) -> AnnotationTransformTool:
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)
	return tool


## Wire the tool's writes back into the host, exactly as
## AnnotationOverlay._on_tool_annotation_modified does.
func _wire_writes(tool: AnnotationTransformTool, host: SidecarMockHost) -> void:
	tool.annotation_modified.connect(func(id: String, ann: Dictionary) -> void:
		host.update_annotation(id, ann)
	)


## Ids still present in the sidecar envelope, in document order.
func _envelope_ids(host: SidecarMockHost) -> PackedStringArray:
	var out := PackedStringArray()
	for ann in host.envelope["annotations"]:
		out.append(str((ann as Dictionary).get("id", "")))
	return out


## The arrow's tail point as SERIALISED in the envelope — the representation a
## sidecar write would put on disk, not anything the tool holds.
func _envelope_tail(host: SidecarMockHost, id: String) -> Vector2:
	for ann in host.envelope["annotations"]:
		var d: Dictionary = ann
		if str(d.get("id", "")) != id:
			continue
		for prim in d.get("primitives", []):
			if prim is Dictionary and (prim as Dictionary).get("kind", "") == "arrow":
				var from_v: Array = (prim as Dictionary).get("from", [0, 0])
				return Vector2(float(from_v[0]), float(from_v[1]))
	return Vector2(NAN, NAN)


# ══════════════════════════════════════════════════════════════════════════════
# BT-32 — the ghost set (cold review F1)
# ══════════════════════════════════════════════════════════════════════════════
#
# The failure this pins is NOT "the getter reports too many ids". It is "Delete
# destroys an annotation the user never selected", which is why the oracle is the
# document envelope's contents and not the selection set's size.
#
# The scenario needs TWO single-id writes with NO READ BETWEEN THEM. That is the
# whole point of review F1: the read-time collapse in get_selected_annotation_ids
# heals a set the moment anyone looks at it, so a test that peeks between the two
# writes proves nothing. Nothing below calls a selection getter until Delete.

func test_ghost_set_two_single_writes_delete_removes_exactly_one() -> void:
	print("test_ghost_set_two_single_writes_delete_removes_exactly_one:")
	var host := _make_host()

	# 1. Marquee-equivalent: three selected, primary ann_c.
	host.set_selected_annotation_ids(PackedStringArray(["ann_a", "ann_b", "ann_c"]), "ann_c")

	# 2. A single-id call site retargets (a dock click, a kind's select-one tool,
	#    an MCP retarget, a host clearing selection). 3. Another lands back on the
	#    id the set was recorded against. NO getter call in between, on purpose.
	host.set_selected_annotation_id("ann_a")
	host.set_selected_annotation_id("ann_c")

	# 4. Delete.
	var tool := _make_tool(host)
	var consumed := tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)
	check("Delete is consumed", consumed)

	check_eq("sidecar envelope keeps 2 of 3 annotations",
		(host.envelope["annotations"] as Array).size(), 2)
	check_eq("exactly one remove_annotation call reached the host",
		host.removed_ids.size(), 1)
	check_eq("and it was the one the user could see selected",
		host.removed_ids, ["ann_c"])
	var survivors := _envelope_ids(host)
	check("ann_a survived", survivors.has("ann_a"))
	check("ann_b survived", survivors.has("ann_b"))


func test_ghost_set_empty_primary_does_not_revive() -> void:
	print("test_ghost_set_empty_primary_does_not_revive:")
	# The same family through the cleared-primary door: a host clears selection
	# inside remove_annotation, then something re-selects the id the set was
	# recorded against. Again, no read until the Delete.
	var host := _make_host()
	host.set_selected_annotation_ids(PackedStringArray(["ann_a", "ann_b"]), "ann_b")
	host.set_selected_annotation_id("")
	host.set_selected_annotation_id("ann_b")

	var tool := _make_tool(host)
	tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)

	check_eq("clear-then-reselect deletes exactly one",
		(host.envelope["annotations"] as Array).size(), 2)
	check_eq("and ann_a was never touched", host.removed_ids, ["ann_b"])


# ══════════════════════════════════════════════════════════════════════════════
# BT-33 — shift-click that misses (cold review F2)
# ══════════════════════════════════════════════════════════════════════════════
#
# Two independent readings per case: the SET SIZE, and a `cancelled` observer.
# The signal matters as much as the set — `cancelled` untoggles the toolbar and
# flips the overlay's mouse_filter back to IGNORE, so a spurious one rips the
# tool out from under a gesture that is still in progress.

func test_additive_zero_travel_release_is_a_noop() -> void:
	print("test_additive_zero_travel_release_is_a_noop:")
	var host := _make_host()
	host.set_selected_annotation_ids(PackedStringArray(["ann_a", "ann_b", "ann_c"]), "ann_c")

	var tool := _make_tool(host)
	var cancelled_count: Array = [0]
	tool.cancelled.connect(func() -> void: cancelled_count[0] += 1)

	# Empty space, well clear of all three arrows (which live on x∈[0,40]).
	var miss := Vector2(900.0, 900.0)
	tool.on_pointer_down(miss, MOUSE_BUTTON_LEFT, KEY_MASK_SHIFT)
	# Zero travel: the release lands on the very same pixel the press did.
	tool.on_pointer_up(miss, MOUSE_BUTTON_LEFT, KEY_MASK_SHIFT)

	check_eq("shift-click-miss leaves all 3 selected",
		host.get_selected_annotation_ids().size(), 3)
	check_eq("primary is untouched", host.get_selected_annotation_id(), "ann_c")
	check_eq("no `cancelled` was emitted", cancelled_count[0], 0)

	# A 2 px slip is still "zero travel" (SELECT_DRAG_THRESHOLD_PX is 3.0 at
	# zoom 1) — the user's hand, not a marquee.
	tool.on_pointer_down(miss, MOUSE_BUTTON_LEFT, KEY_MASK_SHIFT)
	tool.on_pointer_move(miss + Vector2(2.0, 0.0))
	tool.on_pointer_up(miss + Vector2(2.0, 0.0), MOUSE_BUTTON_LEFT, KEY_MASK_SHIFT)
	check_eq("a 2 px slip is still a no-op", host.get_selected_annotation_ids().size(), 3)
	check_eq("still no `cancelled`", cancelled_count[0], 0)


func test_plain_zero_travel_release_still_clears_and_cancels() -> void:
	print("test_plain_zero_travel_release_still_clears_and_cancels:")
	# The contrast leg. Without it, "additive miss is a no-op" would also be
	# satisfied by a branch that made EVERY empty click a no-op — which would
	# break click-away-to-deselect and never restore the camera orbit.
	var host := _make_host()
	host.set_selected_annotation_ids(PackedStringArray(["ann_a", "ann_b", "ann_c"]), "ann_c")

	var tool := _make_tool(host)
	var cancelled_count: Array = [0]
	tool.cancelled.connect(func() -> void: cancelled_count[0] += 1)

	var miss := Vector2(900.0, 900.0)
	tool.on_pointer_down(miss, MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_up(miss, MOUSE_BUTTON_LEFT, 0)

	check_eq("plain click on empty space clears the whole set",
		host.get_selected_annotation_ids().size(), 0)
	check_eq("and emits `cancelled` exactly once", cancelled_count[0], 1)


# ══════════════════════════════════════════════════════════════════════════════
# BT-34 — the legacy single-id signal never goes stale
# ══════════════════════════════════════════════════════════════════════════════
#
# The consumer below is subscribed to selection_changed(String) and NOTHING else,
# the way HelloAnnotationHost / presentation / cad / nametag consumers are. Its
# last-seen id is compared against the set's own virtual primary after every
# write. Two readings, two owners: if the multi API ever stops routing its
# primary through the virtual single-id setter, this diverges immediately.

func test_legacy_only_consumer_never_sees_a_stale_primary() -> void:
	print("test_legacy_only_consumer_never_sees_a_stale_primary:")
	var host := _make_host()
	var consumer := LegacySignalConsumer.new()
	host.selection_changed.connect(consumer.on_selection_changed)

	var steps: Array = [
		{"ids": ["ann_a", "ann_b"],          "primary": "ann_b"},
		{"ids": ["ann_a", "ann_b", "ann_c"], "primary": "ann_c"},
		{"ids": ["ann_a"],                   "primary": "ann_a"},
		{"ids": ["ann_b", "ann_c"],          "primary": "ann_b"},
		{"ids": [],                          "primary": ""},
	]
	# The comparison target is the primary this table DECLARES, not the host's own
	# get_selected_annotation_id(). Comparing the two live readings to each other
	# passes happily when they go stale together — measured: a "legacy signal only
	# on the first set write" regression keeps them equal and both wrong.
	for step in steps:
		var ids := PackedStringArray()
		for id in (step["ids"] as Array):
			ids.append(str(id))
		var want := str(step["primary"])
		host.set_selected_annotation_ids(ids, want)
		check_eq("legacy consumer sees '%s' after set write %s" % [want, str(step["ids"])],
			consumer.last_seen, want)
		check_eq("host's own primary agrees after set write %s" % str(step["ids"]),
			host.get_selected_annotation_id(), want)
		check_eq("and the set reports %d member(s)" % ids.size(),
			host.get_selected_annotation_ids().size(), ids.size())

	check("consumer was actually exercised", consumer.calls >= 4)

	# A SET-ONLY change (membership moves, primary does not) must leave the
	# legacy consumer holding a value that is still CORRECT — silence is only
	# acceptable because there is nothing new to say.
	host.set_selected_annotation_ids(PackedStringArray(["ann_a", "ann_b"]), "ann_b")
	var before := consumer.calls
	host.set_selected_annotation_ids(PackedStringArray(["ann_b", "ann_c"]), "ann_b")
	check_eq("a set-only change does not wake the legacy signal", consumer.calls, before)
	check_eq("and what it still holds is the live primary",
		consumer.last_seen, host.get_selected_annotation_id())


# ══════════════════════════════════════════════════════════════════════════════
# BT-35 — one delta, every member
# ══════════════════════════════════════════════════════════════════════════════
#
# Oracle: the arrows' tail points AS STORED IN THE DOCUMENT after the gesture,
# against their pre-drag stored values plus a single hand-computed vector. The
# tool's own snapshots are never consulted.
#
# Hand-derived: press at (20,0) — inside ann_a's shaft — and move to (95,60).
# Delta = (75, 60), which is 96 px of travel, comfortably past the 3 px
# threshold. Expected tails: ann_a (75,60), ann_b (75,260), ann_c (75,460).

func test_group_drag_serialized_offsets_are_one_shared_delta() -> void:
	print("test_group_drag_serialized_offsets_are_one_shared_delta:")
	var host := _make_host()
	var tool := _make_tool(host)
	_wire_writes(tool, host)

	var before := {
		"ann_a": _envelope_tail(host, "ann_a"),
		"ann_b": _envelope_tail(host, "ann_b"),
		"ann_c": _envelope_tail(host, "ann_c"),
	}
	check("pre-drag tails read out of the envelope", before["ann_a"] == Vector2(0.0, 0.0))

	host.set_selected_annotation_ids(PackedStringArray(["ann_a", "ann_b", "ann_c"]), "ann_a")

	var press := Vector2(20.0, 0.0)
	var delta := Vector2(75.0, 60.0)
	tool.on_pointer_down(press, MOUSE_BUTTON_LEFT, 0)
	# More than one motion: a member whose offset is recomputed from the live
	# pointer rather than its own snapshot only diverges once the gesture has
	# more than a single step.
	tool.on_pointer_move(press + delta * 0.5)
	tool.on_pointer_move(press + delta)
	tool.on_pointer_up(press + delta, MOUSE_BUTTON_LEFT, 0)

	for id in ["ann_a", "ann_b", "ann_c"]:
		var want: Vector2 = (before[id] as Vector2) + delta
		var got := _envelope_tail(host, str(id))
		check_approx("%s tail x is its own origin + one delta" % id, got.x, want.x)
		check_approx("%s tail y is its own origin + one delta" % id, got.y, want.y)

	# Relative geometry is the deform detector: the members must not have
	# converged on each other, which is exactly what a shared-origin bug looks
	# like when every member happens to land somewhere plausible.
	var ab := _envelope_tail(host, "ann_b") - _envelope_tail(host, "ann_a")
	var bc := _envelope_tail(host, "ann_c") - _envelope_tail(host, "ann_b")
	check_approx("ann_a→ann_b spacing is preserved", ab.y, 200.0)
	check_approx("ann_b→ann_c spacing is preserved", bc.y, 200.0)
	check_approx("no lateral shear between members", ab.x, 0.0)


func test_group_drag_below_threshold_writes_nothing() -> void:
	print("test_group_drag_below_threshold_writes_nothing:")
	# A plain CLICK on a member must leave the document byte-identical — the set
	# is not disturbed and nothing is written. This is what keeps "click a member
	# to make it primary" from dirtying the sidecar.
	var host := _make_host()
	var tool := _make_tool(host)
	_wire_writes(tool, host)
	host.set_selected_annotation_ids(PackedStringArray(["ann_a", "ann_b", "ann_c"]), "ann_a")

	var snapshot := (host.envelope["annotations"] as Array).duplicate(true)
	var press := Vector2(20.0, 0.0)
	tool.on_pointer_down(press, MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(press + Vector2(2.0, 0.0))
	tool.on_pointer_up(press + Vector2(2.0, 0.0), MOUSE_BUTTON_LEFT, 0)

	check("a sub-threshold press leaves the document byte-identical",
		host.envelope["annotations"] == snapshot)
	check_eq("and leaves the set intact", host.get_selected_annotation_ids().size(), 3)


# ══════════════════════════════════════════════════════════════════════════════
# BT-36 — the disarm PAIR
# ══════════════════════════════════════════════════════════════════════════════
#
# Neither half is an oracle alone. "Disarms on 2" is satisfied by a predicate
# that disarms on everything; "fires on 1" is satisfied by one that never
# disarms. Both, plus a byte-identity check of the single-selection result
# against a host driven ONLY through the legacy single-id API, is the oracle.

func test_sub_gesture_disarms_on_two_and_fires_on_one() -> void:
	print("test_sub_gesture_disarms_on_two_and_fires_on_one:")
	var probe := SubGestureProbe.new()

	# ── half 1: two selected → disarm, no target ──────────────────────────────
	var two := _make_host()
	two.set_selected_annotation_ids(PackedStringArray(["ann_a", "ann_b"]), "ann_b")
	var r2 := probe.attempt(two)
	check("2-set: sub-gesture refuses to fire", not bool(r2["fired"]))
	check("2-set: it reports itself disarmed", probe.disarmed)
	check_eq("2-set: nothing was acted on", probe.acted_on, "")

	# ── half 2: one selected via the MULTI api → fires ────────────────────────
	var one := _make_host()
	one.set_selected_annotation_ids(PackedStringArray(["ann_b"]), "ann_b")
	var r1 := probe.attempt(one)
	check("1-set via the multi API: sub-gesture fires", bool(r1["fired"]))
	check("1-set: not disarmed", not probe.disarmed)
	check_eq("1-set: acted on the one selected id", str(r1.get("target", "")), "ann_b")

	# ── half 3: byte-identity against a host that never saw the multi API ─────
	var legacy := _make_host()
	legacy.set_selected_annotation_id("ann_b")
	var r_legacy := probe.attempt(legacy)
	check_eq("the legacy single-id path returns a byte-identical result", r_legacy, r1)
	check_eq("and reads the same one-element id list",
		legacy.get_selected_annotation_ids(), one.get_selected_annotation_ids())

	# ── half 4: shrinking a 2-set back to 1 re-arms ───────────────────────────
	two.toggle_selected_annotation_id("ann_a")
	var r_shrunk := probe.attempt(two)
	check("dropping back to one member re-arms the sub-gesture", bool(r_shrunk["fired"]))
	check_eq("and it targets the surviving member", str(r_shrunk.get("target", "")), "ann_b")
