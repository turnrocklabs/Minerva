class_name ChatGroupDock
extends VBoxContainer
## Group dock across the top of the chats pane (DCR 01a017494904, Option C).
##
## Collapsed it is 24px — a header and a chevron. Expanded it is 68px: header,
## then one horizontally scrollable row of group cards. The row STOPS at both
## ends (no wrap-around) and is scrolled with the arrow buttons; edge fades show
## which direction still has cards, which arrows alone do not convey.
##
## The dock is a pure view: it renders from ChatPane + ChatGroupRegistry and
## calls back into ChatPane for every mutation, so MCP-driven group changes show
## up here for free.

signal group_selected(group_id: String)
signal group_rename_requested(group_id: String)
signal chat_dropped_on_group(group_id: String, chat_id: String)
signal create_group_requested(chat_id: String)
signal card_context_menu_requested(group_id: String, kind: int)

const CardScript = preload("res://Scripts/UI/Controls/ChatGroupDock/ChatGroupCard.gd")

# Stroked chevrons, not glyphs. "^" and "v" were literally the text characters —
# one of them IS a rotated letter, it sits on the text baseline rather than
# centred in its box, and the pair is not symmetric. These reuse the geometry of
# the project's own arrow_*.svg (round caps, 2px stroke) but at full opacity, so
# the colour is set here instead of baked into the asset.
const ICON_CHEVRON_DOWN := preload("res://assets/icons/chevron_down.svg")
const ICON_CHEVRON_LEFT := preload("res://assets/icons/chevron_left.svg")
const ICON_CHEVRON_RIGHT := preload("res://assets/icons/chevron_right.svg")

const ICON_COLOR := Color("#dcdcdc")

const COLLAPSED_HEIGHT := 24
const EXPANDED_HEIGHT := 68
const HEADER_HEIGHT := 24
const ROW_PAD := 6
const FADE_WIDTH := 26
const ARROW_WIDTH := 18
const SCROLL_STEP := 160.0
const ADD_CARD_ID := "__add__"

var _collapsed := false
var _header: HBoxContainer = null
var _chevron: Button = null
var _title: Label = null
var _summary: Label = null
var _body: HBoxContainer = null
var _viewport_wrap: Control = null
var _scroll: ScrollContainer = null
var _row: HBoxContainer = null
var _fade_left: TextureRect = null
var _fade_right: TextureRect = null
var _btn_left: Button = null
var _btn_right: Button = null
var _scroll_tween: Tween = null

## Snapshot the dock renders from, supplied by ChatPane.
var _cards: Array[Dictionary] = []
var _active_group_id: String = ChatGroupRegistry.VIEW_ALL


func _ready() -> void:
	_build()
	_apply_layout_state()


func _build() -> void:
	if _header != null:
		return
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	_header = HBoxContainer.new()
	_header.custom_minimum_size = Vector2(0, HEADER_HEIGHT)
	_header.add_theme_constant_override("separation", 6)
	add_child(_header)

	_chevron = Button.new()
	_chevron.name = "DockChevron"
	_chevron.flat = true
	_chevron.expand_icon = false
	_tint_icon(_chevron)
	_chevron.custom_minimum_size = Vector2(20, 0)
	_chevron.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_chevron.focus_mode = Control.FOCUS_NONE
	_strip_button_padding(_chevron)
	_chevron.pressed.connect(toggle_collapsed)
	_header.add_child(_chevron)

	_title = Label.new()
	_title.text = "Groups"
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_child(_title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_child(spacer)

	_summary = Label.new()
	_summary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_summary.add_theme_color_override("font_color", Color("#8fb2bc"))
	_header.add_child(_summary)

	_body = HBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	_body.custom_minimum_size = Vector2(0, EXPANDED_HEIGHT - HEADER_HEIGHT)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_body)

	_btn_left = _make_arrow(ICON_CHEVRON_LEFT, -1)
	_body.add_child(_btn_left)

	# The scroll row and its fades share one clipped wrapper: the fades must sit
	# ON TOP of the cards, which means overlaying rather than flowing.
	_viewport_wrap = Control.new()
	_viewport_wrap.clip_contents = true
	_viewport_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_wrap.mouse_filter = Control.MOUSE_FILTER_PASS
	_body.add_child(_viewport_wrap)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport_wrap.add_child(_scroll)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 6)
	_row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scroll.add_child(_row)

	_fade_left = _make_fade(true)
	_viewport_wrap.add_child(_fade_left)
	_fade_right = _make_fade(false)
	_viewport_wrap.add_child(_fade_right)

	_btn_right = _make_arrow(ICON_CHEVRON_RIGHT, 1)
	_body.add_child(_btn_right)

	if _scroll.get_h_scroll_bar():
		_scroll.get_h_scroll_bar().value_changed.connect(func(_v): _update_edge_affordances())
	_viewport_wrap.resized.connect(_update_edge_affordances)


func _make_arrow(glyph: Texture2D, direction: int) -> Button:
	var b := Button.new()
	b.icon = glyph
	b.expand_icon = false
	_tint_icon(b)
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(ARROW_WIDTH, ChatGroupCard.CARD_HEIGHT)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_strip_button_padding(b)
	b.pressed.connect(_scroll_by.bind(direction))
	return b


## Remove a Button's stylebox padding so it stops driving its row's minimum
## height. The theme's button styleboxes carry content margins of their own, and
## a single Button in the header pushed the dock from its 24px header (68px
## overall) to 31px (79px) — a fifth taller than spec, in the pane where
## vertical space is the whole design constraint.
## Colour the icon here rather than in the asset: the project's existing
## arrow_*.svg bake a 45%-opacity stroke, and modulation multiplies, so a
## half-transparent asset can never be made solid at the use site.
func _tint_icon(b: Button) -> void:
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		b.add_theme_color_override(state, ICON_COLOR)
	b.add_theme_color_override("icon_disabled_color", Color(ICON_COLOR.r, ICON_COLOR.g, ICON_COLOR.b, 0.25))


func _strip_button_padding(b: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(state, StyleBoxEmpty.new())


func _make_fade(from_left: bool) -> TextureRect:
	var grad := Gradient.new()
	var solid := Color("#252b34")
	var clear := Color(solid.r, solid.g, solid.b, 0.0)
	grad.set_color(0, solid if from_left else clear)
	grad.set_color(1, clear if from_left else solid)

	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = FADE_WIDTH
	tex.height = 1
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(1, 0)

	var tr := TextureRect.new()
	tr.texture = tex
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if from_left:
		tr.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	else:
		tr.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	tr.custom_minimum_size = Vector2(FADE_WIDTH, 0)
	tr.size = Vector2(FADE_WIDTH, tr.size.y)
	if not from_left:
		tr.offset_left = -FADE_WIDTH
	else:
		tr.offset_right = FADE_WIDTH
	tr.modulate.a = 0.0
	return tr


#region Collapse

func is_collapsed() -> bool:
	return _collapsed


## Test/inspection hook: the header's disclosure button.
func get_chevron() -> Button:
	return _chevron


func toggle_collapsed() -> void:
	set_collapsed(not _collapsed)


func set_collapsed(collapsed: bool) -> void:
	if _collapsed == collapsed:
		return
	_collapsed = collapsed
	_apply_layout_state()


func _apply_layout_state() -> void:
	if _body != null:
		_body.visible = not _collapsed
	if _chevron != null:
		# Disclosure convention, by where the VERTEX aims: collapsed points RIGHT,
		# at the content that will open; expanded points DOWN, at the content now
		# open beneath it. Down/up would be a toggle-arrow — it describes which
		# way the control moves, not where the content is.
		_chevron.icon = ICON_CHEVRON_RIGHT if _collapsed else ICON_CHEVRON_DOWN
		_chevron.tooltip_text = "Show chat groups" if _collapsed else "Hide chat groups"
	custom_minimum_size = Vector2(0, COLLAPSED_HEIGHT if _collapsed else EXPANDED_HEIGHT)
	if not _collapsed:
		call_deferred("_update_edge_affordances")

#endregion Collapse


#region Rendering

## Render from a snapshot. Each entry: {kind, id, name, color, count}.
func render_cards(cards: Array[Dictionary], active_group_id: String) -> void:
	_build()
	_cards = cards
	_active_group_id = active_group_id

	for child in _row.get_children():
		_row.remove_child(child)
		child.queue_free()

	for entry in cards:
		var card: ChatGroupCard = CardScript.new()
		_row.add_child(card)
		card.configure(
			int(entry.get("kind", ChatGroupCard.Kind.GROUP)),
			str(entry.get("id", "")),
			str(entry.get("name", "")),
			entry.get("color", ChatGroupRegistry.NEUTRAL_COLOR),
			int(entry.get("count", 0)),
			str(entry.get("id", "")) == active_group_id
		)
		card.selected.connect(_on_card_selected)
		card.rename_requested.connect(func(gid): group_rename_requested.emit(gid))
		card.chat_dropped.connect(_on_card_chat_dropped)
		card.context_menu_requested.connect(func(gid, k): card_context_menu_requested.emit(gid, k))

	var group_total := 0
	for entry in cards:
		if int(entry.get("kind", -1)) == ChatGroupCard.Kind.GROUP:
			group_total += 1
	_summary.text = "%d" % group_total if group_total > 0 else ""

	call_deferred("_update_edge_affordances")


func _on_card_selected(group_id: String) -> void:
	if group_id == ADD_CARD_ID:
		create_group_requested.emit("")
		return
	group_selected.emit(group_id)


func _on_card_chat_dropped(group_id: String, chat_id: String) -> void:
	if group_id == ADD_CARD_ID:
		create_group_requested.emit(chat_id)
		return
	chat_dropped_on_group.emit(group_id, chat_id)

#endregion Rendering


#region Scrolling

func _scroll_by(direction: int) -> void:
	if _scroll == null:
		return
	var target := clampf(
		float(_scroll.scroll_horizontal) + SCROLL_STEP * float(direction),
		0.0,
		_max_scroll()
	)
	if _scroll_tween != null and _scroll_tween.is_valid():
		_scroll_tween.kill()
	_scroll_tween = create_tween()
	_scroll_tween.tween_property(_scroll, "scroll_horizontal", int(target), 0.12)
	_scroll_tween.finished.connect(_update_edge_affordances)


func _max_scroll() -> float:
	if _scroll == null:
		return 0.0
	var bar := _scroll.get_h_scroll_bar()
	if bar == null:
		return 0.0
	# The scrollable span is the content width minus the visible page; Godot
	# clamps scroll_horizontal to this itself, so the row simply STOPS at both
	# ends. That is the no-wrap-around behaviour the owner asked for.
	return maxf(0.0, bar.max_value - bar.page)


## Show an arrow/fade on a side only while cards remain past that edge.
func _update_edge_affordances() -> void:
	if _scroll == null or _btn_left == null:
		return
	var maxs := _max_scroll()
	var pos := float(_scroll.scroll_horizontal)
	var can_left := pos > 1.0
	var can_right := pos < maxs - 1.0
	_btn_left.disabled = not can_left
	_btn_right.disabled = not can_right
	_btn_left.modulate.a = 1.0 if can_left else 0.25
	_btn_right.modulate.a = 1.0 if can_right else 0.25
	if _fade_left:
		_fade_left.modulate.a = 1.0 if can_left else 0.0
	if _fade_right:
		_fade_right.modulate.a = 1.0 if can_right else 0.0


## Test/inspection hook: which edges currently advertise more cards.
func get_edge_state() -> Dictionary:
	var maxs := _max_scroll()
	var pos := float(_scroll.scroll_horizontal) if _scroll else 0.0
	return {"can_scroll_left": pos > 1.0, "can_scroll_right": pos < maxs - 1.0, "max_scroll": maxs}

#endregion Scrolling
