extends SceneTree
## Scansort panel substrate smoke test — T7 R1.
##
## Run: godot --headless --path src --script test/test_scansort_panel_smoke.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Round:         T7 R1 — panel UI substrate (ScansortPanel + PasswordDialog)
##
## Layer-1 headless checks (no display required):
##   1.  password_dialog.gd loads without parse errors
##   2.  PasswordDialog script is non-null after load()
##   3.  PasswordDialog extends AcceptDialog
##   4.  PasswordDialog has signal 'password_submitted'
##   5.  PasswordDialog has signal 'cancelled'
##   6.  PasswordDialog has method 'show_set_password'
##   7.  PasswordDialog has method 'show_enter_password'
##   8.  PasswordDialog has method 'show_wrong_password_error'
##   9.  PasswordDialog has method 'show_error'
##   10. ScansortPanel.tscn parses cleanly (PackedScene.instantiate does not crash)
##   11. Root node has class_name Scansort_Panel
##   12. ScansortPanel has method '_ready'
##   13. ScansortPanel has method '_on_open_vault_pressed'
##   14. ScansortPanel has method '_on_password_submitted' (alias check — _on_open_vault_password_submitted)
##   15. ScansortPanel has method '_get_connection'
##   16. ScansortPanel has method 'set_status'
##   17. ScansortPanel has method 'has_open_vault'
##   18. ScansortPanel has method 'get_active_vault_path'
##   19. Instantiated panel's _vault_is_open starts false
##   20. Instantiated panel's _active_vault_path starts empty

const PLUGIN_PANEL_TSCN := "/home/imran/github/plugins/scansort/ui/ScansortPanel.tscn"
const PLUGIN_PANEL_GD   := "/home/imran/github/plugins/scansort/ui/ScansortPanel.gd"
const PLUGIN_DIALOG_GD  := "/home/imran/github/plugins/scansort/ui/password_dialog.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Scansort Panel Substrate Smoke Test (T7 R1) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	await process_frame

	# -----------------------------------------------------------------------
	# Group A: password_dialog.gd
	# -----------------------------------------------------------------------
	print("\n-- A: password_dialog.gd --")

	var dialog_script = load(PLUGIN_DIALOG_GD)
	check("A1: password_dialog.gd loads without parse errors (non-null)",
		dialog_script != null,
		"load() returned null — check parse errors above")

	if dialog_script == null:
		# Can't continue A group.
		for _i in range(8):
			_fail_count += 1
		print("  SKIP A2-A9: dialog script null")
	else:
		var dlg_instance = dialog_script.new()
		check("A2: PasswordDialog instantiates",
			dlg_instance != null)

		check("A3: PasswordDialog extends AcceptDialog",
			dlg_instance is AcceptDialog,
			"got class: %s" % dlg_instance.get_class())

		check("A4: signal 'password_submitted' declared",
			dlg_instance.has_signal("password_submitted"))

		check("A5: signal 'cancelled' declared",
			dlg_instance.has_signal("cancelled"))

		check("A6: method 'show_set_password' exists",
			dlg_instance.has_method("show_set_password"))

		check("A7: method 'show_enter_password' exists",
			dlg_instance.has_method("show_enter_password"))

		check("A8: method 'show_wrong_password_error' exists",
			dlg_instance.has_method("show_wrong_password_error"))

		check("A9: method 'show_error' exists",
			dlg_instance.has_method("show_error"))

		if is_instance_valid(dlg_instance):
			dlg_instance.free()

	# -----------------------------------------------------------------------
	# Group B: ScansortPanel.tscn + ScansortPanel.gd
	# -----------------------------------------------------------------------
	print("\n-- B: ScansortPanel.tscn parse + class check --")

	var packed = load(PLUGIN_PANEL_TSCN)
	check("B10: ScansortPanel.tscn loads (PackedScene non-null)",
		packed != null,
		"load() of .tscn returned null")

	var panel_instance = null
	if packed != null:
		panel_instance = packed.instantiate()
		check("B11: instantiate() returns non-null node",
			panel_instance != null)

		if panel_instance != null:
			check("B12: root node class is Scansort_Panel",
				panel_instance.get_script() != null and
				panel_instance.get_script().get_global_name() == "Scansort_Panel",
				"global name: '%s'" % (panel_instance.get_script().get_global_name() if panel_instance.get_script() != null else "<no script>"))
		else:
			_fail_count += 1
			printerr("  FAIL B12: panel_instance is null")
	else:
		_fail_count += 2
		print("  SKIP B11-B12: packed scene null")

	# -----------------------------------------------------------------------
	# Group C: ScansortPanel.gd method presence
	# -----------------------------------------------------------------------
	print("\n-- C: ScansortPanel.gd method presence --")

	if panel_instance == null:
		for _i in range(8):
			_fail_count += 1
		print("  SKIP C13-C20: panel_instance null")
	else:
		check("C13: has method '_ready'",
			panel_instance.has_method("_ready"))

		check("C14: has method '_on_open_vault_pressed'",
			panel_instance.has_method("_on_open_vault_pressed"))

		# R1 uses _on_open_vault_password_submitted (password reply for open flow)
		check("C15: has method '_on_open_vault_password_submitted'",
			panel_instance.has_method("_on_open_vault_password_submitted"))

		check("C16: has method '_get_connection'",
			panel_instance.has_method("_get_connection"))

		check("C17: has method 'set_status'",
			panel_instance.has_method("set_status"))

		check("C18: has method 'has_open_vault'",
			panel_instance.has_method("has_open_vault"))

		check("C19: has method 'get_active_vault_path'",
			panel_instance.has_method("get_active_vault_path"))

		# -----------------------------------------------------------------------
		# Group D: Initial state via _ready (add to tree to trigger _ready)
		# -----------------------------------------------------------------------
		print("\n-- D: initial state after _ready --")

		root.add_child(panel_instance)
		await process_frame

		check("D20: _vault_is_open starts false",
			panel_instance.get("_vault_is_open") == false,
			"got: %s" % str(panel_instance.get("_vault_is_open")))

		check("D21: _active_vault_path starts empty",
			panel_instance.get("_active_vault_path") == "",
			"got: '%s'" % str(panel_instance.get("_active_vault_path")))

		panel_instance.queue_free()
		await process_frame


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
