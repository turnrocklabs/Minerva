extends SceneTree
## Real PluginManager/PluginDB/panel paths; run only with an isolated profile.

var passed: int = 0
var failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	# Runtime load retains the autoload context required by the real manager.
	var manager_script = load("res://Scripts/Services/Plugins/PluginManager.gd")
	var manager = manager_script.new()
	manager._db = PluginDB.new()
	var panel = load("res://Scenes/PluginManagerPanel.tscn").instantiate()
	panel._pm_override = manager
	root.add_child(panel)
	await process_frame
	var capture = load("res://test/helpers/log_capture.gd").new()
	OS.add_logger(capture)
	await panel._on_manifest_selected("user://missing-diagnostic-manifest.json")
	var status: TextEdit = panel._status_label
	status.select_all()
	check("install failure is read-only, selectable and logged with its reason",
		not status.editable and status.get_selected_text() == status.text
		and status.text.begins_with("Install failed:")
		and "[PluginManager] " + status.text in capture.combined())
	# The native clipboard is checked when running in the disposable Windows desktop.
	if DisplayServer.get_name() != "headless":
		status.grab_focus()
		var copy := InputEventKey.new()
		copy.keycode = KEY_C
		copy.ctrl_pressed = true
		copy.pressed = true
		Input.parse_input_event(copy)
		await process_frame
		check("read-only selection copies through the native clipboard",
			DisplayServer.clipboard_get() == status.text)
	panel._pending_remove_id = "missing_diagnostic_plugin"
	await panel._on_remove_confirmed()
	check("remove failure keeps its reason in text and log",
		status.text.begins_with("Remove failed:") and "[PluginManager] " + status.text in capture.combined())
	var job = load("res://Scripts/Services/Plugins/PluginInstallJob.gd").new()
	job.state = job.State.DONE
	job.outcome = job.OUTCOME_FAILED
	job.message = "Fixture archive download refused"
	job.result = {"plugin_id": "fixture", "version": "1.0"}
	panel._on_install_job_changed(job)
	check("marketplace failure keeps its underlying reason in selectable text and log",
		job.message in status.text and job.message in capture.combined())
	await check_layout(panel, manager)
	root.remove_child(panel)
	panel._show_status("Removal completed after panel detached")
	check("detached completion is logged without a missing SceneTree",
		"[PluginManager] Removal completed after panel detached" in capture.combined())
	OS.remove_logger(capture)
	panel.free()
	manager.free()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)


# The real panel's container geometry is the oracle, not clip_contents flags.
# The fixture manager remains dynamic because --script needs runtime autoloads.
func check_layout(panel, manager) -> void:
	var definition := PluginDefinition.new()
	definition.id = "layout_fixture"
	definition.name = "A long plugin name ".repeat(15)
	definition.version = "1.0." + "1234567890".repeat(20)
	definition.install_lane = PluginDefinition.LANE_MARKETPLACE
	definition.state = manager.S_BUILD_FAILED
	definition.tools = [{"name": "unbroken_tool_name_".repeat(30), "description": "long-description/".repeat(50)}]
	manager.get_db()._plugins[definition.id] = definition
	var notice := "Docket cannot be reached. " + "unbroken-diagnostic/".repeat(60)
	manager._ensure_runtime(definition.id)["notice"] = notice
	manager._setup_envelopes[definition.id] = {
		"expected_path": "/long/unbroken/path/".repeat(60),
		"install_hint": "A multiline install hint\n".repeat(15),
	}
	var singleton = root.get_node("SingletonObject")
	var old_policy = singleton.plugin_policy
	var old_audit = singleton.plugin_audit_log
	var audit := PluginAuditLog.new()
	var policy := PluginPolicy.new(manager.get_db(), audit, false)
	singleton.plugin_policy = policy
	singleton.plugin_audit_log = audit
	definition.host_capabilities = ["mcp.proxy:" + "long-capability/".repeat(40)]
	audit.log_event(definition.id, PluginAuditLog.EVENT_POLICY_DENY, {"capability": definition.host_capabilities[0]})
	panel._selected_plugin_id = definition.id
	panel._refresh_plugin_list()
	panel._populate_detail_panel(definition.id)
	check("ellipsized identity fields expose their complete tooltips",
		panel._detail_name_label.get_tooltip() == definition.name
		and panel._detail_name_label.mouse_filter != Control.MOUSE_FILTER_IGNORE
		and panel._detail_id_label.get_tooltip() == definition.id
		and panel._detail_id_label.mouse_filter != Control.MOUSE_FILTER_IGNORE)
	var editor_error := "PluginEditorRegistry: '.fixturefmt' claimed by 'first'; plugin 'layout_fixture' registration refused"
	manager.set_editor_registration(definition.id, editor_error)
	panel._populate_detail_panel(definition.id)
	var editor_detail: TextEdit = panel._detail_editor_error
	editor_detail.select_all()
	check("editor registration refusal is selectable in Plugin Manager detail",
		not editor_detail.editable and editor_detail.visible and editor_error in editor_detail.get_selected_text()
		and manager.get_plugin_status(definition.id).editor_registration.error == editor_error)
	definition.requires_plugins = [{"id": "voice", "min_version": "99.0.0", "actions": ["minerva_voice_status"]}]
	panel._populate_detail_panel(definition.id)
	editor_detail.select_all()
	check("dependency notice is complete and selectable beside registration refusal",
		not editor_detail.editable and editor_detail.visible and "requires voice" in editor_detail.get_selected_text()
		and editor_error in editor_detail.get_selected_text())
	definition.requires_plugins.clear()
	panel._populate_detail_panel(definition.id)
	panel._required_button.show()
	panel._update_button.show()
	panel._panel_button.show()
	panel._files_changed_label.show()
	var detail_scroll: ScrollContainer = panel._detail_panel.get_parent().get_parent()
	var case_index: int = 0
	for font_size: int in [16, 24]:
		var fixture_theme := Theme.new()
		fixture_theme.default_font_size = font_size
		panel.theme = fixture_theme
		for height: float in [640.0, 480.0]:
			for width: float in [1100.0, 360.0, 600.0, 1100.0]:
				panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
				panel.size = Vector2(width, height)
				for frame: int in range(8):
					# Repeat the pane allocation as its parent container would do
					# after the responsive split changes its minimum size.
					panel.size = Vector2(width, height)
					await process_frame
				case_index += 1
				var context := "width=%d height=%d font=%d case=%d" % [int(width), int(height), font_size, case_index]
				check("panel stays inside assigned pane " + context,
					panel.size.x <= width + 1 and panel.size.y <= height + 1
					and panel.get_combined_minimum_size().x <= width)
				check("details and status stay inside pane " + context,
					inside_horizontally(panel, detail_scroll)
					and inside_horizontally(panel, panel._status_label))
				check("toolbar wraps with reachable actions " + context,
					inside_horizontally(panel, panel._install_button)
					and inside_horizontally(panel, panel._browse_button)
					and inside_horizontally(panel, panel._required_button)
					and panel._required_button.get_global_rect().end.y <= panel.get_global_rect().end.y + 1)
				check("detail action rows fit " + context,
					inside_horizontally(detail_scroll, panel._remove_button)
					and inside_horizontally(detail_scroll, panel._auto_update_check)
					and inside_horizontally(detail_scroll, panel._panel_button))
				check("long detail notice stays intact and wraps " + context,
					notice in editor_detail.text and editor_detail.wrap_mode != TextEdit.LINE_WRAPPING_NONE)
				check("details keep a usable viewport " + context, detail_scroll.size.y >= font_size * 3)
				check("plugin list keeps a complete visible row " + context,
					panel._plugin_list.get_item_rect(0).end.y <= panel._plugin_list.size.y + 1)
				check("overflowing details scroll vertically " + context,
					detail_scroll.get_v_scroll_bar().max_value > detail_scroll.size.y)
				for message: String in ["reload layout_fixture succeeded " + context, "Reload failed: " + notice + "\n" + notice + context]:
					panel._display_status(message, message.begins_with("Reload failed"))
					for frame: int in range(3):
						await process_frame
					panel._status_label.select_all()
					check("complete status remains selectable and bounded " + context,
						panel._status_label.get_selected_text() == message
						and inside_horizontally(panel, panel._status_label)
						and panel.size.x <= width + 1)
				panel._status_label.scroll_vertical = 10000
				check("long status scrolls within its own area " + context,
					panel._status_label.scroll_vertical > 0
					and panel._status_label.size.y < 150)
				detail_scroll.ensure_control_visible(panel._start_button)
				await process_frame
				check("lifecycle action can be scrolled into view " + context,
					visible_vertically(detail_scroll, panel._start_button))
				# Scroll to the final tools section to prove content stays reachable.
				detail_scroll.ensure_control_visible(panel._tools_container)
				await process_frame
				check("last details section can be reached " + context, detail_scroll.scroll_vertical > 0)
				detail_scroll.scroll_vertical = 0
	singleton.plugin_policy = old_policy
	singleton.plugin_audit_log = old_audit


func inside_horizontally(outer: Control, inner: Control) -> bool:
	var outside := outer.get_global_rect()
	var inside := inner.get_global_rect()
	return inside.position.x >= outside.position.x - 1 and inside.end.x <= outside.end.x + 1


func visible_vertically(viewport: Control, action: Control) -> bool:
	var outside := viewport.get_global_rect()
	var inside := action.get_global_rect()
	return inside.position.y >= outside.position.y - 1 and inside.end.y <= outside.end.y + 1
