extends SceneTree
## Scansort panel substrate smoke test — T7 R1 + R2.
##
## Run: godot --headless --path src --script test/test_scansort_panel_smoke.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Rounds:        T7 R1 — panel UI substrate (ScansortPanel + PasswordDialog)
##                T7 R2 — view scripts (FileTree, VaultView, StatusPanel)
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

const PLUGIN_PANEL_TSCN  := "/home/imran/github/plugins/scansort/ui/ScansortPanel.tscn"
const PLUGIN_PANEL_GD    := "/home/imran/github/plugins/scansort/ui/ScansortPanel.gd"
const PLUGIN_DIALOG_GD   := "/home/imran/github/plugins/scansort/ui/password_dialog.gd"
const PLUGIN_FILETREE_GD := "/home/imran/github/plugins/scansort/ui/file_tree.gd"
const PLUGIN_VAULTVIEW_GD := "/home/imran/github/plugins/scansort/ui/vault_view.gd"
const PLUGIN_STATUSPANEL_GD := "/home/imran/github/plugins/scansort/ui/status_panel.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Scansort Panel Substrate Smoke Test (T7 R1 + R2) ===\n")
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

		# -------------------------------------------------------------------
		# Group E: R2 view script parse + method presence
		# -------------------------------------------------------------------
		print("\n-- E: R2 view scripts (file_tree, vault_view, status_panel) --")

		var ft_script = load(PLUGIN_FILETREE_GD)
		check("E22: file_tree.gd loads (non-null)",
			ft_script != null,
			"load() returned null")

		var vv_script = load(PLUGIN_VAULTVIEW_GD)
		check("E23: vault_view.gd loads (non-null)",
			vv_script != null,
			"load() returned null")

		var sp_script = load(PLUGIN_STATUSPANEL_GD)
		check("E24: status_panel.gd loads (non-null)",
			sp_script != null,
			"load() returned null")

		# file_tree.gd method presence
		if ft_script != null:
			var ft = ft_script.new()
			check("E25: FileTree instantiates", ft != null)
			if ft != null:
				check("E26: FileTree has method 'init'",    ft.has_method("init"))
				check("E27: FileTree has method 'refresh'", ft.has_method("refresh"))
				check("E28: FileTree has method 'clear_vault'", ft.has_method("clear_vault"))
				check("E29: FileTree has signal 'document_selected'",
					ft.has_signal("document_selected"))
				if is_instance_valid(ft):
					ft.free()
		else:
			for _i in range(5):
				_fail_count += 1
			print("  SKIP E25-E29: file_tree script null")

		# vault_view.gd method presence
		if vv_script != null:
			var vv = vv_script.new()
			check("E30: VaultView instantiates", vv != null)
			if vv != null:
				check("E31: VaultView has method 'init'",    vv.has_method("init"))
				check("E32: VaultView has method 'refresh'", vv.has_method("refresh"))
				check("E33: VaultView has method 'clear'",   vv.has_method("clear"))
				check("E34: VaultView has method 'on_document_selected'",
					vv.has_method("on_document_selected"))
				check("E35: VaultView has method 'on_documents_changed'",
					vv.has_method("on_documents_changed"))
				if is_instance_valid(vv):
					vv.free()
		else:
			for _i in range(6):
				_fail_count += 1
			print("  SKIP E30-E35: vault_view script null")

		# status_panel.gd method presence
		if sp_script != null:
			var sp = sp_script.new()
			check("E36: StatusPanel instantiates", sp != null)
			if sp != null:
				check("E37: StatusPanel has method 'init'",       sp.has_method("init"))
				check("E38: StatusPanel has method 'set_vault'",  sp.has_method("set_vault"))
				check("E39: StatusPanel has method 'set_status'", sp.has_method("set_status"))
				check("E40: StatusPanel has method 'clear'",      sp.has_method("clear"))
				if is_instance_valid(sp):
					sp.free()
		else:
			for _i in range(5):
				_fail_count += 1
			print("  SKIP E36-E40: status_panel script null")

		# -------------------------------------------------------------------
		# Group F: R2 panel integration — view instances wired into panel
		# -------------------------------------------------------------------
		print("\n-- F: R2 panel integration (views wired into ScansortPanel) --")

		check("F41: panel has _file_tree member (non-null after _ready)",
			panel_instance.get("_file_tree") != null,
			"_file_tree is null")

		check("F42: panel has _vault_view member (non-null after _ready)",
			panel_instance.get("_vault_view") != null,
			"_vault_view is null")

		check("F43: panel has _status_panel member (non-null after _ready)",
			panel_instance.get("_status_panel") != null,
			"_status_panel is null")

		# Verify file_tree is a child of LeftPane.
		var left_pane: Node = panel_instance.get("_left_pane")
		var ft_member: Node = panel_instance.get("_file_tree")
		check("F44: _file_tree is child of _left_pane",
			left_pane != null and ft_member != null and ft_member.get_parent() == left_pane,
			"parent mismatch")

		# Verify vault_view is a child of RightPane.
		var right_pane: Node = panel_instance.get("_right_pane")
		var vv_member: Node = panel_instance.get("_vault_view")
		check("F45: _vault_view is child of _right_pane",
			right_pane != null and vv_member != null and vv_member.get_parent() == right_pane,
			"parent mismatch")

		# Verify file_tree.document_selected is connected to vault_view.on_document_selected.
		var signal_connected: bool = false
		if ft_member != null and vv_member != null:
			var conns: Array = ft_member.get_signal_connection_list("document_selected")
			for c: Dictionary in conns:
				if c.get("callable", Callable()).get_object() == vv_member:
					signal_connected = true
					break
		check("F46: file_tree.document_selected connected to vault_view.on_document_selected",
			signal_connected,
			"signal not wired")

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
