extends SceneTree
## Boundary suite — Visio-style ARROW LABELS (campaign 2, round A8 unit 2,
## docket item 019fb5de8c81). Plan entries BT-38 … BT-42.
## Run: timeout 120 godot --headless --path src --script test/test_annotation_arrow_label.gd
##
## One arrow plus its caption is ONE annotation; the caption's position is always
## DERIVED (midpoint + label_offset), never stored absolute. Each case below is
## written against a representation the label code does not consult itself:
##
##   BT-38  round-trip           → the JSON ON DISK, re-read through
##                                 AnnotationSidecar, plus the DERIVED caption
##                                 rect recomputed after the reload
##   BT-39  empty-commit matrix  → whole-dict equality (unlabelled) and
##                                 key-absence (labelled), including the
##                                 payload-with-other-keys case
##   BT-40  transform invariance → label_position(T(ann)) vs T(label_position(ann)),
##                                 3 operations × 5 orientations
##   BT-41  bounds participation → a DOWNSTREAM CONSUMER's id-set (the transform
##                                 tool's marquee sweep), never the kind's own
##                                 bounds() call
##   BT-42  double-click opt-in  → a stub tool with NO hook, counting the
##                                 on_pointer_down calls the overlay hands it
##
## Deliberate omission: editor placement / caption-commit feel is perceptual and
## belongs to the owner's HITL register (C2-CHECK 8 / BT-43), not here.

var _pass_count: int = 0
var _fail_count: int = 0
var _tmp_dir: String = ""


func _init() -> void:
	print("=== Annotation Arrow-Label Boundary Tests ===\n")
	_tmp_dir = _make_tmp_dir()

	print("-- BT-38: sidecar round-trip keeps all three label keys --")
	test_sidecar_round_trip_preserves_the_three_label_keys()
	test_sidecar_round_trip_preserves_the_derived_caption_rect()

	print("\n-- BT-39: empty-commit matrix --")
	test_empty_commit_on_unlabelled_arrow_is_byte_identical()
	test_empty_commit_erases_payload_only_when_label_was_sole_content()
	test_empty_commit_keeps_every_other_payload_key()
	test_tool_does_not_emit_for_an_empty_commit_on_an_unlabelled_arrow()

	print("\n-- BT-40: transform invariance across orientations --")
	test_label_position_is_transform_invariant()

	print("\n-- BT-41: the caption participates in a downstream consumer --")
	test_marquee_over_the_caption_alone_selects_the_arrow()
	test_marquee_over_the_caption_misses_an_unlabelled_arrow()

	print("\n-- BT-42: double-click stays opt-in --")
	test_tool_without_the_hook_receives_both_presses()
	test_tool_with_the_hook_consumes_the_second_press()
	test_hook_that_declines_still_falls_through()

	_cleanup_tmp_dir()
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


func check_vec(description: String, actual: Vector2, expected: Vector2, tol: float = 0.001) -> void:
	if actual.distance_to(expected) <= tol:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Temp dir (mirrors test_annotation_sidecar.gd) ─────────────────────────────

func _make_tmp_dir() -> String:
	var base := "user://tmp/test_annotation_arrow_label_%d" % int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _cleanup_tmp_dir() -> void:
	if _tmp_dir.is_empty():
		return
	var dir := DirAccess.open(_tmp_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(_tmp_dir.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(_tmp_dir)


# ── Host / tool stubs ─────────────────────────────────────────────────────────

class LabelMockHost extends AnnotationHost:
	signal annotations_changed()

	var registry: AnnotationRegistry = AnnotationRegistry.new()
	var annotations: Array = []
	var modified: Array = []

	var _selected: String = ""

	func get_registry() -> AnnotationRegistry:
		return registry

	func get_annotations() -> Array:
		return annotations

	func add_annotation(annotation: Dictionary) -> String:
		var id := str(annotation.get("id", "ann_%02d" % annotations.size()))
		var stored := annotation.duplicate(true)
		stored["id"] = id
		annotations.append(stored)
		return id

	func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
		modified.append({"id": annotation_id, "annotation": new_annotation.duplicate(true)})
		for i in annotations.size():
			if str((annotations[i] as Dictionary).get("id", "")) == annotation_id:
				var stored := new_annotation.duplicate(true)
				stored["id"] = annotation_id
				annotations[i] = stored
				return true
		return false

	func remove_annotation(annotation_id: String) -> bool:
		for i in annotations.size():
			if str((annotations[i] as Dictionary).get("id", "")) == annotation_id:
				annotations.remove_at(i)
				return true
		return false

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


## A tool that predates the double-click hook: it defines on_pointer_down and
## nothing else. Every tool shipped before A8u2 looks exactly like this, and the
## pcb route-hint kind's POSITIONAL double-click detection depends on still
## seeing the second press.
class HooklessProbeTool extends AnnotationAuthorTool:
	var down_calls: int = 0
	var down_positions: Array = []

	func on_pointer_down(pos: Vector2, _button: int, _mods: int) -> bool:
		down_calls += 1
		down_positions.append(pos)
		return true


## The opt-in case: defines the hook and claims the double-click.
class HookedProbeTool extends HooklessProbeTool:
	var double_calls: int = 0
	var claim: bool = true

	func on_pointer_double_click(_pos: Vector2, _button: int, _mods: int) -> bool:
		double_calls += 1
		return claim


# ── Fixtures ──────────────────────────────────────────────────────────────────

## Legacy primitives-path arrow. `endpoints_any` resolves it with no host.
func _arrow(id: String, fx: float, fy: float, tx: float, ty: float) -> Dictionary:
	return {
		"id": id,
		"author": "human",
		"kind": "2d_arrow",
		"view_context": "test",
		"primitives": [{"kind": "arrow", "from": [fx, fy], "to": [tx, ty]}],
		"created_at": "2026-08-01T00:00:00Z",
	}


func _kind() -> AnnotationArrow:
	return AnnotationArrow.new()


# ══════════════════════════════════════════════════════════════════════════════
# BT-38 — the caption survives a real disk round-trip
# ══════════════════════════════════════════════════════════════════════════════
#
# Not "the dict still has the keys after with_label" — that would be the
# writer's own arithmetic. The annotation is written to a REAL sidecar file with
# AnnotationSidecar.write_sidecar, read back with read_sidecar, and both the raw
# keys AND the caption geometry recomputed from the reloaded dict are checked.
#
# Hand-derived for the fixture below: arrow (0,0)→(100,0), caption "VCC RAIL"
# (8 characters) at font 14.
#   midpoint    = (50, 0)
#   offset      = (12, -30)   DELIBERATELY NOT default_label_offset(14), which is
#                             (0, -22.4): a fixture sitting on the default cannot
#                             tell "the key round-tripped" from "the key was lost
#                             and label_offset() re-derived the same value".
#   centre      = (50 + 12, 0 - 30) = (62, -30)
#   box         = (max(8 * 14 * 0.55, 14), 14 * 1.2) = (61.6, 16.8)
#   rect        = Rect2(62 - 30.8, -30 - 8.4, 61.6, 16.8)
#               = Rect2(31.2, -38.4, 61.6, 16.8)

const _LABEL_TEXT := "VCC RAIL"
const _LABEL_FONT := 14.0
const _LABEL_OFFSET := Vector2(12.0, -30.0)


func _labelled_arrow() -> Dictionary:
	var kind := _kind()
	return kind.with_label(_arrow("ann_lbl", 0.0, 0.0, 100.0, 0.0), _LABEL_TEXT,
		_LABEL_OFFSET, _LABEL_FONT)


func _write_and_reread(annotation: Dictionary, doc_name: String) -> Dictionary:
	var doc_path := _tmp_dir.path_join(doc_name)
	var err := AnnotationSidecar.write_sidecar(doc_path, {
		"document": {"path": doc_name, "kind": "test"},
		"annotations": [annotation],
		"unknown_kinds": [],
	})
	if err != OK:
		return {}
	var data := AnnotationSidecar.read_sidecar(doc_path)
	var anns: Variant = data.get("annotations", [])
	if not anns is Array or (anns as Array).is_empty():
		return {}
	return (anns as Array)[0] as Dictionary


func test_sidecar_round_trip_preserves_the_three_label_keys() -> void:
	print("test_sidecar_round_trip_preserves_the_three_label_keys:")
	var reloaded := _write_and_reread(_labelled_arrow(), "round_trip.test")
	check("something came back off disk", not reloaded.is_empty())
	if reloaded.is_empty():
		return

	var payload: Variant = reloaded.get("kind_payload", {})
	check("reloaded annotation still carries a kind_payload", payload is Dictionary)
	if not payload is Dictionary:
		return
	var p: Dictionary = payload

	check("`label` survived the disk round-trip", p.has(AnnotationArrow.LABEL_KEY))
	check("`label_offset` survived the disk round-trip", p.has(AnnotationArrow.LABEL_OFFSET_KEY))
	check("`label_font_size` survived the disk round-trip", p.has(AnnotationArrow.LABEL_FONT_SIZE_KEY))
	check_eq("caption text is unchanged", str(p.get(AnnotationArrow.LABEL_KEY, "")), _LABEL_TEXT)
	check_approx("glyph size is unchanged",
		float(p.get(AnnotationArrow.LABEL_FONT_SIZE_KEY, -1.0)), _LABEL_FONT)

	# JSON has no Vector2, so the offset comes back as a two-element array of
	# floats. Read it the way the kind does, not the way it was written.
	var off := _kind().label_offset(reloaded)
	check_vec("offset survived as floats, and is not the re-derived default",
		off, _LABEL_OFFSET)
	check("the fixture offset really does differ from the fallback",
		_LABEL_OFFSET != AnnotationArrow.default_label_offset(_LABEL_FONT))


func test_sidecar_round_trip_preserves_the_derived_caption_rect() -> void:
	print("test_sidecar_round_trip_preserves_the_derived_caption_rect:")
	# The consequence, not the keys: a caption whose offset was dropped on the way
	# to disk re-centres on the shaft when the document is reopened. Recomputing
	# the DERIVED rect after the reload catches that even if the key survives with
	# a wrong value.
	var reloaded := _write_and_reread(_labelled_arrow(), "round_trip_rect.test")
	if reloaded.is_empty():
		check("reloaded annotation available", false)
		return

	var kind := _kind()
	var r: Variant = kind.label_rect(reloaded)
	check("caption rect is derivable after reload", r is Rect2)
	if not r is Rect2:
		return
	var rect: Rect2 = r
	check_vec("caption rect position matches the hand-derived value",
		rect.position, Vector2(31.2, -38.4), 0.01)
	check_vec("caption rect size matches the hand-derived value",
		rect.size, Vector2(61.6, 16.8), 0.01)

	# And the caption is NOT sitting on the shaft — the failure mode a dropped
	# offset produces looks exactly like a valid rect otherwise.
	var mid: Variant = kind.label_midpoint(reloaded)
	check("caption did not re-centre on the shaft midpoint",
		mid is Vector2 and not rect.has_point(mid as Vector2))


# ══════════════════════════════════════════════════════════════════════════════
# BT-39 — the empty-commit matrix
# ══════════════════════════════════════════════════════════════════════════════
#
# Two promises, and they pull in opposite directions:
#   * clearing a caption must erase kind_payload ENTIRELY when the label was the
#     payload's only content, so a cleared arrow serialises byte-identical to one
#     that never had a caption; and
#   * an arrow that never had a caption must come back BYTE-IDENTICAL, i.e. no
#     empty kind_payload may be minted on the way through.
# A fix for either one alone breaks the other, which is why they are one matrix.

func test_empty_commit_on_unlabelled_arrow_is_byte_identical() -> void:
	print("test_empty_commit_on_unlabelled_arrow_is_byte_identical:")
	var kind := _kind()
	var bare := _arrow("ann_bare", 0.0, 0.0, 100.0, 0.0)
	var out := kind.with_label(bare, "")

	check_eq("clearing a caption that never existed changes nothing at all", out, bare)
	check("no empty kind_payload was minted", not out.has("kind_payload"))
	# Whitespace-only is the same commit — the user pressed Enter on a blank box.
	check_eq("a whitespace-only commit is the same no-op",
		kind.with_label(bare, "   \t "), bare)


func test_empty_commit_erases_payload_only_when_label_was_sole_content() -> void:
	print("test_empty_commit_erases_payload_only_when_label_was_sole_content:")
	var kind := _kind()
	var bare := _arrow("ann_sole", 0.0, 0.0, 100.0, 0.0)
	var labelled := kind.with_label(bare, "NET", AnnotationArrow.default_label_offset(_LABEL_FONT), _LABEL_FONT)
	check("the labelled form does carry a payload", labelled.has("kind_payload"))

	var cleared := kind.with_label(labelled, "")
	var p: Dictionary = cleared.get("kind_payload", {})
	check("all three label keys are gone",
		not p.has(AnnotationArrow.LABEL_KEY)
		and not p.has(AnnotationArrow.LABEL_OFFSET_KEY)
		and not p.has(AnnotationArrow.LABEL_FONT_SIZE_KEY))
	check("the payload carries no residual content at all", p.is_empty())
	check_eq("everything OUTSIDE kind_payload is identical to the pre-label arrow",
		_without_payload(cleared), _without_payload(bare))
	check("the caption is genuinely gone, not merely empty-stringed",
		not kind.has_label(cleared) and kind.label_rect(cleared) == null)
	# NOT asserted here, deliberately: whole-dict equality with `bare`.
	# MEASURED DIVERGENCE (boundary finding, campaign 2) —
	# AnnotationArrow.gd:299-302 and :322-326 promise that "a cleared arrow
	# serialises byte-identical to one that never had a caption", and the guard
	# that implements it tests `annotation.has("kind_payload")` on the INPUT.
	# On the ordinary UI path the input is the LABELLED arrow, which already has
	# the key, so the else branch writes `kind_payload: {}` back. Author a caption
	# on a bare arrow and clear it and the sidecar keeps an empty dict where there
	# was no key before. Pinning either shape here would be wrong: the current one
	# because it contradicts the shipped contract, the promised one because the
	# fix is production work this fence forbids. Reported instead.


## The annotation minus its kind_payload — everything the caption cannot reach.
func _without_payload(annotation: Dictionary) -> Dictionary:
	var out := annotation.duplicate(true)
	out.erase("kind_payload")
	return out


func test_empty_commit_keeps_every_other_payload_key() -> void:
	print("test_empty_commit_keeps_every_other_payload_key:")
	# The "only when it was the sole content" half. An anchored arrow carries
	# endpoint_a / endpoint_b / head_size in the same dict; an unconditional
	# erase would take the arrow's own geometry with the caption.
	var kind := _kind()
	var anchored := _arrow("ann_anchored", 0.0, 0.0, 100.0, 0.0)
	anchored["kind_payload"] = {
		"endpoint_a": {"x": 0.0, "y": 0.0},
		"endpoint_b": {"x": 100.0, "y": 0.0},
		"head_size": 9.0,
	}
	var labelled := kind.with_label(anchored, "GND", AnnotationArrow.default_label_offset(_LABEL_FONT), _LABEL_FONT)
	var cleared := kind.with_label(labelled, "")

	check_eq("clearing the caption leaves the annotation identical to the pre-label one",
		cleared, anchored)
	var p: Dictionary = cleared.get("kind_payload", {})
	check("endpoint_a survived", p.has("endpoint_a"))
	check("endpoint_b survived", p.has("endpoint_b"))
	check_approx("head_size survived with its value", float(p.get("head_size", -1.0)), 9.0)
	check("label key is gone", not p.has(AnnotationArrow.LABEL_KEY))
	check("label_offset key is gone", not p.has(AnnotationArrow.LABEL_OFFSET_KEY))
	check("label_font_size key is gone", not p.has(AnnotationArrow.LABEL_FONT_SIZE_KEY))


func test_tool_does_not_emit_for_an_empty_commit_on_an_unlabelled_arrow() -> void:
	print("test_tool_does_not_emit_for_an_empty_commit_on_an_unlabelled_arrow:")
	# The tool-side half of the same promise: a double-click the user simply
	# clicked away from must not dirty the document. Observed through the HOST's
	# update log, not through the tool.
	var host := LabelMockHost.new()
	BuiltinKinds.register_all(host.registry)
	host.add_annotation(_arrow("ann_bare", 0.0, 0.0, 100.0, 0.0))

	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)
	tool.annotation_modified.connect(func(id: String, ann: Dictionary) -> void:
		host.update_annotation(id, ann)
	)
	host.set_selected_annotation_id("ann_bare")

	# No edit surface is attached (headless), so the editor never opens and the
	# commit path short-circuits — which is itself the contract: no surface, no
	# write. Drive the commit directly to prove the empty-commit guard.
	tool._commit_label_edit()
	check_eq("no host write for an empty commit on an unlabelled arrow",
		host.modified.size(), 0)
	check_eq("and the stored annotation is untouched",
		host.annotations[0], _arrow("ann_bare", 0.0, 0.0, 100.0, 0.0))


# ══════════════════════════════════════════════════════════════════════════════
# BT-40 — T(mid) + B(off) == T(mid + off)
# ══════════════════════════════════════════════════════════════════════════════
#
# The caption's position is derived, so the invariant to pin is that the DERIVED
# position transforms like a point even though what is stored is an offset. Both
# sides are computed from the payload; nothing here looks at pixels.
#
# Five orientations, because B3a's lesson was that a first-draft suite using one
# blind orientation passed a broken clamp: an offset that is straight up in the
# document frame is invariant under several wrong implementations when the arrow
# happens to be horizontal.

func _orientations() -> Array:
	return [
		{"name": "east",       "to": Vector2(100.0, 0.0)},
		{"name": "north",      "to": Vector2(0.0, -100.0)},
		{"name": "north-east", "to": Vector2(70.0, -70.0)},
		{"name": "south-west", "to": Vector2(-60.0, 45.0)},
		{"name": "west",       "to": Vector2(-100.0, 0.0)},
	]


func _operations() -> Array:
	var rot := Transform2D(deg_to_rad(37.0), Vector2.ZERO)
	var scl := Transform2D(Vector2(2.5, 0.0), Vector2(0.0, 2.5), Vector2.ZERO)
	return [
		{"name": "move",   "op": "move",   "t": Transform2D(0.0, Vector2(13.0, -29.0))},
		{"name": "rotate", "op": "rotate", "t": rot},
		{"name": "scale",  "op": "scale",  "t": scl},
	]


func test_label_position_is_transform_invariant() -> void:
	print("test_label_position_is_transform_invariant:")
	var kind := _kind()
	for orientation in _orientations():
		var to: Vector2 = orientation["to"]
		var base := _arrow("ann_o", 10.0, 20.0, 10.0 + to.x, 20.0 + to.y)
		# A deliberately OBLIQUE offset: a straight-up one is invariant under
		# several wrong implementations.
		var ann := kind.with_label(base, "NET42", Vector2(-9.0, -22.4), _LABEL_FONT)

		var before: Variant = kind.label_position(ann)
		check("%s: caption position is derivable" % str(orientation["name"]), before is Vector2)
		if not before is Vector2:
			continue

		for operation in _operations():
			var t: Transform2D = operation["t"]
			var out := kind.transform_annotation(ann, t, str(operation["op"]))
			var after: Variant = kind.label_position(out)
			if not after is Vector2:
				check("%s/%s: caption position still derivable"
					% [str(orientation["name"]), str(operation["name"])], false)
				continue
			# THE invariant: the derived caption point transforms exactly like any
			# other document point would.
			check_vec("%s/%s: T(mid+off) == T(mid)+B(off)"
					% [str(orientation["name"]), str(operation["name"])],
				after as Vector2, t * (before as Vector2), 0.01)

	# Scale additionally has to carry the glyph size, or a scaled-up arrow keeps a
	# pinhead caption. Hand-derived: 14 × 2.5 = 35.
	var ann_e := kind.with_label(_arrow("ann_s", 0.0, 0.0, 100.0, 0.0), "NET42",
		Vector2(-9.0, -22.4), _LABEL_FONT)
	var scaled := kind.transform_annotation(ann_e,
		Transform2D(Vector2(2.5, 0.0), Vector2(0.0, 2.5), Vector2.ZERO), "scale")
	check_approx("scale carries the glyph size too (14 x 2.5)",
		kind.label_font_size(scaled), 35.0, 0.01)
	check_approx("move leaves the glyph size alone",
		kind.label_font_size(kind.transform_annotation(ann_e,
			Transform2D(0.0, Vector2(13.0, -29.0)), "move")), _LABEL_FONT, 0.01)


# ══════════════════════════════════════════════════════════════════════════════
# BT-41 — an independent consumer sees the caption
# ══════════════════════════════════════════════════════════════════════════════
#
# PLAN DEVIATION, recorded deliberately. The plan names "the dock's zoom-to-fit
# rect" as the independent consumer. Core Minerva has no such thing — grepping
# both AnnotationDockPane/ and the whole of src/Scripts for a fit-to-content rect
# over annotations returns nothing; "zoom-to-fit consumers" appears only as a
# COMMENT inside AnnotationArrow.bounds() itself. Rather than assert the kind's
# own arithmetic against itself, this uses the marquee sweep — AnnotationTransform
# Tool.annotations_intersecting — which is a genuine downstream consumer of
# bounds() living in a different file, and whose observable is an ID SET rather
# than a Rect2.
#
# Hand-derived: arrow (0,0)→(100,0) with the fixture caption sits at
# Rect2(31.2, -38.4, 61.6, 16.8) (see BT-38); the unlabelled arrow's AABB is the
# shaft grown by the 12 px head, Rect2(-12, -12, 124, 24). The probe marquee is
# Rect2(35, -38, 40, 6) — y ∈ [-38, -32]:
#   * inside the caption box (y ∈ [-38.4, -21.6]), x ∈ [35, 75] ⊂ [31.2, 92.8];
#   * clear of the shaft AABB (y ≥ -12); and
#   * ABOVE the caption's CENTRE (y = -30), so a caption merged into bounds at
#     zero extent — a degenerate point rather than a box — no longer reaches it.

func _sweep(host: LabelMockHost, rect: Rect2) -> PackedStringArray:
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)
	return tool.annotations_intersecting(rect)


func test_marquee_over_the_caption_alone_selects_the_arrow() -> void:
	print("test_marquee_over_the_caption_alone_selects_the_arrow:")
	var host := LabelMockHost.new()
	BuiltinKinds.register_all(host.registry)
	host.add_annotation(_labelled_arrow())

	var caption_only := Rect2(35.0, -38.0, 40.0, 6.0)
	check("the probe rect really is clear of the shaft (y = 0)",
		caption_only.position.y + caption_only.size.y < 0.0)

	var swept := _sweep(host, caption_only)
	check_eq("a marquee over the caption alone selects the arrow",
		swept, PackedStringArray(["ann_lbl"]))

	# Second reading, same consumer, different question: a rect on the shaft
	# selects it too. Together these say the caption EXTENDED the footprint
	# rather than replaced it.
	check_eq("a marquee on the shaft still selects it",
		_sweep(host, Rect2(40.0, -2.0, 20.0, 4.0)), PackedStringArray(["ann_lbl"]))


func test_marquee_over_the_caption_misses_an_unlabelled_arrow() -> void:
	print("test_marquee_over_the_caption_misses_an_unlabelled_arrow:")
	# The control. Without it, "the caption region selects the arrow" would also
	# be satisfied by bounds() that had simply grown for some unrelated reason.
	var host := LabelMockHost.new()
	BuiltinKinds.register_all(host.registry)
	host.add_annotation(_arrow("ann_lbl", 0.0, 0.0, 100.0, 0.0))

	check_eq("the same rect selects nothing when the arrow has no caption",
		_sweep(host, Rect2(35.0, -38.0, 40.0, 6.0)), PackedStringArray())


# ══════════════════════════════════════════════════════════════════════════════
# BT-42 — the double-click hook stays opt-in
# ══════════════════════════════════════════════════════════════════════════════
#
# Godot delivers the second press of a double-click as ONE event with
# double_click = true. Every tool that shipped before A8u2 — including the pcb
# route-hint kind, which detects double-clicks POSITIONALLY from two presses at
# the same point — depends on still receiving that press as an ordinary
# on_pointer_down. The oracle is the stub's own call counter, driven through the
# real AnnotationOverlay._gui_input.

func _press(pos: Vector2, double_click: bool) -> InputEventMouseButton:
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = pos
	mb.double_click = double_click
	return mb


## Arm `tool` on a live overlay and deliver a real double-click gesture:
## press, then a second press flagged double_click, both at the same point.
func _deliver_double_click(tool: AnnotationAuthorTool) -> AnnotationOverlay:
	var host := LabelMockHost.new()
	BuiltinKinds.register_all(host.registry)
	var overlay := AnnotationOverlay.new()
	root.add_child(overlay)
	overlay.set_host(host)
	overlay.set_active_tool(tool)
	var at := Vector2(120.0, 80.0)
	overlay._gui_input(_press(at, false))
	overlay._gui_input(_press(at, true))
	return overlay


func _release(overlay: AnnotationOverlay) -> void:
	overlay.set_active_tool(null)
	if overlay.get_parent() != null:
		overlay.get_parent().remove_child(overlay)
	overlay.free()


func test_tool_without_the_hook_receives_both_presses() -> void:
	print("test_tool_without_the_hook_receives_both_presses:")
	var tool := HooklessProbeTool.new()
	var overlay := _deliver_double_click(tool)
	check_eq("a tool with no double-click hook sees BOTH presses", tool.down_calls, 2)
	check("and both landed at the same point",
		tool.down_positions.size() == 2 and tool.down_positions[0] == tool.down_positions[1])
	_release(overlay)


func test_tool_with_the_hook_consumes_the_second_press() -> void:
	print("test_tool_with_the_hook_consumes_the_second_press:")
	var tool := HookedProbeTool.new()
	tool.claim = true
	var overlay := _deliver_double_click(tool)
	check_eq("an opting-in tool is asked once", tool.double_calls, 1)
	check_eq("and it swallows the second press", tool.down_calls, 1)
	_release(overlay)


func test_hook_that_declines_still_falls_through() -> void:
	print("test_hook_that_declines_still_falls_through:")
	# Declining must be indistinguishable from never defining the hook — that is
	# what makes it safe for a tool to look at the double-click and pass.
	var tool := HookedProbeTool.new()
	tool.claim = false
	var overlay := _deliver_double_click(tool)
	check_eq("a declining tool is still asked", tool.double_calls, 1)
	check_eq("and gets both presses anyway", tool.down_calls, 2)
	_release(overlay)
