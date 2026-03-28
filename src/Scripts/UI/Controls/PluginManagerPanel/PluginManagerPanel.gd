class_name PluginManagerPanel
extends PanelContainer
## Plugin Manager UI panel.
##
## Displays all installed plugins in a list on the left side.
## Selecting a plugin shows its details on the right: status, start/stop/restart
## controls, capability grants, audit log, and tool list.
##
## Follows the PCBEditor pattern: all UI is built in _build_ui(), no complex .tscn tree.


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Currently selected plugin id, or empty if none.
var _selected_plugin_id: String = ""

## File dialog for installing plugins.
var _install_dialog: FileDialog = null

## Confirmation dialog for removing plugins.
var _remove_confirm: ConfirmationDialog = null

## Pending plugin id for removal confirmation.
var _pending_remove_id: String = ""

## Checkbox to delete plugin data directory on removal.
var _remove_delete_data_check: CheckButton = null


# ---------------------------------------------------------------------------
# UI References — left pane
# ---------------------------------------------------------------------------

var _plugin_list: ItemList = null
var _refresh_button: Button = null


# ---------------------------------------------------------------------------
# UI References — right pane: header
# ---------------------------------------------------------------------------

var _detail_placeholder: Label = null
var _detail_panel: VBoxContainer = null

var _detail_name_label: Label = null
var _detail_version_label: Label = null
var _detail_id_label: Label = null
var _detail_status_label: Label = null
var _detail_uptime_label: Label = null

var _start_button: Button = null
var _stop_button: Button = null
var _restart_button: Button = null
var _reload_button: Button = null
var _autostart_check: CheckButton = null
var _auto_reload_check: CheckButton = null
var _files_changed_label: Label = null
var _remove_button: Button = null


# ---------------------------------------------------------------------------
# UI References — right pane: capabilities
# ---------------------------------------------------------------------------

var _caps_container: VBoxContainer = null


# ---------------------------------------------------------------------------
# UI References — right pane: audit log
# ---------------------------------------------------------------------------

var _audit_container: VBoxContainer = null
var _audit_scroll: ScrollContainer = null
var _audit_list: VBoxContainer = null


# ---------------------------------------------------------------------------
# UI References — right pane: tools
# ---------------------------------------------------------------------------

var _tools_container: VBoxContainer = null
var _tools_list: VBoxContainer = null


# ---------------------------------------------------------------------------
# UI References — bottom toolbar
# ---------------------------------------------------------------------------

var _install_button: Button = null
var _status_label: Label = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_build_ui()
	_connect_signals()
	_refresh_plugin_list()


func _exit_tree() -> void:
	_disconnect_signals()


# ---------------------------------------------------------------------------
# UI Construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true

	var main_vbox := VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.clip_contents = true
	add_child(main_vbox)

	# ── Content area (left list + right detail) ──
	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 220
	main_vbox.add_child(split)

	# Left pane
	var left_vbox := _build_left_pane()
	split.add_child(left_vbox)

	# Right pane
	var right_panel := _build_right_pane()
	split.add_child(right_panel)

	# ── Bottom toolbar ──
	main_vbox.add_child(HSeparator.new())
	var bottom_hbox := _build_bottom_toolbar()
	main_vbox.add_child(bottom_hbox)


func _build_left_pane() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size.x = 200
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var header_row := HBoxContainer.new()
	vbox.add_child(header_row)

	var header_label := Label.new()
	header_label.text = "Plugins"
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(header_label)

	_refresh_button = Button.new()
	_refresh_button.text = "Refresh"
	_refresh_button.flat = true
	_refresh_button.custom_minimum_size.x = 60
	_refresh_button.pressed.connect(_refresh_plugin_list)
	header_row.add_child(_refresh_button)

	_plugin_list = ItemList.new()
	_plugin_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_plugin_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plugin_list.item_selected.connect(_on_plugin_selected)
	vbox.add_child(_plugin_list)

	return vbox


func _build_right_pane() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.clip_contents = true

	var right_vbox := VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.clip_contents = true
	scroll.add_child(right_vbox)

	# Placeholder shown when nothing is selected.
	_detail_placeholder = Label.new()
	_detail_placeholder.text = "Select a plugin to view details."
	_detail_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail_placeholder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_placeholder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(_detail_placeholder)

	# Actual detail panel (hidden until a plugin is selected).
	_detail_panel = VBoxContainer.new()
	_detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_panel.visible = false
	right_vbox.add_child(_detail_panel)

	_build_detail_header(_detail_panel)
	_detail_panel.add_child(HSeparator.new())
	_build_caps_section(_detail_panel)
	_detail_panel.add_child(HSeparator.new())
	_build_audit_section(_detail_panel)
	_detail_panel.add_child(HSeparator.new())
	_build_tools_section(_detail_panel)

	return scroll


func _build_detail_header(parent: VBoxContainer) -> void:
	# Plugin name (large)
	_detail_name_label = Label.new()
	_detail_name_label.text = ""
	_detail_name_label.add_theme_font_size_override("font_size", 16)
	parent.add_child(_detail_name_label)

	# Version + ID row
	var meta_row := HBoxContainer.new()
	parent.add_child(meta_row)

	var ver_title := Label.new()
	ver_title.text = "Version: "
	ver_title.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	meta_row.add_child(ver_title)

	_detail_version_label = Label.new()
	_detail_version_label.text = "-"
	meta_row.add_child(_detail_version_label)

	var id_sep := Label.new()
	id_sep.text = "  |  ID: "
	id_sep.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	meta_row.add_child(id_sep)

	_detail_id_label = Label.new()
	_detail_id_label.text = "-"
	meta_row.add_child(_detail_id_label)

	# Status row
	var status_row := HBoxContainer.new()
	parent.add_child(status_row)

	var status_title := Label.new()
	status_title.text = "Status: "
	status_title.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	status_row.add_child(status_title)

	_detail_status_label = Label.new()
	_detail_status_label.text = "-"
	status_row.add_child(_detail_status_label)

	var uptime_sep := Label.new()
	uptime_sep.text = "  Uptime: "
	uptime_sep.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	status_row.add_child(uptime_sep)

	_detail_uptime_label = Label.new()
	_detail_uptime_label.text = "-"
	status_row.add_child(_detail_uptime_label)

	# Control buttons — row 1: Start / Stop / Restart / Reload
	var btn_row := HBoxContainer.new()
	parent.add_child(btn_row)

	_start_button = Button.new()
	_start_button.text = "Start"
	_start_button.pressed.connect(_on_start_pressed)
	btn_row.add_child(_start_button)

	_stop_button = Button.new()
	_stop_button.text = "Stop"
	_stop_button.pressed.connect(_on_stop_pressed)
	btn_row.add_child(_stop_button)

	_restart_button = Button.new()
	_restart_button.text = "Restart"
	_restart_button.pressed.connect(_on_restart_pressed)
	btn_row.add_child(_restart_button)

	_reload_button = Button.new()
	_reload_button.text = "Reload"
	_reload_button.tooltip_text = "Kill, recompile/reinitialise, and restart the plugin to pick up code changes"
	_reload_button.pressed.connect(_on_reload_pressed)
	btn_row.add_child(_reload_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)

	_remove_button = Button.new()
	_remove_button.text = "Remove Plugin"
	_remove_button.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	_remove_button.pressed.connect(_on_remove_pressed)
	btn_row.add_child(_remove_button)

	# Control toggles — row 2: Auto-start / Auto-reload / files-changed indicator
	var toggle_row := HBoxContainer.new()
	parent.add_child(toggle_row)

	_autostart_check = CheckButton.new()
	_autostart_check.text = "Auto-start"
	_autostart_check.tooltip_text = "Start this plugin automatically when Minerva launches"
	_autostart_check.toggled.connect(_on_autostart_toggled)
	toggle_row.add_child(_autostart_check)

	_auto_reload_check = CheckButton.new()
	_auto_reload_check.text = "Auto-reload"
	_auto_reload_check.tooltip_text = "Automatically reload this plugin when its source files change (hot reload)"
	_auto_reload_check.toggled.connect(_on_auto_reload_toggled)
	toggle_row.add_child(_auto_reload_check)

	_files_changed_label = Label.new()
	_files_changed_label.text = "● files changed"
	_files_changed_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.1))
	_files_changed_label.tooltip_text = "Source files have changed. Click 'Reload' to pick up changes."
	_files_changed_label.visible = false
	toggle_row.add_child(_files_changed_label)


func _build_caps_section(parent: VBoxContainer) -> void:
	_caps_container = VBoxContainer.new()
	_caps_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_caps_container)

	var hdr := Label.new()
	hdr.text = "Capabilities"
	hdr.add_theme_font_size_override("font_size", 13)
	_caps_container.add_child(hdr)

	var desc := Label.new()
	desc.text = "Toggle to grant or revoke plugin permissions."
	desc.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	_caps_container.add_child(desc)


func _build_audit_section(parent: VBoxContainer) -> void:
	_audit_container = VBoxContainer.new()
	_audit_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_audit_container)

	var hdr_row := HBoxContainer.new()
	_audit_container.add_child(hdr_row)

	var hdr := Label.new()
	hdr.text = "Recent Audit Events"
	hdr.add_theme_font_size_override("font_size", 13)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)

	var refresh_audit_btn := Button.new()
	refresh_audit_btn.text = "Refresh"
	refresh_audit_btn.flat = true
	refresh_audit_btn.pressed.connect(func(): _populate_detail_panel(_selected_plugin_id))
	hdr_row.add_child(refresh_audit_btn)

	_audit_scroll = ScrollContainer.new()
	_audit_scroll.custom_minimum_size.y = 120
	_audit_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_audit_container.add_child(_audit_scroll)

	_audit_list = VBoxContainer.new()
	_audit_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_audit_scroll.add_child(_audit_list)


func _build_tools_section(parent: VBoxContainer) -> void:
	_tools_container = VBoxContainer.new()
	_tools_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_tools_container)

	var hdr := Label.new()
	hdr.text = "Provided Tools"
	hdr.add_theme_font_size_override("font_size", 13)
	_tools_container.add_child(hdr)

	_tools_list = VBoxContainer.new()
	_tools_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tools_container.add_child(_tools_list)


func _build_bottom_toolbar() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.custom_minimum_size.y = 32

	_install_button = Button.new()
	_install_button.text = "Install Plugin..."
	_install_button.pressed.connect(_on_install_pressed)
	hbox.add_child(_install_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
	hbox.add_child(_status_label)

	return hbox


# ---------------------------------------------------------------------------
# Signal wiring
# ---------------------------------------------------------------------------

func _connect_signals() -> void:
	if not SingletonObject.plugin_manager:
		return

	var pm: PluginManager = SingletonObject.plugin_manager
	if not pm.plugin_state_changed.is_connected(_on_plugin_state_changed):
		pm.plugin_state_changed.connect(_on_plugin_state_changed)
	if not pm.plugin_started.is_connected(_on_plugin_event):
		pm.plugin_started.connect(_on_plugin_event)
	if not pm.plugin_stopped.is_connected(_on_plugin_event):
		pm.plugin_stopped.connect(_on_plugin_event)
	if not pm.plugin_crashed.is_connected(_on_plugin_event):
		pm.plugin_crashed.connect(_on_plugin_event)
	if not pm.plugin_file_changed.is_connected(_on_plugin_file_changed):
		pm.plugin_file_changed.connect(_on_plugin_file_changed)

	if SingletonObject.plugin_audit_log:
		var al: PluginAuditLog = SingletonObject.plugin_audit_log
		if not al.entry_added.is_connected(_on_audit_entry_added):
			al.entry_added.connect(_on_audit_entry_added)


func _disconnect_signals() -> void:
	if not SingletonObject.plugin_manager:
		return

	var pm: PluginManager = SingletonObject.plugin_manager
	if pm.plugin_state_changed.is_connected(_on_plugin_state_changed):
		pm.plugin_state_changed.disconnect(_on_plugin_state_changed)
	if pm.plugin_started.is_connected(_on_plugin_event):
		pm.plugin_started.disconnect(_on_plugin_event)
	if pm.plugin_stopped.is_connected(_on_plugin_event):
		pm.plugin_stopped.disconnect(_on_plugin_event)
	if pm.plugin_crashed.is_connected(_on_plugin_event):
		pm.plugin_crashed.disconnect(_on_plugin_event)
	if pm.plugin_file_changed.is_connected(_on_plugin_file_changed):
		pm.plugin_file_changed.disconnect(_on_plugin_file_changed)

	if SingletonObject.plugin_audit_log:
		var al: PluginAuditLog = SingletonObject.plugin_audit_log
		if al.entry_added.is_connected(_on_audit_entry_added):
			al.entry_added.disconnect(_on_audit_entry_added)


# ---------------------------------------------------------------------------
# Plugin list population
# ---------------------------------------------------------------------------

func _refresh_plugin_list() -> void:
	if not _plugin_list:
		return

	_plugin_list.clear()

	if not SingletonObject.plugin_manager:
		var empty_item := _plugin_list.add_item("(Plugin system unavailable)")
		_plugin_list.set_item_disabled(empty_item, true)
		return

	var pm: PluginManager = SingletonObject.plugin_manager
	var plugins: Array = pm.get_all_plugins()

	if plugins.is_empty():
		var idx := _plugin_list.add_item("No plugins installed")
		_plugin_list.set_item_disabled(idx, true)
		return

	for status in plugins:
		var display_name: String = "%s  v%s" % [status.get("name", status.get("id", "?")), status.get("version", "")]
		var idx := _plugin_list.add_item(display_name)
		_plugin_list.set_item_metadata(idx, status.get("id", ""))
		_apply_state_color(idx, status.get("state", PluginDefinition.State.INSTALLED))


func _apply_state_color(item_idx: int, state: int) -> void:
	var color: Color
	match state:
		PluginDefinition.State.RUNNING:
			color = Color(0.3, 0.9, 0.4)   # green
		PluginDefinition.State.STARTING:
			color = Color(0.9, 0.8, 0.2)   # yellow
		PluginDefinition.State.STOPPED, PluginDefinition.State.INSTALLED:
			color = Color(0.6, 0.6, 0.6)   # gray
		PluginDefinition.State.ERROR:
			color = Color(0.9, 0.3, 0.3)   # red
		PluginDefinition.State.CRASH_LOOP:
			color = Color(1.0, 0.2, 0.2)   # bright red
		_:
			color = Color(0.6, 0.6, 0.6)

	_plugin_list.set_item_custom_fg_color(item_idx, color)


# ---------------------------------------------------------------------------
# Detail panel population
# ---------------------------------------------------------------------------

func _populate_detail_panel(plugin_id: String) -> void:
	if plugin_id.is_empty() or not SingletonObject.plugin_manager:
		_detail_placeholder.visible = true
		_detail_panel.visible = false
		return

	var pm: PluginManager = SingletonObject.plugin_manager
	var status: Dictionary = pm.get_plugin_status(plugin_id)
	if status.has("error"):
		_detail_placeholder.visible = true
		_detail_panel.visible = false
		return

	_detail_placeholder.visible = false
	_detail_panel.visible = true

	# Header
	_detail_name_label.text = status.get("name", plugin_id)
	_detail_version_label.text = status.get("version", "-")
	_detail_id_label.text = plugin_id

	var state: int = status.get("state", PluginDefinition.State.INSTALLED)
	var state_name: String = status.get("state_name", "UNKNOWN")
	_detail_status_label.text = state_name
	_detail_status_label.add_theme_color_override("font_color", _state_color(state))

	var uptime: float = status.get("uptime_sec", 0.0)
	_detail_uptime_label.text = _format_uptime(uptime) if state == PluginDefinition.State.RUNNING else "-"

	# Button states
	var is_running := state == PluginDefinition.State.RUNNING
	var is_starting := state == PluginDefinition.State.STARTING
	var is_crash_loop := state == PluginDefinition.State.CRASH_LOOP
	_start_button.disabled = is_running or is_starting or is_crash_loop
	_stop_button.disabled = not (is_running or is_starting)
	_restart_button.disabled = not (is_running or is_starting)

	# Autostart / auto-reload toggles — reflect current DB state without re-triggering signals
	var def = pm.get_db().get_by_id(plugin_id)
	if def != null:
		if _autostart_check != null:
			_autostart_check.set_pressed_no_signal(def.autostart)
		if _auto_reload_check != null:
			_auto_reload_check.set_pressed_no_signal(def.auto_reload)

	# Capabilities
	_populate_capabilities(plugin_id)

	# Audit log
	_populate_audit_log(plugin_id)

	# Tools
	_populate_tools(plugin_id)


func _populate_capabilities(plugin_id: String) -> void:
	# Remove old capability rows (skip header labels at index 0 and 1)
	var children := _caps_container.get_children()
	for i in range(children.size() - 1, 1, -1):
		children[i].queue_free()

	if not SingletonObject.plugin_policy:
		return

	var policy: PluginPolicy = SingletonObject.plugin_policy
	var requested: Array = policy.get_requested_capabilities(plugin_id)
	var granted: Array = policy.get_granted_capabilities(plugin_id)

	if requested.is_empty():
		var none_label := Label.new()
		none_label.text = "No capabilities requested."
		none_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_caps_container.add_child(none_label)
		return

	for cap in requested:
		var row := HBoxContainer.new()
		_caps_container.add_child(row)

		var toggle := CheckButton.new()
		# Display mcp.proxy capabilities with the prefix stripped for readability
		var display_name: String = cap
		if cap.begins_with("mcp.proxy:"):
			display_name = cap.substr("mcp.proxy:".length())
			toggle.tooltip_text = cap
		toggle.text = display_name
		toggle.button_pressed = cap in granted
		toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Capture cap in a local variable for the lambda
		var cap_copy: String = cap
		toggle.toggled.connect(func(pressed: bool):
			if pressed:
				policy.grant_capability(plugin_id, cap_copy)
			else:
				policy.revoke_capability(plugin_id, cap_copy)
			_show_status("Capability '%s' %s" % [cap_copy, "granted" if pressed else "revoked"])
		)
		row.add_child(toggle)

		# Add mcp.proxy badge for proxy capabilities
		if cap.begins_with("mcp.proxy:"):
			var badge := Label.new()
			badge.text = "mcp.proxy"
			badge.add_theme_color_override("font_color", Color(0.5, 0.7, 0.9))
			badge.add_theme_font_size_override("font_size", 10)
			row.add_child(badge)

	# Also show any extra granted caps not in the manifest (shouldn't happen, but be safe)
	for cap in granted:
		if cap not in requested:
			var row := HBoxContainer.new()
			_caps_container.add_child(row)

			var toggle := CheckButton.new()
			toggle.text = cap + " (extra)"
			toggle.button_pressed = true
			toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var cap_copy: String = cap
			toggle.toggled.connect(func(pressed: bool):
				if not pressed:
					policy.revoke_capability(plugin_id, cap_copy)
					_show_status("Capability '%s' revoked" % cap_copy)
			)
			row.add_child(toggle)


func _populate_audit_log(plugin_id: String) -> void:
	# Clear existing rows
	for child in _audit_list.get_children():
		child.queue_free()

	if not SingletonObject.plugin_audit_log:
		return

	var al: PluginAuditLog = SingletonObject.plugin_audit_log
	var entries: Array = al.get_entries(plugin_id, "", 20)

	if entries.is_empty():
		var none_label := Label.new()
		none_label.text = "No audit events yet."
		none_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_audit_list.add_child(none_label)
		return

	for entry in entries:
		var event_type: String = entry.get("event_type", "")
		var timestamp: String = entry.get("timestamp", "")
		var detail: Dictionary = entry.get("detail", {})
		var is_denial := event_type == PluginAuditLog.EVENT_POLICY_DENY

		var row := HBoxContainer.new()
		_audit_list.add_child(row)

		# Timestamp
		var ts_label := Label.new()
		# Show only the time portion if available (after the T)
		var ts_short := timestamp
		if "T" in timestamp:
			ts_short = timestamp.split("T")[1].left(8)
		ts_label.text = ts_short
		ts_label.custom_minimum_size.x = 65
		ts_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		row.add_child(ts_label)

		# Event type (colored red for denials)
		var type_label := Label.new()
		type_label.text = event_type
		type_label.custom_minimum_size.x = 120
		type_label.clip_text = true
		if is_denial:
			type_label.add_theme_color_override("font_color", Color(0.9, 0.35, 0.35))
		else:
			type_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		row.add_child(type_label)

		# Detail (capability, etc.)
		var detail_str := ""
		if detail.has("capability"):
			detail_str = detail["capability"]
		elif detail.has("reason"):
			detail_str = detail["reason"]
		if not detail_str.is_empty():
			var detail_label := Label.new()
			detail_label.text = detail_str
			detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			detail_label.clip_text = true
			detail_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
			row.add_child(detail_label)

		# Quick-grant button for denials
		if is_denial and detail.has("capability"):
			var denied_cap: String = detail["capability"]
			var grant_btn := Button.new()
			grant_btn.text = "Grant"
			grant_btn.flat = true
			grant_btn.add_theme_color_override("font_color", Color(0.4, 0.85, 0.5))
			grant_btn.pressed.connect(func():
				if SingletonObject.plugin_policy:
					SingletonObject.plugin_policy.grant_capability(plugin_id, denied_cap)
					_show_status("Granted '%s' to %s" % [denied_cap, plugin_id])
					_populate_detail_panel(plugin_id)
			)
			row.add_child(grant_btn)


func _populate_tools(plugin_id: String) -> void:
	# Clear existing rows
	for child in _tools_list.get_children():
		child.queue_free()

	if not SingletonObject.plugin_manager:
		return

	var pm: PluginManager = SingletonObject.plugin_manager
	var db: PluginDB = pm.get_db()
	var def: PluginDefinition = db.get_by_id(plugin_id)

	if def == null or def.tools.is_empty():
		var none_label := Label.new()
		none_label.text = "No tools declared."
		none_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_tools_list.add_child(none_label)
		return

	# Check which tools are registered in PluginToolRegistry
	var registered_names: Dictionary = {}
	if SingletonObject.plugin_tool_registry:
		var reg: PluginToolRegistry = SingletonObject.plugin_tool_registry
		for t in reg.get_plugin_tools(plugin_id):
			registered_names[t.get("name", "")] = true

	for tool_entry in def.tools:
		var tool_name: String = tool_entry.get("name", "")
		var tool_desc: String = tool_entry.get("description", "")
		var is_registered: bool = registered_names.has(tool_name)

		var row := HBoxContainer.new()
		_tools_list.add_child(row)

		var status_dot := Label.new()
		status_dot.text = "●  "
		status_dot.add_theme_color_override("font_color",
			Color(0.3, 0.9, 0.4) if is_registered else Color(0.5, 0.5, 0.5))
		row.add_child(status_dot)

		var name_label := Label.new()
		name_label.text = tool_name
		name_label.custom_minimum_size.x = 200
		row.add_child(name_label)

		if not tool_desc.is_empty():
			var desc_label := Label.new()
			desc_label.text = tool_desc
			desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			desc_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
			desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
			row.add_child(desc_label)


# ---------------------------------------------------------------------------
# Signal Handlers — plugin manager events
# ---------------------------------------------------------------------------

func _on_plugin_selected(index: int) -> void:
	_selected_plugin_id = _plugin_list.get_item_metadata(index)
	# Clear the files-changed indicator when switching to a different plugin.
	if _files_changed_label:
		_files_changed_label.visible = false
	_populate_detail_panel(_selected_plugin_id)


func _on_plugin_state_changed(_id: String, _old: int, _new: int) -> void:
	_refresh_plugin_list()
	# Re-select the same plugin so the right pane updates
	if not _selected_plugin_id.is_empty():
		_populate_detail_panel(_selected_plugin_id)


func _on_plugin_event(_id: String) -> void:
	_refresh_plugin_list()
	if not _selected_plugin_id.is_empty():
		_populate_detail_panel(_selected_plugin_id)


func _on_audit_entry_added(entry: Dictionary) -> void:
	# Refresh audit section if this event is for the currently-viewed plugin
	var entry_plugin: String = entry.get("plugin_id", "")
	if entry_plugin == _selected_plugin_id and not _selected_plugin_id.is_empty():
		_populate_audit_log(_selected_plugin_id)


# ---------------------------------------------------------------------------
# Signal Handlers — control buttons
# ---------------------------------------------------------------------------

func _on_start_pressed() -> void:
	if _selected_plugin_id.is_empty():
		return
	_show_status("Starting %s..." % _selected_plugin_id)
	_start_button.disabled = true
	await SingletonObject.plugin_manager.start_plugin(_selected_plugin_id)
	_refresh_plugin_list()


func _on_stop_pressed() -> void:
	if _selected_plugin_id.is_empty():
		return
	_show_status("Stopping %s..." % _selected_plugin_id)
	_stop_button.disabled = true
	await SingletonObject.plugin_manager.stop_plugin(_selected_plugin_id)
	_refresh_plugin_list()


func _on_restart_pressed() -> void:
	if _selected_plugin_id.is_empty():
		return
	_show_status("Restarting %s..." % _selected_plugin_id)
	_restart_button.disabled = true
	await SingletonObject.plugin_manager.restart_plugin(_selected_plugin_id)
	_refresh_plugin_list()


func _on_reload_pressed() -> void:
	if _selected_plugin_id.is_empty():
		return
	_show_status("Reloading %s..." % _selected_plugin_id)
	_reload_button.disabled = true
	if _files_changed_label:
		_files_changed_label.visible = false
	await SingletonObject.plugin_manager.restart_plugin(_selected_plugin_id)
	_reload_button.disabled = false
	_refresh_plugin_list()


func _on_autostart_toggled(enabled: bool) -> void:
	if _selected_plugin_id.is_empty():
		return
	SingletonObject.plugin_manager.get_db().set_autostart(_selected_plugin_id, enabled)
	_show_status("Auto-start %s for %s" % ["enabled" if enabled else "disabled", _selected_plugin_id])


func _on_auto_reload_toggled(enabled: bool) -> void:
	if _selected_plugin_id.is_empty():
		return
	SingletonObject.plugin_manager.set_auto_reload(_selected_plugin_id, enabled)
	_show_status("Auto-reload %s for %s" % ["enabled" if enabled else "disabled", _selected_plugin_id])


func _on_plugin_file_changed(id: String) -> void:
	# Show the "files changed" indicator if the changed plugin is currently selected.
	if id == _selected_plugin_id and _files_changed_label:
		_files_changed_label.visible = true


func _on_install_pressed() -> void:
	if _install_dialog == null:
		_install_dialog = FileDialog.new()
		_install_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_install_dialog.filters = PackedStringArray(["*.json ; Plugin Manifest"])
		_install_dialog.title = "Select Plugin Manifest (manifest.json)"
		_install_dialog.file_selected.connect(_on_manifest_selected)
		add_child(_install_dialog)
	_install_dialog.popup_centered(Vector2i(700, 500))


func _on_manifest_selected(path: String) -> void:
	if not SingletonObject.plugin_manager:
		_show_status("Plugin manager unavailable.", true)
		return

	var result: Dictionary = SingletonObject.plugin_manager.install_plugin(path)
	if result.has("error"):
		_show_status("Install failed: %s" % result["error"], true)
	else:
		_show_status("Installed plugin '%s'." % result.get("id", "?"))
		_refresh_plugin_list()


func _on_remove_pressed() -> void:
	if _selected_plugin_id.is_empty():
		return

	if _remove_confirm == null:
		_remove_confirm = ConfirmationDialog.new()
		_remove_confirm.confirmed.connect(_on_remove_confirmed)
		add_child(_remove_confirm)

		# Add a checkbox option to delete data to the dialog's content area
		_remove_delete_data_check = CheckButton.new()
		_remove_delete_data_check.text = "Also delete plugin data directory"
		_remove_delete_data_check.tooltip_text = "If checked, the plugin's data directory (user://plugins/data/<id>/) will be permanently deleted"
		_remove_confirm.add_child(_remove_delete_data_check)

	_pending_remove_id = _selected_plugin_id
	var pm_name := _selected_plugin_id
	if SingletonObject.plugin_manager:
		var status = SingletonObject.plugin_manager.get_plugin_status(_selected_plugin_id)
		pm_name = status.get("name", _selected_plugin_id)

	_remove_confirm.dialog_text = "Remove plugin '%s'?\n\nThis will stop the plugin and remove it from Minerva." % pm_name
	_remove_delete_data_check.button_pressed = false
	_remove_confirm.popup_centered()


func _on_remove_confirmed() -> void:
	if _pending_remove_id.is_empty() or not SingletonObject.plugin_manager:
		return

	var delete_data := _remove_delete_data_check.button_pressed if _remove_delete_data_check else false
	var result: Dictionary = await SingletonObject.plugin_manager.remove_plugin(_pending_remove_id, delete_data)
	if result.has("error"):
		_show_status("Remove failed: %s" % result["error"], true)
	else:
		_show_status("Plugin removed.")
		_selected_plugin_id = ""
		_detail_placeholder.visible = true
		_detail_panel.visible = false
		_refresh_plugin_list()

	_pending_remove_id = ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _show_status(message: String, is_error: bool = false) -> void:
	if not _status_label:
		return
	_status_label.text = message
	if is_error:
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	else:
		_status_label.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6))

	# Clear after 5 seconds
	get_tree().create_timer(5.0).timeout.connect(func():
		if _status_label and _status_label.text == message:
			_status_label.text = ""
	)


func _state_color(state: int) -> Color:
	match state:
		PluginDefinition.State.RUNNING:   return Color(0.3, 0.9, 0.4)
		PluginDefinition.State.STARTING:  return Color(0.9, 0.8, 0.2)
		PluginDefinition.State.ERROR:     return Color(0.9, 0.3, 0.3)
		PluginDefinition.State.CRASH_LOOP: return Color(1.0, 0.2, 0.2)
		_:                                return Color(0.6, 0.6, 0.6)


func _format_uptime(seconds: float) -> String:
	var s := int(seconds)
	if s < 60:
		return "%ds" % s
	elif s < 3600:
		return "%dm %ds" % [s / 60, s % 60]
	else:
		return "%dh %dm" % [s / 3600, (s % 3600) / 60]
