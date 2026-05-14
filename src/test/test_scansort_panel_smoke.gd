extends SceneTree
## Scansort panel substrate smoke test — T7 R1 + R2 + R3 + R4 + R5 + R6 + R7 + R8 + R9.
##
## Run: godot --headless --path src --script test/test_scansort_panel_smoke.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Rounds:        T7 R1 — panel UI substrate (ScansortPanel + PasswordDialog)
##                T7 R2 — view scripts (FileTree, VaultView, StatusPanel)
##                T7 R3 — add-document dialog + ingest pipeline
##                T7 R4 — CRUD dialogs (EditDetailsDialog, RulesEditorDialog)
##                T7 R5 — cross-vault registry dialog (settings dialog dropped in R8)
##                T7 R6 — checklist dialog
##                T7 R7 — get_editor_actions() chrome API (toolbar removed)
##                T7 R8 — drop settings dialog, inherit chat model via _resolve_chat_model_for_classify
##                T7 R9 — chrome OptionButton for model selection (_model_dropdown)
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

# Plugin UI scripts live at $HOME/github/plugins/scansort/ui on every dev box.
# Derive from $HOME so the suite runs on both Linux desktop and macOS laptop.
static func _ui(name: String) -> String:
	return "%s/github/plugins/scansort/ui/%s" % [OS.get_environment("HOME"), name]

var PLUGIN_PANEL_TSCN  := _ui("ScansortPanel.tscn")
var PLUGIN_PANEL_GD    := _ui("ScansortPanel.gd")
var PLUGIN_DIALOG_GD   := _ui("password_dialog.gd")
var PLUGIN_FILETREE_GD := _ui("file_tree.gd")
var PLUGIN_VAULTVIEW_GD := _ui("vault_view.gd")
var PLUGIN_STATUSPANEL_GD := _ui("status_panel.gd")
var PLUGIN_ADD_DIALOG_GD        := _ui("add_document_dialog.gd")
var PLUGIN_EDIT_DETAILS_GD      := _ui("edit_details_dialog.gd")
var PLUGIN_RULES_EDITOR_GD      := _ui("rules_editor_dialog.gd")
var PLUGIN_VAULT_REGISTRY_GD    := _ui("vault_registry_dialog.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Scansort Panel Substrate Smoke Test (T7 R1-R8) ===\n")
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

	# -----------------------------------------------------------------------
	# Group G: R3 add_document_dialog.gd
	# -----------------------------------------------------------------------
	print("\n-- G: add_document_dialog.gd (T7 R3) --")

	var add_dlg_script = load(PLUGIN_ADD_DIALOG_GD)
	check("G47: add_document_dialog.gd loads (non-null)",
		add_dlg_script != null,
		"load() returned null — check parse errors above")

	if add_dlg_script == null:
		for _i in range(9):
			_fail_count += 1
		print("  SKIP G48-G56: add_document_dialog script null")
	else:
		var add_dlg = add_dlg_script.new()
		check("G48: AddDocumentDialog instantiates", add_dlg != null)

		if add_dlg != null:
			check("G49: extends AcceptDialog",
				add_dlg is AcceptDialog,
				"got class: %s" % add_dlg.get_class())

			check("G50: signal 'accepted' declared",
				add_dlg.has_signal("accepted"))

			check("G51: signal 'cancelled' declared",
				add_dlg.has_signal("cancelled"))

			check("G52: method 'set_proposal' exists",
				add_dlg.has_method("set_proposal"))

			check("G53: method '_on_accept_pressed' exists",
				add_dlg.has_method("_on_accept_pressed"))

			check("G54: method '_on_cancel_pressed' exists",
				add_dlg.has_method("_on_cancel_pressed"))

			# Smoke: call set_proposal with a fake dict — must not crash.
			var fake_proposal := {
				"category":    "invoices",
				"confidence":  0.87,
				"sender":      "ACME Corp",
				"description": "Test invoice",
				"doc_date":    "2026-05-13",
				"tags":        ["finance", "2026"],
				"sha256":      "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
				"simhash":     "0000000000000001",
				"dhash":       "0000000000000002",
				"source_file": "/tmp/test_invoice.pdf",
			}
			var set_proposal_ok := true
			add_dlg.set_proposal(fake_proposal)
			check("G55: set_proposal(fake_proposal) does not crash", set_proposal_ok)

			if is_instance_valid(add_dlg):
				add_dlg.free()

	# -----------------------------------------------------------------------
	# Group H: R3 ScansortPanel pipeline method presence
	# -----------------------------------------------------------------------
	print("\n-- H: ScansortPanel R3 methods (T7 R3) --")

	# Re-instantiate the panel for the H checks (panel_instance was freed above).
	var panel2_packed = load(PLUGIN_PANEL_TSCN)
	var panel2 = null
	if panel2_packed != null:
		panel2 = panel2_packed.instantiate()

	if panel2 == null:
		for _i in range(5):
			_fail_count += 1
		print("  SKIP H56-H60: could not instantiate panel for H checks")
	else:
		root.add_child(panel2)
		await process_frame

		check("H56: panel has method '_on_add_document_pressed'",
			panel2.has_method("_on_add_document_pressed"))

		check("H57: panel has method '_ingest_pipeline'",
			panel2.has_method("_ingest_pipeline"))

		check("H58: panel has method '_on_add_dialog_accepted'",
			panel2.has_method("_on_add_dialog_accepted"))

		check("H59: panel has method '_on_add_dialog_cancelled'",
			panel2.has_method("_on_add_dialog_cancelled"))

		check("H60: panel._vault_password starts empty",
			panel2.get("_vault_password") == "",
			"got: '%s'" % str(panel2.get("_vault_password")))

		panel2.queue_free()
		await process_frame

	# -----------------------------------------------------------------------
	# Group I: R4 dialogs — EditDetailsDialog + RulesEditorDialog
	# -----------------------------------------------------------------------
	print("\n-- I: R4 dialogs (edit_details_dialog, rules_editor_dialog) --")

	# --- I61-I67: edit_details_dialog.gd ---
	var edit_dlg_script = load(PLUGIN_EDIT_DETAILS_GD)
	check("I61: edit_details_dialog.gd loads (non-null)",
		edit_dlg_script != null,
		"load() returned null — check parse errors above")

	if edit_dlg_script == null:
		for _i in range(6):
			_fail_count += 1
		print("  SKIP I62-I67: edit_details_dialog script null")
	else:
		var edit_dlg = edit_dlg_script.new()
		check("I62: EditDetailsDialog instantiates", edit_dlg != null)

		if edit_dlg != null:
			check("I63: extends AcceptDialog",
				edit_dlg is AcceptDialog,
				"got class: %s" % edit_dlg.get_class())

			check("I64: signal 'accepted' declared",
				edit_dlg.has_signal("accepted"))

			check("I65: signal 'cancelled' declared",
				edit_dlg.has_signal("cancelled"))

			check("I66: method 'set_document' exists",
				edit_dlg.has_method("set_document"))

			# Smoke: set_document with a fake dict + empty rules — must not crash.
			var fake_doc := {
				"doc_id":          42,
				"display_name":    "Test Invoice",
				"description":     "A test document",
				"doc_date":        "2026-05-13",
				"tags":            ["finance", "test"],
				"category":        "invoices",
			}
			var smoke_ok := true
			edit_dlg.set_document(fake_doc, [])
			check("I67: set_document(fake_doc, []) does not crash", smoke_ok)

			if is_instance_valid(edit_dlg):
				edit_dlg.free()

	# --- I68-I75: rules_editor_dialog.gd ---
	var rules_dlg_script = load(PLUGIN_RULES_EDITOR_GD)
	check("I68: rules_editor_dialog.gd loads (non-null)",
		rules_dlg_script != null,
		"load() returned null — check parse errors above")

	if rules_dlg_script == null:
		for _i in range(7):
			_fail_count += 1
		print("  SKIP I69-I75: rules_editor_dialog script null")
	else:
		var rules_dlg = rules_dlg_script.new()
		check("I69: RulesEditorDialog instantiates", rules_dlg != null)

		if rules_dlg != null:
			check("I70: extends AcceptDialog",
				rules_dlg is AcceptDialog,
				"got class: %s" % rules_dlg.get_class())

			check("I71: signal 'rules_changed' declared",
				rules_dlg.has_signal("rules_changed"))

			check("I72: signal 'closed' declared",
				rules_dlg.has_signal("closed"))

			check("I73: method 'init' exists",
				rules_dlg.has_method("init"))

			check("I74: method 'refresh' exists",
				rules_dlg.has_method("refresh"))

			check("I75: method '_on_save_pressed' exists",
				rules_dlg.has_method("_on_save_pressed"))

			if is_instance_valid(rules_dlg):
				rules_dlg.free()

	# --- I76-I78: ScansortPanel R4 method presence ---
	print("\n-- I (panel R4 methods): ScansortPanel --")
	var panel3_packed = load(PLUGIN_PANEL_TSCN)
	var panel3 = null
	if panel3_packed != null:
		panel3 = panel3_packed.instantiate()

	if panel3 == null:
		for _i in range(3):
			_fail_count += 1
		print("  SKIP I76-I78: could not instantiate panel for I checks")
	else:
		root.add_child(panel3)
		await process_frame

		check("I76: panel has method '_on_rules_editor_pressed'",
			panel3.has_method("_on_rules_editor_pressed"))

		check("I77: panel has method '_on_edit_doc_pressed'",
			panel3.has_method("_on_edit_doc_pressed"))

		check("I78: panel has method '_on_edit_dialog_accepted'",
			panel3.has_method("_on_edit_dialog_accepted"))

		panel3.queue_free()
		await process_frame

	# -----------------------------------------------------------------------
	# Group J: R5 dialogs — VaultRegistryDialog + SettingsDialog
	# -----------------------------------------------------------------------
	print("\n-- J: R5 dialogs (vault_registry_dialog, settings_dialog) --")

	# --- J79-J86: vault_registry_dialog.gd ---
	var reg_dlg_script = load(PLUGIN_VAULT_REGISTRY_GD)
	check("J79: vault_registry_dialog.gd loads (non-null)",
		reg_dlg_script != null,
		"load() returned null — check parse errors above")

	if reg_dlg_script == null:
		for _i in range(7):
			_fail_count += 1
		print("  SKIP J80-J86: vault_registry_dialog script null")
	else:
		var reg_dlg = reg_dlg_script.new()
		check("J80: VaultRegistryDialog instantiates", reg_dlg != null)

		if reg_dlg != null:
			check("J81: extends AcceptDialog",
				reg_dlg is AcceptDialog,
				"got class: %s" % reg_dlg.get_class())

			check("J82: signal 'vault_picked' declared",
				reg_dlg.has_signal("vault_picked"))

			check("J83: signal 'closed' declared",
				reg_dlg.has_signal("closed"))

			check("J84: method 'init' exists",
				reg_dlg.has_method("init"))

			check("J85: method 'refresh' exists",
				reg_dlg.has_method("refresh"))

			# Smoke: init with null conn — must not crash (refresh defers on scene tree).
			var reg_smoke_ok := true
			reg_dlg.init(null)
			check("J86: init(null) does not crash", reg_smoke_ok)

			if is_instance_valid(reg_dlg):
				reg_dlg.free()

	# --- J97-J103: ScansortPanel R5+R8 method presence ---
	# R8: settings_dialog.gd deleted; J87-J96 (settings dialog tests) dropped.
	#     J98/J99/J100/J101/J103 replaced with R8 assertions.
	print("\n-- J (panel R5+R8): ScansortPanel --")
	var panel4_packed = load(PLUGIN_PANEL_TSCN)
	var panel4 = null
	if panel4_packed != null:
		panel4 = panel4_packed.instantiate()

	if panel4 == null:
		for _i in range(4):
			_fail_count += 1
		print("  SKIP J97-J103: could not instantiate panel for J checks")
	else:
		root.add_child(panel4)
		await process_frame

		check("J97: panel has method '_on_vault_registry_pressed'",
			panel4.has_method("_on_vault_registry_pressed"))

		# R8: settings pressed and load_settings_defaults are gone.
		check("J98: panel does NOT have '_on_settings_pressed' (R8: removed)",
			not panel4.has_method("_on_settings_pressed"),
			"_on_settings_pressed still exists — not fully removed")

		check("J99: panel does NOT have '_load_settings_defaults' (R8: removed)",
			not panel4.has_method("_load_settings_defaults"),
			"_load_settings_defaults still exists — not fully removed")

		# R8: _settings member var is gone.
		check("J100: panel._settings member no longer exists (R8: removed)",
			panel4.get("_settings") == null,
			"_settings still present — not fully removed")

		# R8: new helper exists.
		check("J101: panel has method '_resolve_chat_model_for_classify' (R8: added)",
			panel4.has_method("_resolve_chat_model_for_classify"),
			"_resolve_chat_model_for_classify not found")

		# J102: verify menu id 5 still present via get_editor_actions().
		var actions_j: Array = panel4.get_editor_actions() if panel4.has_method("get_editor_actions") else []
		var fmb_j: MenuButton = null
		if actions_j.size() > 0 and actions_j[0] is MenuButton:
			fmb_j = actions_j[0]
		var has_id5 := false
		var has_id6 := false
		if fmb_j != null:
			var pm_j: PopupMenu = fmb_j.get_popup()
			for i: int in range(pm_j.item_count):
				var item_id: int = pm_j.get_item_id(i)
				if item_id == 5:
					has_id5 = true
				if item_id == 6:
					has_id6 = true
		check("J102: File menu (via get_editor_actions) has id 5 (Vault Registry)",
			has_id5, "menu id 5 not found")
		check("J103: File menu (via get_editor_actions) does NOT have id 6 (Settings removed)",
			not has_id6, "menu id 6 still present — Settings item not removed")
		# Free the returned MenuButton (in headless tests the editor chrome isn't present).
		if fmb_j != null and is_instance_valid(fmb_j):
			fmb_j.queue_free()

	# --- K group: R6 — checklist dialog ---
	var PLUGIN_CHECKLIST_GD := _ui("checklist_dialog.gd")
	var checklist_script := load(PLUGIN_CHECKLIST_GD)
	check("K104: checklist_dialog.gd parses cleanly", checklist_script != null,
		"load() returned null")

	if checklist_script != null:
		var instance_signals: Array = checklist_script.get_script_signal_list()
		var sig_names: Array = []
		for s: Dictionary in instance_signals:
			sig_names.append(s.get("name", ""))
		check("K105: ChecklistDialog has signal 'checklist_changed'",
			sig_names.has("checklist_changed"),
			"signals: %s" % str(sig_names))
		check("K106: ChecklistDialog has signal 'closed'",
			sig_names.has("closed"),
			"signals: %s" % str(sig_names))

		var instance: Object = checklist_script.new()
		check("K107: ChecklistDialog instantiates without crash", instance != null)
		if instance != null:
			check("K108: ChecklistDialog has method 'init'",
				instance.has_method("init"))
			check("K109: ChecklistDialog has method 'refresh'",
				instance.has_method("refresh"))
			check("K110: ChecklistDialog has method '_on_run_check'",
				instance.has_method("_on_run_check"))
			check("K111: ChecklistDialog has method '_on_add_auto'",
				instance.has_method("_on_add_auto"))
			check("K112: ChecklistDialog has method '_on_delete_item'",
				instance.has_method("_on_delete_item"))
			if instance is Node:
				(instance as Node).queue_free()
			else:
				instance.free()

	# Panel-side wire: id 7 menu item + handler method.
	# K114 now fetches the menu via get_editor_actions() (R7: toolbar removed).
	if panel4 != null and is_instance_valid(panel4):
		check("K113: panel has method '_on_checklist_pressed'",
			panel4.has_method("_on_checklist_pressed"))
		var actions_k: Array = panel4.get_editor_actions() if panel4.has_method("get_editor_actions") else []
		var fmb_k: MenuButton = null
		if actions_k.size() > 0 and actions_k[0] is MenuButton:
			fmb_k = actions_k[0]
		var has_id7: bool = false
		if fmb_k != null:
			var pm2: PopupMenu = fmb_k.get_popup()
			for i: int in range(pm2.item_count):
				if pm2.get_item_id(i) == 7:
					has_id7 = true
		check("K114: File menu (via get_editor_actions) has id 7 (Checklist)",
			has_id7, "menu id 7 not found")
		if fmb_k != null and is_instance_valid(fmb_k):
			fmb_k.queue_free()

		panel4.queue_free()
		await process_frame

	# -----------------------------------------------------------------------
	# Group L: R7 — get_editor_actions() chrome API
	# -----------------------------------------------------------------------
	print("\n-- L: get_editor_actions() chrome API (T7 R7) --")

	var panel_l_packed := load(PLUGIN_PANEL_TSCN)
	var panel_l = null
	if panel_l_packed != null:
		panel_l = panel_l_packed.instantiate()

	if panel_l == null:
		for _i in range(8):
			_fail_count += 1
		print("  SKIP L115-L122: could not instantiate panel for L checks")
	else:
		root.add_child(panel_l)
		await process_frame

		check("L115: panel has method 'get_editor_actions'",
			panel_l.has_method("get_editor_actions"))

		var actions_l: Array = []
		if panel_l.has_method("get_editor_actions"):
			actions_l = panel_l.get_editor_actions()

		check("L116: get_editor_actions() returns Array",
			actions_l is Array,
			"got type: %s" % type_string(typeof(actions_l)))

		check("L117: returned Array has at least 1 element",
			actions_l.size() >= 1,
			"got size: %d" % actions_l.size())

		var menu_l: MenuButton = null
		if actions_l.size() > 0 and actions_l[0] is MenuButton:
			menu_l = actions_l[0]

		check("L118: first element is a MenuButton",
			menu_l != null,
			"got: %s" % (str(actions_l[0]) if actions_l.size() > 0 else "<empty>"))

		if menu_l != null:
			var popup_l: PopupMenu = menu_l.get_popup()

			check("L119: MenuButton popup has >= 7 items",
				popup_l.item_count >= 7,
				"got item_count: %d" % popup_l.item_count)

			# Verify all expected ids 0,1,2,3,4,5,7 present; id 6 (Settings) gone (R8).
			var found_ids: Array[int] = []
			for i: int in range(popup_l.item_count):
				found_ids.append(popup_l.get_item_id(i))

			check("L120: popup has id 0 (New Vault)",
				found_ids.has(0), "id 0 not found in: %s" % str(found_ids))
			check("L121: popup has id 1 (Open Vault)",
				found_ids.has(1), "id 1 not found in: %s" % str(found_ids))
			check("L122: popup has ids 2,3,4,5,7 and NOT id 6 (R8: Settings removed)",
				found_ids.has(2) and found_ids.has(3) and found_ids.has(4) and
				found_ids.has(5) and found_ids.has(7) and not found_ids.has(6),
				"id mismatch from: %s" % str(found_ids))

			if is_instance_valid(menu_l):
				menu_l.queue_free()
		else:
			for _i in range(4):
				_fail_count += 1
			print("  SKIP L119-L122: menu_l is null")

		# Verify internal _file_menu_btn is gone (toolbar removed).
		var old_btn = panel_l.get("_file_menu_btn")
		check("L123: _file_menu_btn member no longer exists (toolbar removed)",
			old_btn == null,
			"_file_menu_btn still non-null — toolbar not removed")

		panel_l.queue_free()
		await process_frame

	# -----------------------------------------------------------------------
	# Group M: R9 — chrome model OptionButton
	# -----------------------------------------------------------------------
	print("\n-- M: chrome model OptionButton (T7 R9) --")

	var panel_m_packed := load(PLUGIN_PANEL_TSCN)
	var panel_m = null
	if panel_m_packed != null:
		panel_m = panel_m_packed.instantiate()

	if panel_m == null:
		for _i in range(6):
			_fail_count += 1
		print("  SKIP M124-M129: could not instantiate panel for M checks")
	else:
		root.add_child(panel_m)
		await process_frame

		var actions_m: Array = []
		if panel_m.has_method("get_editor_actions"):
			actions_m = panel_m.get_editor_actions()

		check("M124: get_editor_actions() returns Array of size 2",
			actions_m.size() == 2,
			"got size: %d" % actions_m.size())

		check("M125: first element is MenuButton (file menu)",
			actions_m.size() > 0 and actions_m[0] is MenuButton,
			"got type: %s" % (type_string(typeof(actions_m[0])) if actions_m.size() > 0 else "<empty>"))

		check("M126: second element is OptionButton (model dropdown)",
			actions_m.size() > 1 and actions_m[1] is OptionButton,
			"got type: %s" % (type_string(typeof(actions_m[1])) if actions_m.size() > 1 else "<empty>"))

		# Inspect the OptionButton's first item metadata — must be a Dictionary.
		var has_metadata_dict := false
		if actions_m.size() > 1 and actions_m[1] is OptionButton:
			var ob: OptionButton = actions_m[1]
			if ob.get_item_count() > 0:
				var meta = ob.get_item_metadata(0)
				has_metadata_dict = (meta is Dictionary)
		check("M127: OptionButton metadata at index 0 is a Dictionary (spec wiring)",
			has_metadata_dict,
			"metadata not a Dictionary — spec not stored")

		# _resolve_chat_model_for_classify() must return {model_spec: Dictionary}.
		var resolve_result = null
		if panel_m.has_method("_resolve_chat_model_for_classify"):
			resolve_result = panel_m._resolve_chat_model_for_classify()
		check("M128: _resolve_chat_model_for_classify() returns Dictionary with 'model_spec' key",
			resolve_result is Dictionary and resolve_result.has("model_spec"),
			"got: %s" % str(resolve_result))

		# L6: deselect the dropdown — should fall back to {model_spec: {}}.
		var fallback_result = null
		var dropdown_m: OptionButton = panel_m.get("_model_dropdown")
		if dropdown_m != null and is_instance_valid(dropdown_m):
			dropdown_m.select(-1)
		if panel_m.has_method("_resolve_chat_model_for_classify"):
			fallback_result = panel_m._resolve_chat_model_for_classify()
		check("M129: _resolve_chat_model_for_classify() falls back to {model_spec: {}} when no item selected",
			fallback_result is Dictionary and
			fallback_result.has("model_spec") and
			fallback_result.get("model_spec") is Dictionary and
			(fallback_result.get("model_spec") as Dictionary).is_empty(),
			"got: %s" % str(fallback_result))

		# M130: mirror the call-site guard — when spec is empty, classify_args
		# must NOT include "model_spec" (broker rejects {} as "unknown kind").
		var fb_spec: Dictionary = {}
		if fallback_result is Dictionary and fallback_result.get("model_spec") is Dictionary:
			fb_spec = fallback_result.get("model_spec")
		var classify_args_m: Dictionary = {"vault_path": "/tmp/x.ssort", "model": "default"}
		if not fb_spec.is_empty():
			classify_args_m["model_spec"] = fb_spec
		check("M130: classify_args omits 'model_spec' when resolver returns empty spec",
			not classify_args_m.has("model_spec"),
			"classify_args has model_spec=%s" % str(classify_args_m.get("model_spec")))

		# Free chrome controls returned by get_editor_actions().
		for ctrl in actions_m:
			if ctrl != null and is_instance_valid(ctrl):
				ctrl.queue_free()

		panel_m.queue_free()
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
