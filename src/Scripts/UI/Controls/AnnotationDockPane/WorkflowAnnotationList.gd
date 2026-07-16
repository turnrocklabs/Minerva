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

var _host: RefCounted = null
var _selected_id: String = ""

var _header: Label
var _groups_list: VBoxContainer
var _context_menu: PopupMenu = null


func _ready() -> void:
	_build_ui()
	refresh()


func set_host(host: RefCounted) -> void:
	if _host != null and _host.has_signal("annotations_changed") and _host.is_connected("annotations_changed", Callable(self, "refresh")):
		_host.disconnect("annotations_changed", Callable(self, "refresh"))
	if _host != null and _host.has_signal("selection_changed") and _host.is_connected("selection_changed", Callable(self, "_on_selection_changed")):
		_host.disconnect("selection_changed", Callable(self, "_on_selection_changed"))
	_host = host
	_selected_id = ""
	if _host != null and _host.has_signal("annotations_changed") and not _host.is_connected("annotations_changed", Callable(self, "refresh")):
		_host.connect("annotations_changed", Callable(self, "refresh"))
	if _host != null and _host.has_signal("selection_changed") and not _host.is_connected("selection_changed", Callable(self, "_on_selection_changed")):
		_host.connect("selection_changed", Callable(self, "_on_selection_changed"))
	if _host != null and _host.has_method("get_selected_annotation_id"):
		_selected_id = _host.get_selected_annotation_id()
	refresh()


## Data view of the current listing — one flat entry per workflow annotation,
## kind-grouped ordering (group order = first-seen kind order, entries keep
## host order within a group). Tests and MCP-ergonomic callers read this
## instead of scraping child controls.
## Entry shape: {kind: String, kind_display_name: String, id: String,
##               summary: String, lifecycle: String}.
func get_listing() -> Array:
	var groups := _grouped_entries()
	var flat: Array = []
	for kind_name in groups.keys():
		for entry in (groups[kind_name] as Array):
			flat.append(entry)
	return flat


func entry_count() -> int:
	return get_listing().size()


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

	# Zero workflow annotations → the whole surface disappears (no header
	# squatting in the dock for hosts that never use workflow kinds).
	if _header != null:
		_header.visible = total > 0
	_groups_list.visible = total > 0


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

	_groups_list = VBoxContainer.new()
	_groups_list.name = "WorkflowGroups"
	_groups_list.add_theme_constant_override("separation", 4)
	_groups_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_groups_list.visible = false
	add_child(_groups_list)

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
func _grouped_entries() -> Dictionary:
	var groups := {}
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
		})
	return groups


func _make_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.tooltip_text = str(entry.get("summary", ""))
	if str(entry.get("id", "")) == _selected_id and not _selected_id.is_empty():
		var style := StyleBoxFlat.new()
		style.bg_color = _SELECTED_ROW_COLOR
		row.add_theme_stylebox_override("panel", style)

	var select := Button.new()
	select.text = "#%d" % int(entry.get("display_index", 0))
	select.focus_mode = Control.FOCUS_NONE
	select.custom_minimum_size = Vector2(44, 24)
	select.pressed.connect(_select_annotation.bind(str(entry.get("id", ""))))
	row.add_child(select)

	var label := Label.new()
	label.text = str(entry.get("summary", ""))
	label.clip_text = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	return row


func _select_annotation(annotation_id: String) -> void:
	if _host != null and _host.has_method("set_selected_annotation_id"):
		_host.set_selected_annotation_id(annotation_id)
	annotation_selected.emit(annotation_id)


func _on_selection_changed(annotation_id: String) -> void:
	_selected_id = annotation_id
	refresh()
