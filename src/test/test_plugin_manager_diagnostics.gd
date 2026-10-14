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
	var status: LineEdit = panel._status_label
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
