class_name FocusedChatPopup
extends PersistentWindow
## Popup for creating a Focused Chat — a chat with a fixed, pre-selected tool set.
## Dual-list "transfer" UI: available skills on left, selected skills on right,
## add/remove buttons in between. Tool preview below.

signal focused_chat_requested(config: Dictionary)

# Skill data: id → {title, description, tool_deps, project}
var _skills: Dictionary = {}
# All available tool names (excluding discovery tools)
var _all_tool_names: Array[String] = []
# tool_name → description (used for search)
var _tool_descriptions: Dictionary = {}
# Extra tools added manually (not from skills)
var _extra_tools: Dictionary = {}  # tool_name → bool
# Tools contributed by selected skills
var _skill_tools: Dictionary = {}  # tool_name → Array[skill_id]
# Selected skill IDs (ordered)
var _selected_skill_ids: Array[String] = []

# UI refs — skill lists
var _available_search: LineEdit
var _available_list: ItemList
var _selected_list: ItemList
var _add_btn: Button
var _remove_btn: Button
# UI refs — tool list
var _tool_search: LineEdit
var _tool_list: VBoxContainer
# UI refs — bottom
var _summary_label: Label
var _create_btn: Button


func _ready() -> void:
	super._ready()
	title = "Create Focused Chat"
	size = Vector2i(960, 680)
	min_size = Vector2i(800, 550)
	_build_ui()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	# Use a VSplitContainer so user can resize between skills and tools sections
	var vsplit := VSplitContainer.new()
	vsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(vsplit)

	# ---- Top: skill transfer panel ----
	var skill_panel := VBoxContainer.new()
	skill_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	skill_panel.custom_minimum_size.y = 200
	vsplit.add_child(skill_panel)

	var skill_header := Label.new()
	skill_header.text = "Skills"
	skill_header.add_theme_font_size_override("font_size", 15)
	skill_panel.add_child(skill_header)

	var transfer := HBoxContainer.new()
	transfer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	transfer.add_theme_constant_override("separation", 6)
	skill_panel.add_child(transfer)

	# Left: available skills
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.size_flags_stretch_ratio = 1.0
	left_col.custom_minimum_size.x = 250
	transfer.add_child(left_col)

	var avail_label := Label.new()
	avail_label.text = "Available"
	avail_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	left_col.add_child(avail_label)

	_available_search = LineEdit.new()
	_available_search.placeholder_text = "Filter..."
	_available_search.text_changed.connect(_on_available_search_changed)
	left_col.add_child(_available_search)

	_available_list = ItemList.new()
	_available_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_available_list.select_mode = ItemList.SELECT_MULTI
	_available_list.item_activated.connect(_on_available_item_activated)
	left_col.add_child(_available_list)

	# Center: add/remove buttons
	var btn_col := VBoxContainer.new()
	btn_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn_col.add_theme_constant_override("separation", 4)
	transfer.add_child(btn_col)

	_add_btn = Button.new()
	_add_btn.text = ">>"
	_add_btn.tooltip_text = "Add selected skills"
	_add_btn.custom_minimum_size.x = 40
	_add_btn.pressed.connect(_on_add_pressed)
	btn_col.add_child(_add_btn)

	_remove_btn = Button.new()
	_remove_btn.text = "<<"
	_remove_btn.tooltip_text = "Remove selected skills"
	_remove_btn.custom_minimum_size.x = 40
	_remove_btn.pressed.connect(_on_remove_pressed)
	btn_col.add_child(_remove_btn)

	# Right: selected skills
	var right_col := VBoxContainer.new()
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_col.size_flags_stretch_ratio = 1.0
	right_col.custom_minimum_size.x = 250
	transfer.add_child(right_col)

	var sel_label := Label.new()
	sel_label.text = "Selected"
	sel_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	right_col.add_child(sel_label)

	_selected_list = ItemList.new()
	_selected_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_selected_list.select_mode = ItemList.SELECT_MULTI
	_selected_list.item_activated.connect(_on_selected_item_activated)
	right_col.add_child(_selected_list)

	# ---- Bottom: tool preview + action bar ----
	var bottom_panel := VBoxContainer.new()
	bottom_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_panel.custom_minimum_size.y = 150
	vsplit.add_child(bottom_panel)

	var tool_header := Label.new()
	tool_header.text = "Resulting Tools"
	tool_header.add_theme_font_size_override("font_size", 15)
	bottom_panel.add_child(tool_header)

	_tool_search = LineEdit.new()
	_tool_search.placeholder_text = "Search tools to add individually..."
	_tool_search.text_changed.connect(_on_tool_search_changed)
	bottom_panel.add_child(_tool_search)

	var tool_scroll := ScrollContainer.new()
	tool_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_panel.add_child(tool_scroll)

	_tool_list = VBoxContainer.new()
	_tool_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tool_scroll.add_child(_tool_list)

	# Action bar
	var action_bar := HBoxContainer.new()
	action_bar.add_theme_constant_override("separation", 8)
	bottom_panel.add_child(action_bar)

	_summary_label = Label.new()
	_summary_label.text = "0 skills, 0 tools selected"
	_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_bar.add_child(_summary_label)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(hide)
	action_bar.add_child(cancel_btn)

	_create_btn = Button.new()
	_create_btn.text = "Create"
	_create_btn.disabled = true
	_create_btn.pressed.connect(_on_create_pressed)
	action_bar.add_child(_create_btn)

	# Initial split favors the tool chooser — skill transfer needs less room than
	# the scrollable tool list + search box.
	vsplit.split_offset = 200


## Reload skills and tools from docket/MCP. Call before showing.
func refresh() -> void:
	_skills.clear()
	_all_tool_names.clear()
	_tool_descriptions.clear()
	_extra_tools.clear()
	_skill_tools.clear()
	_selected_skill_ids.clear()
	_load_skills()
	_load_tools()
	_render_available_list("")
	_render_selected_list()
	_render_tool_list("")
	_update_summary()


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

func _load_skills() -> void:
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		print("[FocusedChatPopup] DocketManager not available")
		return

	var projects := dm.get_loaded_projects()

	for proj_name in projects:
		# Get skill catalog (IDs + titles)
		var list_result := dm.call_tool("docket_skill_list", {"project": proj_name})
		if list_result.has("error"):
			continue
		var skills_arr: Array = list_result.get("skills", [])

		# Fetch each skill individually to get tool_deps (not in list response)
		for skill_entry in skills_arr:
			var id: String = str(skill_entry.get("id", ""))
			if id.is_empty() or _skills.has(id):
				continue
			var full := dm.call_tool("docket_skill_get", {"id": id, "project": proj_name})
			if full.has("error"):
				# Still add with no tool_deps — skill is browsable
				_skills[id] = {
					"title": str(skill_entry.get("title", "")),
					"description": str(skill_entry.get("description", "")),
					"tool_deps": [] as Array[String],
					"project": proj_name,
				}
				continue
			_add_skill_from_item(full, proj_name)


func _add_skill_from_item(item: Dictionary, proj_name: String) -> void:
	var id: String = str(item.get("id", ""))
	if id.is_empty() or _skills.has(id):
		return
	var tool_deps_raw = item.get("tool_deps", [])
	var deps_str: Array[String] = []
	if tool_deps_raw is Array:
		for dep in tool_deps_raw:
			deps_str.append(str(dep))
	elif tool_deps_raw is String and not tool_deps_raw.is_empty():
		# Might be JSON string
		var parsed = JSON.parse_string(tool_deps_raw)
		if parsed is Array:
			for dep in parsed:
				deps_str.append(str(dep))
	_skills[id] = {
		"title": str(item.get("title", "")),
		"description": str(item.get("description", "")),
		"tool_deps": deps_str,
		"project": proj_name,
	}


func _load_tools() -> void:
	var mcp = SingletonObject.get_mcp_manager()
	if not mcp:
		return
	var discovery_tools := ["minerva_tool_search", "minerva_list_skills", "minerva_get_skill"]
	for tool_def in mcp.get_available_tools():
		var tool_name: String = str(tool_def.name)
		if tool_name.is_empty() or tool_name in discovery_tools:
			continue
		_all_tool_names.append(tool_name)
		_tool_descriptions[tool_name] = str(tool_def.description) if "description" in tool_def else ""
		_extra_tools[tool_name] = false
	_all_tool_names.sort()


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _render_available_list(filter: String) -> void:
	_available_list.clear()
	var filter_lower := filter.to_lower()

	var sorted_ids: Array = _skills.keys()
	sorted_ids.sort_custom(func(a, b): return str(_skills[a]["title"]).to_lower() < str(_skills[b]["title"]).to_lower())

	for id in sorted_ids:
		# Skip already-selected skills
		if id in _selected_skill_ids:
			continue
		var skill: Dictionary = _skills[id]
		var skill_title: String = skill["title"]
		var desc: String = skill["description"]
		if not filter_lower.is_empty():
			if not skill_title.to_lower().contains(filter_lower) and not desc.to_lower().contains(filter_lower):
				continue
		var deps_count: int = skill["tool_deps"].size()
		var display: String = "%s  (%d tools)" % [skill_title, deps_count] if deps_count > 0 else skill_title
		var idx := _available_list.add_item(display)
		_available_list.set_item_metadata(idx, id)
		if not desc.is_empty():
			_available_list.set_item_tooltip(idx, desc)


func _render_selected_list() -> void:
	_selected_list.clear()
	for id in _selected_skill_ids:
		if not _skills.has(id):
			continue
		var skill: Dictionary = _skills[id]
		var deps_count: int = skill["tool_deps"].size()
		var display: String = "%s  (%d tools)" % [skill["title"], deps_count] if deps_count > 0 else skill["title"]
		var idx := _selected_list.add_item(display)
		_selected_list.set_item_metadata(idx, id)


func _render_tool_list(filter: String) -> void:
	for child in _tool_list.get_children():
		child.queue_free()

	var filter_lower := filter.to_lower()
	# Stem the filter for loose plural/singular matching (notes ↔ note).
	var filter_stem := filter_lower
	if filter_stem.length() > 3 and filter_stem.ends_with("s"):
		filter_stem = filter_stem.substr(0, filter_stem.length() - 1)

	for tool_name in _all_tool_names:
		if not filter_lower.is_empty():
			var name_lower := tool_name.to_lower()
			var desc_lower := str(_tool_descriptions.get(tool_name, "")).to_lower()
			var matches := name_lower.contains(filter_lower) \
				or desc_lower.contains(filter_lower) \
				or name_lower.contains(filter_stem) \
				or desc_lower.contains(filter_stem)
			if not matches:
				continue

		var from_skill := _skill_tools.has(tool_name)
		var manually_added: bool = _extra_tools.get(tool_name, false)

		# Only show if contributed by skill, manually added, or user is searching
		if not from_skill and not manually_added and filter_lower.is_empty():
			continue

		var check := CheckButton.new()
		check.button_pressed = from_skill or manually_added
		if from_skill:
			check.text = "%s  (from skill)" % tool_name
		else:
			check.text = tool_name
		check.toggled.connect(_on_tool_toggled.bind(tool_name))
		_tool_list.add_child(check)

	if _tool_list.get_child_count() == 0:
		var hint := Label.new()
		if filter_lower.is_empty():
			hint.text = "Select skills above, or type in the search box to add individual tools"
		else:
			hint.text = "(No matching tools)"
		hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_tool_list.add_child(hint)


# ---------------------------------------------------------------------------
# Skill transfer interaction
# ---------------------------------------------------------------------------

## Double-click on available -> add
func _on_available_item_activated(index: int) -> void:
	var id = _available_list.get_item_metadata(index)
	if id is String and not id.is_empty():
		_add_skill_to_selected(id)

## Double-click on selected -> remove
func _on_selected_item_activated(index: int) -> void:
	var id = _selected_list.get_item_metadata(index)
	if id is String and not id.is_empty():
		_remove_skill_from_selected(id)

## >> button
func _on_add_pressed() -> void:
	var indices := _available_list.get_selected_items()
	var ids_to_add: Array[String] = []
	for idx in indices:
		var id = _available_list.get_item_metadata(idx)
		if id is String and not id.is_empty():
			ids_to_add.append(id)
	for id in ids_to_add:
		_add_skill_to_selected(id)

## << button
func _on_remove_pressed() -> void:
	var indices := _selected_list.get_selected_items()
	var ids_to_remove: Array[String] = []
	for idx in indices:
		var id = _selected_list.get_item_metadata(idx)
		if id is String and not id.is_empty():
			ids_to_remove.append(id)
	for id in ids_to_remove:
		_remove_skill_from_selected(id)


func _add_skill_to_selected(id: String) -> void:
	if id in _selected_skill_ids:
		return
	_selected_skill_ids.append(id)
	_recompute_skill_tools()
	_render_available_list(_available_search.text)
	_render_selected_list()
	_render_tool_list(_tool_search.text)
	_update_summary()


func _remove_skill_from_selected(id: String) -> void:
	_selected_skill_ids.erase(id)
	_recompute_skill_tools()
	_render_available_list(_available_search.text)
	_render_selected_list()
	_render_tool_list(_tool_search.text)
	_update_summary()


# ---------------------------------------------------------------------------
# Tool interaction
# ---------------------------------------------------------------------------

func _on_tool_toggled(toggled: bool, tool_name: String) -> void:
	_extra_tools[tool_name] = toggled
	_update_summary()


func _on_available_search_changed(text: String) -> void:
	_render_available_list(text)


func _on_tool_search_changed(text: String) -> void:
	_render_tool_list(text)


# ---------------------------------------------------------------------------
# State computation
# ---------------------------------------------------------------------------

func _recompute_skill_tools() -> void:
	_skill_tools.clear()
	for id in _selected_skill_ids:
		if not _skills.has(id):
			continue
		var skill: Dictionary = _skills[id]
		for dep in skill["tool_deps"]:
			var dep_str: String = str(dep)
			if not _skill_tools.has(dep_str):
				_skill_tools[dep_str] = []
			_skill_tools[dep_str].append(id)


func _get_selected_skill_names() -> Array[String]:
	var names: Array[String] = []
	for id in _selected_skill_ids:
		if _skills.has(id):
			names.append(_skills[id]["title"])
	return names


func _get_resolved_tools() -> Array[String]:
	var tools: Array[String] = []
	for tool_name in _skill_tools:
		if tool_name not in tools:
			tools.append(tool_name)
	for tool_name in _extra_tools:
		if _extra_tools[tool_name] and tool_name not in tools:
			tools.append(tool_name)
	return tools


func _update_summary() -> void:
	var skill_count := _selected_skill_ids.size()
	var tool_count := _get_resolved_tools().size()
	_summary_label.text = "%d skill%s, %d tool%s selected" % [
		skill_count, "" if skill_count == 1 else "s",
		tool_count, "" if tool_count == 1 else "s",
	]
	_create_btn.disabled = tool_count == 0


func _on_create_pressed() -> void:
	var selected_skills := _get_selected_skill_names()
	var resolved_tools := _get_resolved_tools()

	# Resolve skill instructions via MCPSkillTools
	var instructions := ""
	if not selected_skills.is_empty():
		var mcp = SingletonObject.get_mcp_manager()
		if mcp and mcp.minerva_server:
			for module in mcp.minerva_server._modules:
				if module is MCPSkillTools:
					var resolved: Dictionary = module.resolve_skills(selected_skills)
					instructions = resolved.get("instructions", "")
					break

	focused_chat_requested.emit({
		"skills": selected_skills,
		"resolved_tools": resolved_tools,
		"instructions": instructions,
	})
	hide()
