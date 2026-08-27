class_name WorkflowAnnotationList
extends VBoxContainer
## Workflow-annotation listing surface (pcb-ui-native-cluster §4, WC-2).
##
## The counterpart of AnnotationWorkbench: shows ONLY workflow-class
## annotations (AnnotationKind.workflow_class == true — e.g. pcb_route_hint)
## for ONE host, grouped by kind. The review workbench excludes exactly this
## set, so together the two surfaces partition a host's annotations with no
## overlap and no loss. MCP read surfaces are unaffected (separation is
## UI-only).
##
## Style deliberately mirrors AnnotationWorkbench's row idiom (#index select
## button + clipped summary label) so the dock reads as one unit. The control
## renders nothing (zero height) when the host has no workflow annotations.

signal annotation_selected(annotation_id: String)

const _MUTED := Color(1, 1, 1, 0.58)
const _SELECTED_ROW_COLOR := Color(0.4, 0.55, 0.85, 0.18)

## Clear-by-author (pcb-ui-native-cluster §5, WC-3): the context-menu labels,
## in display order, and the author_kind value each sends to the host.
const _CLEAR_MENU_ITEMS := [
	["Clear human-authored hints", "human"],
	["Clear AI-authored hints", "ai"],
	["Clear all hints", "all"],
]

## Per-annotation Accept/Reject (C5, docket 019f6c465fd8 — explicit-propose UX
## + proposal lifecycle). Minimal GENERIC extension to this file, mirroring
## the WC-3 clear_by_author fence-extension precedent above: clear_by_author
## is a single list-wide right-click menu keyed off ONE duck-typed host
## method; a per-row action needs a per-row decision, which that single global
## PopupMenu shape can't host (it has no notion of "which row"), so this adds
## two small inline row buttons instead of extending the menu.
##
## Zero pcb-specific vocabulary here on purpose — the trigger is the
## SUBSTRATE's own generic "machine-authored" signal (author.kind == "ai",
## the same convention AnnotationRenderContext.author_color("ai") keys cyan
## rendering off of — see _is_ai_authored below), gated on the host
## duck-typing BOTH verbs (accept_annotation_proposal / reject_annotation_
## proposal), exactly like clear_annotations_by_author's opt-in. Any plugin's
## workflow-class kind can opt in by (a) stamping author.kind="ai" on its
## machine-written annotations and (b) implementing the two host methods;
## pcb (route-hint proposals) is simply the first consumer. Buttons only
## appear on rows where both conditions hold — a human-authored hint, or a
## host without the methods, renders exactly as before.
const _ACCEPT_METHOD := "accept_annotation_proposal"
const _REJECT_METHOD := "reject_annotation_proposal"

## Consumed-record filter (Epoch UX2 station 1, owner ruling "once suggestions
## are applied, the real parts are what matter"): annotations whose lifecycle
## is "applied" are RECORDS — kept for provenance/citation/undo, no longer
## day-to-day work items — so the listing hides them by default behind a
## "Show consumed (N)" toggle. Generic on purpose: "applied" is substrate
## lifecycle vocabulary (any workflow-class kind may consume), zero pcb
## wording here, same convention as every other opt-in in this file.
const _CONSUMED_LIFECYCLE := "applied"

var _host: RefCounted = null
var _selected_id: String = ""

var _show_consumed: bool = false
## Count of consumed workflow annotations seen on the LAST _grouped_entries
## walk (side effect documented there) — feeds the toggle's label/visibility.
var _consumed_seen: int = 0

## Every selected id (A8u1 multi-select); _selected_id stays the primary. Rows
## highlight on set membership so a canvas marquee lights up every swept row.
var _selected_ids: PackedStringArray = PackedStringArray()

var _header: Label
var _groups_list: VBoxContainer
var _scroll: ScrollContainer
var _context_menu: PopupMenu = null
var _consumed_toggle: CheckBox = null


func _ready() -> void:
	_build_ui()
	refresh()


func set_host(host: RefCounted) -> void:
	if _host != null and _host.has_signal("annotations_changed") and _host.is_connected("annotations_changed", Callable(self, "refresh")):
		_host.disconnect("annotations_changed", Callable(self, "refresh"))
	if _host != null and _host.has_signal("selection_changed") and _host.is_connected("selection_changed", Callable(self, "_on_selection_changed")):
		_host.disconnect("selection_changed", Callable(self, "_on_selection_changed"))
	if _host != null and _host.has_signal("selection_set_changed") and _host.is_connected("selection_set_changed", Callable(self, "_on_selection_set_changed")):
		_host.disconnect("selection_set_changed", Callable(self, "_on_selection_set_changed"))
	_host = host
	_selected_id = ""
	_selected_ids = PackedStringArray()
	if _host != null and _host.has_signal("annotations_changed") and not _host.is_connected("annotations_changed", Callable(self, "refresh")):
		_host.connect("annotations_changed", Callable(self, "refresh"))
	if _host != null and _host.has_signal("selection_changed") and not _host.is_connected("selection_changed", Callable(self, "_on_selection_changed")):
		_host.connect("selection_changed", Callable(self, "_on_selection_changed"))
	# A8u1: the SET can change with the primary unmoved (re-marquee, shift-toggle
	# of a non-primary), and selection_changed stays silent then.
	if _host != null and _host.has_signal("selection_set_changed") and not _host.is_connected("selection_set_changed", Callable(self, "_on_selection_set_changed")):
		_host.connect("selection_set_changed", Callable(self, "_on_selection_set_changed"))
	if _host != null and _host.has_method("get_selected_annotation_id"):
		_selected_id = _host.get_selected_annotation_id()
	_selected_ids = _read_selected_ids()
	refresh()


## Data view of the current listing — one flat entry per workflow annotation,
## kind-grouped ordering (group order = first-seen kind order, entries keep
## host order within a group). Tests and MCP-ergonomic callers read this
## instead of scraping child controls.
## Entry shape: {kind: String, kind_display_name: String, id: String,
##               summary: String, lifecycle: String, drc_badge: String}.
## drc_badge is "" when the annotation carries no kind_payload.drc (see
## _drc_badge_text doc for the "⚠ N" / "⚠ ?" / "" contract).
func get_listing() -> Array:
	var groups := _grouped_entries()
	var flat: Array = []
	for kind_name in groups.keys():
		for entry in (groups[kind_name] as Array):
			flat.append(entry)
	return flat


func entry_count() -> int:
	return get_listing().size()


## Consumed-record filter accessors (tests / programmatic callers — same
## convention as clear_by_author's programmatic entry point above).
func set_show_consumed(value: bool) -> void:
	if _show_consumed == value:
		return
	_show_consumed = value
	if _consumed_toggle != null:
		_consumed_toggle.set_pressed_no_signal(value)
	refresh()


func get_show_consumed() -> bool:
	return _show_consumed


## Consumed workflow annotations currently known (whether or not shown).
func consumed_count() -> int:
	_grouped_entries()  # refreshes _consumed_seen
	return _consumed_seen


func refresh() -> void:
	if _groups_list == null:
		return
	for child in _groups_list.get_children():
		child.queue_free()

	var groups := _grouped_entries()
	var total := 0
	for kind_name in groups.keys():
		var entries: Array = groups[kind_name]
		total += entries.size()

		var group_header := Label.new()
		group_header.text = "%s (%d)" % [str((entries[0] as Dictionary).get("kind_display_name", kind_name)), entries.size()]
		group_header.add_theme_font_size_override("font_size", 11)
		group_header.add_theme_color_override("font_color", _MUTED)
		_groups_list.add_child(group_header)

		for entry in entries:
			_groups_list.add_child(_make_row(entry as Dictionary))

	# Consumed-filter toggle: label carries the hidden-record count, and it
	# only occupies dock space when there is at least one consumed record.
	if _consumed_toggle != null:
		_consumed_toggle.text = "Show consumed (%d)" % _consumed_seen
		_consumed_toggle.visible = _consumed_seen > 0

	# Zero workflow annotations → the whole surface disappears (no header
	# squatting in the dock for hosts that never use workflow kinds). A host
	# whose ONLY workflow annotations are hidden consumed records keeps the
	# header + toggle: the record must stay reachable, or the filter would be
	# a delete in disguise.
	if _header != null:
		_header.visible = total > 0 or _consumed_seen > 0
	if _scroll != null:
		_scroll.visible = total > 0


## True while the row content is wider than the viewport.
func is_scrolling_horizontally() -> bool:
	if _scroll == null:
		return false
	return _scroll.get_h_scroll_bar().visible


func _build_ui() -> void:
	if _groups_list != null:
		return
	add_theme_constant_override("separation", 4)
	# PASS (not the Control default STOP) so a right-click that lands on empty
	# space between/below rows still reaches _gui_input here instead of being
	# silently absorbed — rows (Buttons/Labels) still get first look at clicks
	# that land ON them.
	mouse_filter = Control.MOUSE_FILTER_PASS

	_header = Label.new()
	_header.text = "Workflow"
	_header.add_theme_font_size_override("font_size", 13)
	_header.visible = false
	add_child(_header)

	_consumed_toggle = CheckBox.new()
	_consumed_toggle.name = "ShowConsumedToggle"
	_consumed_toggle.text = "Show consumed (0)"
	_consumed_toggle.tooltip_text = "Consumed records: intents already applied to the document. Hidden by default — the real result is what matters now."
	_consumed_toggle.focus_mode = Control.FOCUS_NONE
	_consumed_toggle.add_theme_font_size_override("font_size", 11)
	_consumed_toggle.visible = false
	_consumed_toggle.toggled.connect(_on_show_consumed_toggled)
	add_child(_consumed_toggle)

	_scroll = ScrollContainer.new()
	_scroll.name = "WorkflowScroll"
	# Horizontal AUTO / vertical DISABLED — see AnnotationWorkbench's scroll for
	# both halves: rows shrink to the dock first with the scrollbar (wheel /
	# shift+wheel) as the fallback that keeps the right-hand row controls
	# reachable, and the dock pane owns the single vertical scroll.
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.visible = false
	add_child(_scroll)

	_groups_list = VBoxContainer.new()
	_groups_list.name = "WorkflowGroups"
	_groups_list.add_theme_constant_override("separation", 4)
	_groups_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_groups_list)

	_context_menu = PopupMenu.new()
	_context_menu.name = "ClearByAuthorMenu"
	for i in _CLEAR_MENU_ITEMS.size():
		_context_menu.add_item(str(_CLEAR_MENU_ITEMS[i][0]), i)
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(_context_menu)


## Right-click anywhere in the listing opens the clear-by-author menu — but
## ONLY when the host duck-types clear_annotations_by_author (contract §5:
## "other hosts without it get no menu entry"). Left-click and everything
## else falls through untouched (rows own their own left-click selection).
func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_RIGHT:
		return
	if _host == null or not _host.has_method("clear_annotations_by_author"):
		return
	_context_menu.position = get_screen_position() + mb.position
	_context_menu.popup()
	accept_event()


func _on_context_menu_id_pressed(id: int) -> void:
	if id < 0 or id >= _CLEAR_MENU_ITEMS.size():
		return
	clear_by_author(str(_CLEAR_MENU_ITEMS[id][1]))


func _on_show_consumed_toggled(pressed: bool) -> void:
	_show_consumed = pressed
	refresh()


## Test-friendly / programmatic entry point (mirrors get_listing()/entry_count()
## as the accessor tests call directly rather than simulating a right-click +
## popup selection). author_kind: "human" | "ai" | "all". No-op (returns 0)
## when the host doesn't support the host-side filter. Refreshes the listing
## on a real removal so the UI reflects the clear immediately.
func clear_by_author(author_kind: String) -> int:
	if _host == null or not _host.has_method("clear_annotations_by_author"):
		return 0
	var removed: int = int(_host.clear_annotations_by_author(author_kind))
	if removed > 0:
		refresh()
	return removed


## kind name (String) → Array of entry Dictionaries, in first-seen kind order.
## Side effect (documented on _consumed_seen): recounts consumed workflow
## annotations on every walk, whether or not they are listed.
func _grouped_entries() -> Dictionary:
	var groups := {}
	_consumed_seen = 0
	if _host == null or not _host.has_method("get_annotations"):
		return groups
	var registry: AnnotationRegistry = _host.get_registry() if _host.has_method("get_registry") else null
	if registry == null:
		return groups
	var index := 0
	for a in _host.get_annotations():
		if not a is Dictionary:
			continue
		index += 1
		var ann: Dictionary = a as Dictionary
		var kind_name := str(ann.get("kind", ""))
		var kind: AnnotationKind = registry.get_annotation_kind(StringName(kind_name))
		if kind == null or not kind.workflow_class:
			continue
		# Supersession (owner HITL 2026-07-17): an annotation that another
		# annotation now stands for — e.g. a route hint answered by a proposal
		# that carries the same geometry plus its rule-check verdict — must not
		# occupy its own review row: the reviewer would see the same route
		# twice, with the verdict on the far copy. Duck-typed and generic: a
		# host that doesn't implement the hook supersedes nothing. Supersession
		# is UI-only — the superseded annotation still exists (rejecting its
		# successor brings the row straight back) and MCP reads are unaffected.
		# Consumed-record filter (see _CONSUMED_LIFECYCLE doc): counted always
		# — the toggle label needs the number, and the count must include
		# superseded+consumed rows or those records would be invisible AND
		# uncounted (a delete in disguise) — listed only on opt-in. Sits
		# AFTER the index increment so #display indices are stable regardless
		# of the toggle state.
		var consumed := str(ann.get("lifecycle", "open")) == _CONSUMED_LIFECYCLE
		if consumed:
			_consumed_seen += 1
		if _host.has_method("is_annotation_superseded") and _host.is_annotation_superseded(ann):
			continue
		if consumed and not _show_consumed:
			continue
		if not groups.has(kind_name):
			groups[kind_name] = []
		var summary := str(ann.get("summary", "")).strip_edges()
		if summary.is_empty():
			summary = kind.summary(ann)
		(groups[kind_name] as Array).append({
			"kind": kind_name,
			"kind_display_name": kind.display_name,
			"id": str(ann.get("id", "")),
			"summary": summary,
			"lifecycle": str(ann.get("lifecycle", "open")),
			"display_index": index,
			"is_ai_authored": _is_ai_authored(ann),
			"drc_badge": _drc_badge_text(ann),
		})
	return groups


## DRC-at-propose (docket 019f6f1492e0) row badge. GENERIC extension — zero
## pcb vocabulary here on purpose, mirroring the C5 Accept/Reject precedent
## above (_ACCEPT_METHOD/_REJECT_METHOD doc): "drc" (design/rule-check) is
## cross-domain rule-check vocabulary, not a pcb-specific concept, and this
## reads it by plain duck-typed key lookup on kind_payload — the SAME
## substrate contract clear_by_author/accept/reject already opt annotation
## kinds into. Any plugin's workflow-class kind can carry a
## kind_payload.drc = {clean: bool|null, violations?: Array, error?: String}
## shape (pcb route-hint proposals are simply the first consumer, written by
## panel_tools.gd's _write_back_proposals) and this row will render it with
## no further wiring. Contract: clean == false -> "⚠ N" (N = violations
## count); clean == null -> "⚠ ?" (rule check unavailable — e.g. the DRC
## engine itself faulted, see pcb_worker.methods._attach_route_drc); no
## "drc" key at all (the pre-existing default for every non-pcb workflow kind,
## and for a pcb proposal from an older worker) -> "" (no badge, row renders
## exactly as it did before this round).
static func _drc_badge_text(annotation: Dictionary) -> String:
	var kp: Variant = annotation.get("kind_payload", null)
	if not (kp is Dictionary) or not (kp as Dictionary).has("drc"):
		return ""
	var drc: Variant = (kp as Dictionary).get("drc")
	if not (drc is Dictionary):
		return ""
	var clean: Variant = (drc as Dictionary).get("clean", null)
	if clean == null:
		return "⚠ ?"
	if bool(clean):
		return ""
	var raw_violations: Variant = (drc as Dictionary).get("violations", [])
	var violations: Array = raw_violations if raw_violations is Array else []
	return "⚠ %d" % violations.size()


## Generic "is this a machine proposal" signal — accepts both a v1 "human"/"ai"
## author string and a v2 {kind:...} author dict (same tolerance
## AnnotationRenderContext.author_color already documents for the identical
## reason: callers evolve independently of the schema round that introduced
## the dict form).
static func _is_ai_authored(annotation: Dictionary) -> bool:
	var author: Variant = annotation.get("author", null)
	if author is String:
		return author == "ai"
	if author is Dictionary:
		return str((author as Dictionary).get("kind", "")) == "ai"
	return false


func _make_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.tooltip_text = str(entry.get("summary", ""))
	if _selected_ids.has(str(entry.get("id", ""))):
		var style := StyleBoxFlat.new()
		style.bg_color = _SELECTED_ROW_COLOR
		row.add_theme_stylebox_override("panel", style)

	var select := Button.new()
	select.text = "#%d" % int(entry.get("display_index", 0))
	select.focus_mode = Control.FOCUS_NONE
	select.custom_minimum_size = Vector2(44, 24)
	select.pressed.connect(_select_annotation.bind(str(entry.get("id", ""))))
	row.add_child(select)

	# DRC-at-propose badge (see _drc_badge_text doc) — before the summary label
	# so it reads immediately after the #index, and is skipped entirely (no
	# child added) when the annotation carries no "drc" key at all.
	var badge_text := str(entry.get("drc_badge", ""))
	if not badge_text.is_empty():
		var badge := Label.new()
		badge.name = "DrcBadge"
		badge.text = badge_text
		badge.tooltip_text = "rule check unavailable" if badge_text == "⚠ ?" else "DRC violations on this route"
		badge.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2))
		row.add_child(badge)

	var label := Label.new()
	label.text = str(entry.get("summary", ""))
	# Zero minimum width (clip + ellipsis) so the row shrinks to the dock and
	# the Accept/Reject buttons stay pinned at the right edge.
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	# Per-annotation Accept/Reject — see the class-doc note above
	# _ACCEPT_METHOD/_REJECT_METHOD for why this is here instead of an
	# extended context menu.
	if bool(entry.get("is_ai_authored", false)) and _host != null \
			and _host.has_method(_ACCEPT_METHOD) and _host.has_method(_REJECT_METHOD):
		var entry_id := str(entry.get("id", ""))

		var accept_btn := Button.new()
		accept_btn.name = "AcceptButton"
		accept_btn.text = "Accept"
		accept_btn.focus_mode = Control.FOCUS_NONE
		accept_btn.pressed.connect(_on_accept_pressed.bind(entry_id))
		row.add_child(accept_btn)

		var reject_btn := Button.new()
		reject_btn.name = "RejectButton"
		reject_btn.text = "Reject"
		reject_btn.focus_mode = Control.FOCUS_NONE
		reject_btn.pressed.connect(_on_reject_pressed.bind(entry_id))
		row.add_child(reject_btn)

	return row


## Calls the host's generic accept verb (duck-typed — see _ACCEPT_METHOD doc)
## and refreshes. Coroutine: the pcb host's accept_annotation_proposal awaits
## panel_tools.gd's tool dispatch; connecting a Button.pressed signal directly
## to an async func is fine in Godot (fire-and-forget from the signal's
## perspective — refresh() still runs once the await resolves).
func _on_accept_pressed(annotation_id: String) -> void:
	if _host == null or not _host.has_method(_ACCEPT_METHOD):
		return
	await _host.call(_ACCEPT_METHOD, annotation_id)
	refresh()


func _on_reject_pressed(annotation_id: String) -> void:
	if _host == null or not _host.has_method(_REJECT_METHOD):
		return
	await _host.call(_REJECT_METHOD, annotation_id)
	refresh()


func _select_annotation(annotation_id: String) -> void:
	# A list click REPLACES the selection. Route through the multi API when the
	# host has it: the single-id setter is a no-op when the clicked row is
	# already primary, which would leave a canvas multi-selection standing.
	if _host != null and _host.has_method("set_selected_annotation_ids"):
		_host.set_selected_annotation_ids(PackedStringArray([annotation_id]), annotation_id)
	elif _host != null and _host.has_method("set_selected_annotation_id"):
		_host.set_selected_annotation_id(annotation_id)
	annotation_selected.emit(annotation_id)


func _on_selection_changed(annotation_id: String) -> void:
	_selected_id = annotation_id
	_selected_ids = _read_selected_ids()
	refresh()


func _on_selection_set_changed(annotation_ids: PackedStringArray) -> void:
	_selected_ids = annotation_ids.duplicate()
	refresh()


## Every selected id. See AnnotationHost.selected_ids_for for the single-id
## fallback shared with the overlay and the author tools.
func _read_selected_ids() -> PackedStringArray:
	return AnnotationHost.selected_ids_for(_host)
