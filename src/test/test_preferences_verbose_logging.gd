extends SceneTree
## Exercises the real Preferences Save gate without constructing unrelated tabs.

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var Fixture = load("res://test/helpers/preferences_verbose_fixture.gd")
	var singleton = root.get_node("SingletonObject")
	var original: bool = singleton.verbose_logging
	var saved_original: bool = singleton.config_file.get_value("Logging", "verbose", original)
	var disk_before := ConfigFile.new()
	disk_before.load(singleton._config_file_name)
	var disk_before_text := disk_before.encode_to_text()
	var target := not saved_original
	var popup = Fixture.new()
	var button := CheckButton.new()
	var toggles := {"count": 0}
	button.toggled.connect(func(_enabled: bool): toggles.count += 1)
	popup._load_verbose_logging_setting(button)
	check("reopening loads verbose state without emitting a toggle",
		button.button_pressed == saved_original and toggles.count == 0)
	popup._on_verbose_logging_check_button_toggled(target)
	check("staging verbose logging does not change runtime or persisted config",
		singleton.verbose_logging == original
		and singleton.config_file.get_value("Logging", "verbose", original) == saved_original)
	popup._staged_verbose_logging = target
	popup.confirmation_result = false
	await popup._on_btn_save_prefs_pressed()
	check("cancelled deactivation leaves verbose logging and config unchanged",
		singleton.verbose_logging == original and not popup.confirmed_save_called
		and singleton.config_file.get_value("Logging", "verbose", original) == saved_original)
	var disk_after_cancel := ConfigFile.new()
	disk_after_cancel.load(singleton._config_file_name)
	check("cancelled Save leaves the preferences file unchanged",
		disk_after_cancel.encode_to_text() == disk_before_text)

	popup.confirmation_result = true
	await popup._on_btn_save_prefs_pressed()
	check("accepted Preferences Save applies and persists the staged value",
		singleton.verbose_logging == target and popup.confirmed_save_called
		and singleton.config_file.get_value("Logging", "verbose", original) == target)
	popup._load_verbose_logging_setting(button)
	var disk := ConfigFile.new()
	var disk_error := disk.load(singleton._config_file_name)
	check("accepted Save survives a fresh config reload",
		disk_error == OK and disk.get_value("Logging", "verbose", original) == target
		and button.button_pressed == target and toggles.count == 0)

	singleton.set_verbose_logging(saved_original, false)
	var unchanged_disk := ConfigFile.new()
	unchanged_disk.load(singleton._config_file_name)
	check("startup-style nonpersistent application changes runtime only",
		singleton.verbose_logging == saved_original
		and unchanged_disk.get_value("Logging", "verbose", original) == target)

	singleton.set_verbose_logging(saved_original)
	singleton.verbose_logging = original
	button.free()
	popup.free()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)
