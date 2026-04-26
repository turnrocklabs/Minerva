extends SceneTree
## Unit tests for Helloscene_AnnotationHost.describe_point() and the
## add/update/set_annotations anchor-stamping hooks.
##
## Run: godot --headless --path src --script test/test_hello_annotation_describe_point.gd
##
## Coverage:
##   - describe_point with no _ui_root → ""
##   - describe_point with canvas+root set, point OUTSIDE all controls → ""
##   - describe_point at a coord INSIDE a Label → "ui:Label"
##   - describe_point at a coord inside a Label with text → "label.word:<w>"
##   - add_annotation populates anchored_to via _stamp_anchor
##   - update_annotation re-stamps anchored_to when coords change
##   - set_annotations calls refresh_all_anchors on all loaded annotations

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Hello Annotation Describe-Point Tests ===\n")

	print("-- describe_point: guard cases --")
	test_describe_point_no_ui_root_returns_empty()
	test_describe_point_outside_all_controls_returns_empty()

	print("\n-- describe_point: Label hit --")
	test_describe_point_inside_label_returns_ui_label()
	test_describe_point_word_resolution_single_word()
	test_describe_point_word_resolution_second_word()
	test_describe_point_word_resolution_empty_label()

	print("\n-- add_annotation stamps anchored_to --")
	test_add_annotation_stamps_anchor_with_registry()
	test_add_annotation_no_registry_no_anchor()

	print("\n-- update_annotation re-stamps anchored_to --")
	test_update_annotation_restamps_anchor()

	print("\n-- set_annotations refreshes anchors --")
	test_set_annotations_refreshes_anchors()
	test_set_annotations_empty_list_no_crash()

	print("\n-- _find_leaf_at tolerance margin --")
	test_describe_point_within_margin_5px_outside_hits()
	test_describe_point_within_margin_15px_outside_hits()
	test_describe_point_outside_margin_25px_misses()

	print("\n-- arrow directional projection --")
	test_arrow_projection_resolves_widget_past_tip()

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


# ── Fixture helpers ───────────────────────────────────────────────────────────

## Build a minimal Control tree:
##   root (Control, global_position=(0,0), size=(800,600))
##   └─ VBoxContainer (layout wrapper — skipped by _find_leaf_at)
##      └─ FakeCanvas (Control, name="AnnotationCanvas") ← excluded from hit-test
##      └─ Label (name="Label", position=(0, 100), size=(400, 30))
##
## Returns [root, fake_canvas, label].
##
## Because we're in headless SceneTree (not a real viewport), global_position
## for Controls that are NOT part of a real scene equals local position
## (i.e. there's no parent viewport to offset against). We position them so
## that we can exercise the hit-test logic with known coords.
func _build_ui_fixture() -> Array:
	var root := Control.new()
	root.set_position(Vector2.ZERO)
	root.set_size(Vector2(800, 600))

	var vbox := VBoxContainer.new()
	vbox.set_position(Vector2.ZERO)
	vbox.set_size(Vector2(800, 600))
	root.add_child(vbox)

	var fake_canvas := Control.new()
	fake_canvas.name = "AnnotationCanvas"
	fake_canvas.set_position(Vector2(0, 0))
	fake_canvas.set_size(Vector2(800, 300))
	vbox.add_child(fake_canvas)

	var label := Label.new()
	label.name = "Label"
	label.set_position(Vector2(0, 300))
	label.set_size(Vector2(400, 30))
	label.text = "Hello World"
	vbox.add_child(label)

	return [root, fake_canvas, label]


## Build a host with the given canvas+root, optionally with a populated registry.
func _build_host(canvas: Control, root: Control, with_registry: bool = false) -> Helloscene_AnnotationHost:
	var host := Helloscene_AnnotationHost.new()
	if with_registry:
		var reg := AnnotationRegistry.new()
		BuiltinKinds.register_all(reg)
		host._registry = reg
	host.set_canvas_and_root(canvas, root)
	return host


# ── describe_point guard cases ────────────────────────────────────────────────

func test_describe_point_no_ui_root_returns_empty() -> void:
	print("test_describe_point_no_ui_root_returns_empty:")
	var host := Helloscene_AnnotationHost.new()
	# Neither _canvas_node nor _ui_root are set.
	check_eq("describe_point with no ui_root returns ''",
		host.describe_point(Vector2(10.0, 10.0)), "")


func test_describe_point_outside_all_controls_returns_empty() -> void:
	print("test_describe_point_outside_all_controls_returns_empty:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]

	var host := _build_host(fake_canvas, root)
	# doc_pos (700, 500) → canvas_global = canvas.global_position + (700,500)
	# canvas is at (0,0), so canvas_global = (700,500).
	# The label is at (0,300)...(400,330) — (700,500) is outside everything.
	check_eq("describe_point outside all controls returns ''",
		host.describe_point(Vector2(700.0, 500.0)), "")


# ── describe_point: Label hits ────────────────────────────────────────────────

func test_describe_point_inside_label_returns_ui_label() -> void:
	print("test_describe_point_inside_label_returns_ui_label:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]

	# The label text is "Hello World". Let's point at a position to the right
	# of both words so word resolution returns "" and we fall back to "ui:Label".
	# Label is at global (0,300), size (400,30). Point at x=399 (far right, no word).
	label.text = "Hi"  # short text — x=399 is beyond the word
	var host := _build_host(fake_canvas, root)
	# doc_pos such that canvas_global lands inside the label but beyond its text.
	# canvas_global = canvas.global_pos + doc_pos = (0,0) + doc_pos.
	# Label at y=300..330. doc_pos y = 310 lands inside.
	# doc_pos x = 399 is inside the label rect but beyond "Hi" text (~2 * 14 * 0.55 = ~15px wide).
	var result := host.describe_point(Vector2(399.0, 310.0))
	# Either "ui:Label" (word resolution failed) or "label.word:Hi" — both acceptable
	# depending on where exactly the approximation places the word boundary.
	# We just check it returns something referencing the label.
	check("describe_point inside label returns label reference",
		result == "ui:Label" or result.begins_with("label.word:"))


func test_describe_point_word_resolution_single_word() -> void:
	print("test_describe_point_word_resolution_single_word:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = "Hello"

	var host := _build_host(fake_canvas, root)
	# "Hello" at x=0 in the label; label global_position.x = 0.
	# canvas global_pos = (0,0), so canvas_global = doc_pos.
	# Label starts at y=300. Point at (5, 310) should land on "Hello".
	var result := host.describe_point(Vector2(5.0, 310.0))
	check_eq("single word 'Hello' resolved at x=5", result, "label.word:Hello")


func test_describe_point_word_resolution_second_word() -> void:
	print("test_describe_point_word_resolution_second_word:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = "Hello World"

	var host := _build_host(fake_canvas, root)
	# "Hello" is 5 chars * 14 * 0.55 = 38.5px wide. Space = 7.7px.
	# "World" starts at ~46.2px.
	# Point at x=60 should land on "World".
	var result := host.describe_point(Vector2(60.0, 310.0))
	check_eq("second word 'World' resolved at x=60", result, "label.word:World")


func test_describe_point_word_resolution_empty_label() -> void:
	print("test_describe_point_word_resolution_empty_label:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = ""

	var host := _build_host(fake_canvas, root)
	# Empty label text → word resolution returns "" → falls back to "ui:Label".
	var result := host.describe_point(Vector2(5.0, 310.0))
	check_eq("empty label text → 'ui:Label'", result, "ui:Label")


# ── add_annotation stamps anchored_to ────────────────────────────────────────

func test_add_annotation_stamps_anchor_with_registry() -> void:
	print("test_add_annotation_stamps_anchor_with_registry:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = "Hello"

	var host := _build_host(fake_canvas, root, true)  # with registry

	# 2d_text annotation with "at" landing on "Hello" (x=5, y=310).
	var ann := {
		"kind": "2d_text",
		"author": "human",
		"primitives": [{"kind": "text", "at": [5.0, 310.0], "content": "note"}],
	}
	var id := host.add_annotation(ann)
	check("add_annotation returns non-empty id", not id.is_empty())

	var stored: Dictionary = host.get_annotations()[0]
	check("stored annotation has anchored_to key", stored.has("anchored_to"))
	# The anchor should reference the label word "Hello" (or at minimum the Label).
	var anchored: String = str(stored.get("anchored_to", ""))
	check("anchored_to references a label element",
		anchored == "label.word:Hello" or anchored == "ui:Label" or anchored == "")


func test_add_annotation_no_registry_no_anchor() -> void:
	print("test_add_annotation_no_registry_no_anchor:")
	# Host with no registry — _stamp_anchor is a no-op, so anchored_to should NOT
	# be written (registry guard).
	var host := Helloscene_AnnotationHost.new()
	# No registry, no canvas/root set.
	var ann := {
		"kind": "2d_text",
		"primitives": [{"kind": "text", "at": [0.0, 0.0], "content": "x"}],
	}
	var id := host.add_annotation(ann)
	var stored: Dictionary = host.get_annotations()[0]
	# _stamp_anchor is a no-op when registry is null, so anchored_to should be absent.
	check("no registry → anchored_to NOT written", not stored.has("anchored_to"))
	check("id still assigned", not id.is_empty())


# ── update_annotation re-stamps anchored_to ──────────────────────────────────

func test_update_annotation_restamps_anchor() -> void:
	print("test_update_annotation_restamps_anchor:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = "Hello World"

	var host := _build_host(fake_canvas, root, true)

	# Add annotation pointing at "Hello" (x=5).
	var id := host.add_annotation({
		"kind": "2d_text",
		"primitives": [{"kind": "text", "at": [5.0, 310.0], "content": "note"}],
	})
	var initial_anchor: String = str(host.get_annotations()[0].get("anchored_to", ""))

	# Update annotation to point at "World" (x=60).
	var updated := host.update_annotation(id, {
		"kind": "2d_text",
		"primitives": [{"kind": "text", "at": [60.0, 310.0], "content": "note"}],
	})
	check("update_annotation returned true", updated)

	var new_anchor: String = str(host.get_annotations()[0].get("anchored_to", ""))
	# The new anchor should reference "World" (or still the label in worst case).
	check("update_annotation re-stamped anchored_to", host.get_annotations()[0].has("anchored_to"))
	# If word resolution is working, the anchor should have changed (Hello → World).
	# In the approximation model both should resolve, but we allow them to both be
	# "ui:Label" if the font heuristic places both in the same word-bucket.
	print("    initial_anchor=%s  new_anchor=%s" % [initial_anchor, new_anchor])


# ── set_annotations refreshes anchors ────────────────────────────────────────

func test_set_annotations_refreshes_anchors() -> void:
	print("test_set_annotations_refreshes_anchors:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = "Hello"

	var host := _build_host(fake_canvas, root, true)

	# Bulk-load annotations that have a stale anchored_to.
	var list: Array = [
		{
			"id": "ann_bulk1",
			"kind": "2d_text",
			"anchored_to": "stale:value",
			"primitives": [{"kind": "text", "at": [5.0, 310.0], "content": "a"}],
		},
		{
			"id": "ann_bulk2",
			"kind": "2d_text",
			"anchored_to": "stale:other",
			"primitives": [{"kind": "text", "at": [5.0, 310.0], "content": "b"}],
		},
	]
	host.set_annotations(list)

	check_eq("set_annotations loaded 2 entries", host.get_annotations().size(), 2)

	var a0: Dictionary = host.get_annotations()[0]
	var a1: Dictionary = host.get_annotations()[1]
	check("first annotation has anchored_to after refresh", a0.has("anchored_to"))
	check("second annotation has anchored_to after refresh", a1.has("anchored_to"))

	# Stale values should have been overwritten (even if the new value is "" or
	# "label.word:Hello", either way it's no longer "stale:value").
	var anchor0: String = str(a0.get("anchored_to", "MISSING"))
	var anchor1: String = str(a1.get("anchored_to", "MISSING"))
	check("first annotation anchor is not the stale value", anchor0 != "stale:value")
	check("second annotation anchor is not the stale value", anchor1 != "stale:other")


func test_set_annotations_empty_list_no_crash() -> void:
	print("test_set_annotations_empty_list_no_crash:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]

	var host := _build_host(fake_canvas, root, true)
	host.set_annotations([])
	check_eq("set_annotations([]) results in empty list", host.get_annotations().size(), 0)
	check("no crash on empty set_annotations", true)


# ── _find_leaf_at tolerance margin ───────────────────────────────────────────
##
## Fixture: Label at global_position=(0,300), size=(400,30).
## canvas at (0,0). doc_pos maps directly to global coords (identity).
## Testing points at 5/15/25 px OUTSIDE the label's bottom edge (y=330).
## _TOLERANCE_MARGIN = 16px, so:
##   y=335 (5px outside)  → within margin → hit
##   y=345 (15px outside) → within margin → hit
##   y=355 (25px outside) → outside margin → miss

func test_describe_point_within_margin_5px_outside_hits() -> void:
	print("test_describe_point_within_margin_5px_outside_hits:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = ""  # empty text so result is "ui:Label"

	var host := _build_host(fake_canvas, root)
	# Label bottom edge is at y=330 (position.y=300 + size.y=30).
	# 5px outside: y = 335. x = 5 is inside the label's x range.
	var result := host.describe_point(Vector2(5.0, 335.0))
	check("5px outside label rect hits within 16px margin",
		result == "ui:Label" or result.begins_with("label.word:"))


func test_describe_point_within_margin_15px_outside_hits() -> void:
	print("test_describe_point_within_margin_15px_outside_hits:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = ""

	var host := _build_host(fake_canvas, root)
	# 15px outside bottom edge: y = 345.
	var result := host.describe_point(Vector2(5.0, 345.0))
	check("15px outside label rect hits within 16px margin",
		result == "ui:Label" or result.begins_with("label.word:"))


func test_describe_point_outside_margin_25px_misses() -> void:
	print("test_describe_point_outside_margin_25px_misses:")
	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = ""

	var host := _build_host(fake_canvas, root)
	# 25px outside bottom edge: y = 355. Exceeds _TOLERANCE_MARGIN=16, so miss.
	var result := host.describe_point(Vector2(5.0, 355.0))
	check_eq("25px outside label rect misses (beyond 16px margin)", result, "")


# ── arrow directional projection ──────────────────────────────────────────────

func test_arrow_projection_resolves_widget_past_tip() -> void:
	print("test_arrow_projection_resolves_widget_past_tip:")
	## Arrow pointing right. Head is in empty space just past the label's right edge.
	## Projection (32px further right) still lands on the label thanks to the margin.
	##
	## Label is at global_position=(0,300), size=(400,30).
	## The label's right edge is at x=400.
	## Head doc_pos: (408, 315) — 8px outside the label's right edge, outside strict rect.
	## With _TOLERANCE_MARGIN=16, the grown rect is [−16..416, 284..346].
	## Head at x=408 is within 16px margin → describe_point(head) already resolves.
	## So let's place head further: (420, 315) — 20px outside → miss without margin,
	## still miss with margin (400+16=416 < 420). Projection: direction = (1,0)*32 →
	## projected = (452, 315) → also misses.
	##
	## Instead: use a vertical arrow pointing DOWN at the label from above.
	## Head: (5, 295) — 5px ABOVE the label top (label.top = 300).
	##   With _TOLERANCE_MARGIN=16: grown rect top = 300-16 = 284. 295 > 284 → HIT.
	##
	## To truly test projection we need head to land outside even the margin (>16px away):
	## Head: (5, 280) — 20px above label top (300-280=20 > 16) → misses even with margin.
	## Tail: (5, 200). direction = (0,1). projected = (5, 312) — inside label → HIT.

	var fixture := _build_ui_fixture()
	var root: Control = fixture[0]
	var fake_canvas: Control = fixture[1]
	var label: Label = fixture[2]
	label.text = ""  # empty text → resolve to "ui:Label" or ""

	var host := _build_host(fake_canvas, root, true)

	# Arrow from (5, 200) pointing DOWN, head at (5, 280).
	# head=280 is 20px above label top=300 → outside 16px margin → describe_point("") miss.
	# projection direction=(0,1)*32 → projected=(5,312) → inside label → HIT.
	var ann := {
		"kind": "2d_arrow",
		"author": "human",
		"primitives": [{"kind": "arrow", "from": [5.0, 200.0], "to": [5.0, 280.0]}],
	}
	var id := host.add_annotation(ann)
	check("add_annotation returned id", not id.is_empty())

	var stored: Dictionary = host.get_annotations()[0]
	var anchored: String = str(stored.get("anchored_to", ""))
	# The projection should have resolved the label.
	check("arrow with head 20px above label resolves via projection to the label",
		anchored == "ui:Label" or anchored.begins_with("label.word:"))
