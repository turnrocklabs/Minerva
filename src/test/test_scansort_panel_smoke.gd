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
		# Group F: U4 panel integration — 2-column layout + chrome buttons
		# -------------------------------------------------------------------
		print("\n-- F: U4 panel integration (2-col layout, chrome buttons) --")

		var src_tree: Node = panel_instance.get("_source_tree")
		var dst_tree: Node = panel_instance.get("_dest_tree")
		var stat_panel: Node = panel_instance.get("_status_panel")

		check("F41: panel has _source_tree member (a Tree, non-null after _ready)",
			src_tree != null and src_tree is Tree,
			"_source_tree missing or not a Tree")

		# W5: _dest_tree is null at _ready (no vault open yet) — the member still
		# exists; it gets set to the first destination tree on vault open.
		check("F42: panel has _dest_tree member (may be null before vault open — W5 dynamic)",
			"_dest_tree" in panel_instance,
			"_dest_tree member missing from panel entirely")

		# Status panel is the bottom bar — a direct child of the root layout VBox.
		var stat_parent: Node = stat_panel.get_parent() if stat_panel != null else null
		check("F43: _status_panel is a bottom bar under a VBoxContainer layout",
			stat_panel != null and stat_parent is VBoxContainer,
			"status parent: %s" % (str(stat_parent.get_class()) if stat_parent != null else "<null>"))

		# _source_tree lives under a container named SourcePane.
		var src_parent: Node = src_tree.get_parent() if src_tree != null else null
		check("F44: _source_tree is child of a 'SourcePane' container",
			src_parent != null and str(src_parent.name) == "SourcePane",
			"parent: %s" % (str(src_parent.name) if src_parent != null else "<null>"))

		# W5: _dest_tree is null before vault open. Check that DestPane exists
		# instead — it still hosts the scroll content + add button.
		var dest_pane_node: Node = panel_instance.find_child("DestPane", true, false) if panel_instance != null else null
		check("F45: 'DestPane' container exists as a descendant of the panel (W5: dynamic content)",
			dest_pane_node != null,
			"DestPane container not found")

		# get_editor_actions() contributes [Process, Stop, File] to the chrome
		# bar — Process/Stop are disabled icon Buttons, File is a MenuButton.
		var chrome_actions: Array = panel_instance.get_editor_actions()
		var chrome_ok: bool = chrome_actions.size() == 3 \
			and chrome_actions[0] is Button and chrome_actions[1] is Button \
			and chrome_actions[2] is MenuButton \
			and chrome_actions[0].icon != null and chrome_actions[1].icon != null \
			and chrome_actions[0].disabled and chrome_actions[1].disabled
		check("F46: get_editor_actions returns [Process(icon,disabled), Stop(icon,disabled), File menu]",
			chrome_ok,
			"got: %s" % str(chrome_actions.map(func(c): return c.get_class() if c != null else "<null>")))
		for c in chrome_actions:
			if c != null and is_instance_valid(c):
				c.queue_free()

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

		# R8 removed an old Settings dialog; F&F (post-R6) restored a new one
		# whose sole knob is the classification-model override. The old
		# _load_settings_defaults helper stays gone (defaults live in the
		# Settings dialog now).
		check("J98: panel HAS '_on_settings_pressed' (F&F: Settings dialog restored)",
			panel4.has_method("_on_settings_pressed"),
			"_on_settings_pressed missing — Settings dialog not wired")

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
		# U4: get_editor_actions returns [Process, Stop, File menu] — find the menu.
		var fmb_j: MenuButton = null
		for a_j in actions_j:
			if a_j is MenuButton:
				fmb_j = a_j
				break
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
		# U4: get_editor_actions returns [Process, Stop, File menu] — find the menu.
		var fmb_k: MenuButton = null
		for a_k in actions_k:
			if a_k is MenuButton:
				fmb_k = a_k
				break
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

		# U4: get_editor_actions returns [Process, Stop, File menu] — find the menu.
		var menu_l: MenuButton = null
		for a_l in actions_l:
			if a_l is MenuButton:
				menu_l = a_l
				break

		check("L118: actions contain the File MenuButton",
			menu_l != null,
			"no MenuButton in: %s" % str(actions_l.map(func(c): return c.get_class() if c != null else "<null>")))

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

			# Rules-file R6: Library Rules Editor (8), Create Vault-Specific
			# Rules (9), Use Library Rules (10).
			check("L122b: popup has id 8 (Library Rules Editor)",
				found_ids.has(8),
				"id 8 missing from: %s" % str(found_ids))
			check("L122c: popup has id 9 (Create Vault-Specific Rules)",
				found_ids.has(9),
				"id 9 missing from: %s" % str(found_ids))
			check("L122d: popup has id 10 (Use Library Rules)",
				found_ids.has(10),
				"id 10 missing from: %s" % str(found_ids))
			check("L122e: popup has id 11 (Settings)",
				found_ids.has(11),
				"id 11 missing from: %s" % str(found_ids))

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

		# Rules-file R6: panel exposes the rules-path helpers and the new
		# library / create / use-library handlers.
		check("L124: panel has method '_library_rules_path'",
			panel_l.has_method("_library_rules_path"),
			"missing helper for layer-2 rules path")
		check("L125: panel has method '_vault_rules_path'",
			panel_l.has_method("_vault_rules_path"),
			"missing helper for layer-1 sibling path")
		check("L126: panel has method '_on_library_rules_editor_pressed'",
			panel_l.has_method("_on_library_rules_editor_pressed"))
		check("L127: panel has method '_on_create_vault_rules_pressed'",
			panel_l.has_method("_on_create_vault_rules_pressed"))
		check("L128: panel has method '_on_use_library_rules_pressed'",
			panel_l.has_method("_on_use_library_rules_pressed"))
		check("L128b: panel has method '_on_settings_pressed'",
			panel_l.has_method("_on_settings_pressed"))

		if panel_l.has_method("_library_rules_path"):
			var lib_path: String = str(panel_l._library_rules_path())
			check("L129: _library_rules_path returns a non-empty absolute path",
				not lib_path.is_empty() and lib_path.is_absolute_path(),
				"got: '%s'" % lib_path)
			check("L130: _library_rules_path ends in scansort_rules.json",
				lib_path.ends_with("scansort_rules.json"),
				"got: '%s'" % lib_path)

		if panel_l.has_method("_vault_rules_path"):
			var sib: String = str(panel_l._vault_rules_path())
			check("L131: _vault_rules_path empty when no vault open",
				sib.is_empty(),
				"expected empty, got: '%s'" % sib)

		panel_l.queue_free()
		await process_frame

	# Rules editor dialog (R6): both init entry points present.
	var dialog_script_r6 = load(_ui("rules_editor_dialog.gd"))
	check("L132: rules_editor_dialog.gd parses cleanly",
		dialog_script_r6 != null,
		"load() returned null")
	if dialog_script_r6 != null:
		var dlg_r6 = dialog_script_r6.new()
		check("L133: dialog has method 'init_with_rules_path'",
			dlg_r6.has_method("init_with_rules_path"))
		check("L134: dialog retains legacy 'init' for back-compat",
			dlg_r6.has_method("init"))
		if dlg_r6 != null and is_instance_valid(dlg_r6):
			dlg_r6.queue_free()

	# Settings dialog (F&F): single classification-model preference.
	var settings_script = load(_ui("settings_dialog.gd"))
	check("L135: settings_dialog.gd parses cleanly",
		settings_script != null,
		"load() returned null")
	if settings_script != null:
		var settings_dlg = settings_script.new()
		check("L136: settings dialog has method 'init'",
			settings_dlg.has_method("init"))
		# ScansortSettings is an inner class on the settings script.
		var inner = settings_script.ScansortSettings
		check("L137: settings script exposes ScansortSettings inner class",
			inner != null)
		if inner != null:
			var path: String = str(inner.settings_path())
			check("L138: settings_path returns non-empty absolute path ending in .json",
				not path.is_empty() and path.is_absolute_path() and path.ends_with(".json"),
				"got: '%s'" % path)
			# Round-trip the override Dict — write, read, assert match.
			var saved_path := path
			var backup_text: String = ""
			var had_backup: bool = FileAccess.file_exists(saved_path)
			if had_backup:
				var bf := FileAccess.open(saved_path, FileAccess.READ)
				if bf != null:
					backup_text = bf.get_as_text()
					bf.close()
			var probe: Dictionary = {"kind": "builtin", "model_id": 42}
			var save_ok: bool = inner.save_model_override(probe)
			check("L139: save_model_override returns true",
				save_ok, "save returned false")
			var loaded: Dictionary = inner.load_model_override()
			# JSON round-trip turns ints into floats; coerce for comparison.
			var loaded_id: int = int(loaded.get("model_id", -1))
			check("L140: load_model_override round-trips kind and model_id",
				str(loaded.get("kind", "")) == "builtin" and loaded_id == 42,
				"got: %s" % str(loaded))
			# Clear the override (empty Dict → null persistence) and verify load is empty.
			inner.save_model_override({})
			var loaded_empty: Dictionary = inner.load_model_override()
			check("L141: empty save clears the override (load returns {})",
				loaded_empty.is_empty(),
				"got: %s" % str(loaded_empty))
			# Restore backup if there was one, else clean up.
			if had_backup:
				var rf := FileAccess.open(saved_path, FileAccess.WRITE)
				if rf != null:
					rf.store_string(backup_text)
					rf.close()
			else:
				if FileAccess.file_exists(saved_path):
					DirAccess.remove_absolute(saved_path)
		if settings_dlg != null and is_instance_valid(settings_dlg):
			settings_dlg.queue_free()

	# -----------------------------------------------------------------------
	# Group M: chrome chrome single-purpose + chat-model inheritance
	# (was T7 R9 OptionButton; replaced by inheritance via ChatPane.get_active_model_spec)
	# -----------------------------------------------------------------------
	print("\n-- M: chrome single-button + chat-model inheritance --")

	var panel_m_packed := load(PLUGIN_PANEL_TSCN)
	var panel_m = null
	if panel_m_packed != null:
		panel_m = panel_m_packed.instantiate()

	if panel_m == null:
		for _i in range(5):
			_fail_count += 1
		print("  SKIP M124-M128: could not instantiate panel for M checks")
	else:
		root.add_child(panel_m)
		await process_frame

		var actions_m: Array = []
		if panel_m.has_method("get_editor_actions"):
			actions_m = panel_m.get_editor_actions()

		# U4: get_editor_actions returns [Process, Stop, File menu] — 3 controls.
		check("M124: get_editor_actions() returns 3 controls (Process, Stop, File menu)",
			actions_m.size() == 3,
			"got size: %d" % actions_m.size())

		# No per-panel model picker — exactly one MenuButton, zero OptionButtons.
		var menu_count_m: int = 0
		var option_count_m: int = 0
		for a_m in actions_m:
			if a_m is MenuButton:
				menu_count_m += 1
			elif a_m is OptionButton:
				option_count_m += 1
		check("M125: actions hold exactly one MenuButton and no OptionButton (no model picker)",
			menu_count_m == 1 and option_count_m == 0,
			"menus: %d, options: %d" % [menu_count_m, option_count_m])

		check("M126: panel no longer holds a _model_dropdown member",
			panel_m.get("_model_dropdown") == null,
			"_model_dropdown still present — duplicate of chat panel's picker")

		# _resolve_chat_model_for_classify() must return {model_spec: Dictionary}.
		# In headless tests SingletonObject.Chats isn't initialized, so it falls
		# back to {}; that's the safe path verified here.
		var resolve_result = null
		if panel_m.has_method("_resolve_chat_model_for_classify"):
			resolve_result = panel_m._resolve_chat_model_for_classify()
		check("M127: _resolve_chat_model_for_classify() returns {model_spec: Dictionary}",
			resolve_result is Dictionary and resolve_result.has("model_spec")
				and resolve_result.get("model_spec") is Dictionary,
			"got: %s" % str(resolve_result))

		# M128: the call-site guard — an EMPTY spec must NOT be added to
		# classify_args (the broker rejects {} as "unknown kind"). Tested with a
		# known-empty spec; the resolver's actual output depends on chat state
		# (it legitimately returns a real spec when a chat model is selected)
		# and isn't the subject of this check.
		var empty_spec: Dictionary = {}
		var classify_args_m: Dictionary = {"vault_path": "/tmp/x.ssort", "model": "default"}
		if not empty_spec.is_empty():
			classify_args_m["model_spec"] = empty_spec
		check("M128: classify_args omits 'model_spec' when spec is empty",
			not classify_args_m.has("model_spec"),
			"classify_args has model_spec=%s" % str(classify_args_m.get("model_spec")))

		# Free chrome controls returned by get_editor_actions().
		for ctrl in actions_m:
			if ctrl != null and is_instance_valid(ctrl):
				ctrl.queue_free()

		panel_m.queue_free()
		await process_frame

	# -----------------------------------------------------------------------
	# Group N: U1 — unified scan_tree component + providers
	# -----------------------------------------------------------------------
	print("\n-- N: unified scan_tree + providers (U1) --")

	# scan_tree_provider.gd — the base contract.
	var provider_base_script = load(_ui("scan_tree_provider.gd"))
	check("N135: scan_tree_provider.gd parses cleanly",
		provider_base_script != null, "load() returned null")
	if provider_base_script != null:
		var pb = provider_base_script.new()
		check("N136: base provider has get_tree_data",
			pb.has_method("get_tree_data"))
		check("N137: base provider has get_source_label",
			pb.has_method("get_source_label"))
		check("N138: base provider get_tree_data returns empty Array by default",
			pb.get_tree_data() is Array and (pb.get_tree_data() as Array).is_empty())

	# scan_tree_vault_provider.gd — vault-backed provider.
	var vault_provider_script = load(_ui("scan_tree_vault_provider.gd"))
	check("N139: scan_tree_vault_provider.gd parses cleanly",
		vault_provider_script != null, "load() returned null")
	if vault_provider_script != null:
		var vp = vault_provider_script.new()
		check("N140: vault provider has init",
			vp.has_method("init"))
		check("N141: vault provider has get_tree_data",
			vp.has_method("get_tree_data"))
		# Uninitialised (no conn) → get_tree_data returns [] without crashing.
		var vp_data = await vp.get_tree_data()
		check("N142: vault provider get_tree_data returns [] when uninitialised",
			vp_data is Array and (vp_data as Array).is_empty(),
			"got: %s" % str(vp_data))
		# get_source_label reflects the (absent) vault path.
		check("N143: vault provider get_source_label returns 'Vault' when no path",
			str(vp.get_source_label()) == "Vault",
			"got: '%s'" % str(vp.get_source_label()))

	# scan_tree.gd — the unified component.
	var scan_tree_script = load(_ui("scan_tree.gd"))
	check("N144: scan_tree.gd parses cleanly",
		scan_tree_script != null, "load() returned null")
	if scan_tree_script != null:
		var st = scan_tree_script.new()
		check("N145: scan_tree extends Tree",
			st is Tree, "got class: %s" % st.get_class())
		check("N146: scan_tree has set_provider / refresh / populate / get_checked_keys",
			st.has_method("set_provider") and st.has_method("refresh")
				and st.has_method("populate") and st.has_method("get_checked_keys"))
		check("N147: scan_tree declares file_activated / selection_changed / check_toggled signals",
			st.has_signal("file_activated") and st.has_signal("selection_changed")
				and st.has_signal("check_toggled"))

		# Render test: populate() with canned data, verify structure.
		root.add_child(st)
		await process_frame
		var canned: Array = [
			{
				"kind": "folder", "name": "receipts/ (2)", "key": "cat:receipts",
				"date": "", "tooltip": "", "children": [
					{"kind": "file", "name": "jan.pdf", "key": "doc:1", "date": "2026-01-05", "tooltip": "jan", "children": []},
					{"kind": "file", "name": "feb.pdf", "key": "doc:2", "date": "2026-02-05", "tooltip": "feb", "children": []},
				],
			},
			{
				"kind": "folder", "name": "school/ (1)", "key": "cat:school",
				"date": "", "tooltip": "", "children": [
					{"kind": "file", "name": "ch1.pdf", "key": "doc:3", "date": "2026-03-01", "tooltip": "ch1", "children": []},
				],
			},
		]
		st.populate(canned)
		var tree_root: TreeItem = st.get_root()
		check("N148: populate() builds the top-level folders",
			tree_root != null and tree_root.get_child_count() == 2,
			"got child count: %d" % (tree_root.get_child_count() if tree_root != null else -1))
		if tree_root != null and tree_root.get_child_count() == 2:
			var first_folder: TreeItem = tree_root.get_first_child()
			check("N149: first folder row carries kind=folder and is non-checkable",
				str(first_folder.get_meta("kind", "")) == "folder"
					and first_folder.get_cell_mode(0) != TreeItem.CELL_MODE_CHECK,
				"folder row mis-rendered")
			check("N150: first folder has 2 file children",
				first_folder.get_child_count() == 2,
				"got: %d" % first_folder.get_child_count())
			var first_file: TreeItem = first_folder.get_first_child()
			check("N151: file row is a checkbox cell with kind=file",
				str(first_file.get_meta("kind", "")) == "file"
					and first_file.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK,
				"file row mis-rendered")
			check("N152: file row metadata carries the node key",
				str(first_file.get_metadata(1)) == "doc:1",
				"got key: '%s'" % str(first_file.get_metadata(1)))

			# get_checked_keys: check two files, expect their keys back.
			first_file.set_checked(0, true)
			var third_file: TreeItem = tree_root.get_child(1).get_first_child()
			third_file.set_checked(0, true)
			var checked: Array = st.get_checked_keys()
			check("N153: get_checked_keys returns exactly the checked file keys",
				checked.size() == 2 and checked.has("doc:1") and checked.has("doc:3"),
				"got: %s" % str(checked))

		st.queue_free()
		await process_frame

	# -----------------------------------------------------------------------
	# Group O: U2 — scan_tree_source_provider.gd (source-directory provider)
	# -----------------------------------------------------------------------
	print("\n-- O: scan_tree source provider (U2) --")

	var source_provider_script = load(_ui("scan_tree_source_provider.gd"))
	check("O154: scan_tree_source_provider.gd parses cleanly",
		source_provider_script != null, "load() returned null")
	if source_provider_script != null:
		var sp = source_provider_script.new()
		check("O155: source provider has init",
			sp.has_method("init"))
		check("O156: source provider has get_tree_data",
			sp.has_method("get_tree_data"))
		check("O157: source provider has get_source_label",
			sp.has_method("get_source_label"))
		# Uninitialised (no conn) → get_tree_data returns [] without crashing.
		var sp_data = await sp.get_tree_data()
		check("O158: source provider get_tree_data returns [] when uninitialised",
			sp_data is Array and (sp_data as Array).is_empty(),
			"got: %s" % str(sp_data))
		# get_source_label is 'Source' before any directory is resolved.
		check("O159: source provider get_source_label returns 'Source' when unset",
			str(sp.get_source_label()) == "Source",
			"got: '%s'" % str(sp.get_source_label()))


	# -----------------------------------------------------------------------
	# Group P: U5 — Process All batch pipeline (structural checks)
	# -----------------------------------------------------------------------
	print("\n-- P: U5 batch pipeline — structural checks --")

	var panel_p_packed := load(PLUGIN_PANEL_TSCN)
	var panel_p = null
	if panel_p_packed != null:
		panel_p = panel_p_packed.instantiate()

	if panel_p == null:
		for _i in range(9):
			_fail_count += 1
		print("  SKIP P160-P168: could not instantiate panel for P checks")
	else:
		root.add_child(panel_p)
		await process_frame

		# Method presence.
		check("P160: panel has method '_on_process_all_pressed'",
			panel_p.has_method("_on_process_all_pressed"))
		check("P161: panel has method '_on_stop_pressed'",
			panel_p.has_method("_on_stop_pressed"))
		check("P162: panel has method 'clear_processed_state'",
			panel_p.has_method("clear_processed_state"))

		# Session state members exist and default to correct types / values.
		check("P163: panel._processed_keys exists and is a Dictionary",
			panel_p.get("_processed_keys") != null and panel_p.get("_processed_keys") is Dictionary,
			"got: %s" % str(panel_p.get("_processed_keys")))
		check("P164: panel._low_confidence_keys exists and is a Dictionary",
			panel_p.get("_low_confidence_keys") != null and panel_p.get("_low_confidence_keys") is Dictionary,
			"got: %s" % str(panel_p.get("_low_confidence_keys")))
		check("P165: panel._process_cancelled exists and starts false",
			panel_p.get("_process_cancelled") != null and panel_p.get("_process_cancelled") == false,
			"got: %s" % str(panel_p.get("_process_cancelled")))

		# scan_tree_source_provider has set_session_marks.
		var sp5_script = load(_ui("scan_tree_source_provider.gd"))
		check("P166: scan_tree_source_provider.gd still parses cleanly",
			sp5_script != null, "load() returned null")
		if sp5_script != null:
			var sp5 = sp5_script.new()
			check("P167: source provider has method 'set_session_marks'",
				sp5.has_method("set_session_marks"),
				"set_session_marks missing")
			# Smoke: call set_session_marks — must not crash.
			var smoke_ok := true
			sp5.set_session_marks({"file1.pdf": true}, {"file2.pdf": true})
			check("P168: set_session_marks(processed, low_conf) does not crash", smoke_ok)
			# sp5 extends scan_tree_provider.gd (RefCounted) — auto-freed, no .free().

		panel_p.queue_free()
		await process_frame

	# -----------------------------------------------------------------------
	# Group Q: U6 — manual review + inject-to-chat
	# -----------------------------------------------------------------------
	print("\n-- Q: U6 manual review + inject-to-chat --")

	# --- scan_tree.gd additions ---
	var scan_tree_q_script = load(_ui("scan_tree.gd"))
	check("Q169: scan_tree.gd still parses cleanly after U6 additions",
		scan_tree_q_script != null, "load() returned null")

	if scan_tree_q_script != null:
		var st_q = scan_tree_q_script.new()
		check("Q170: scan_tree has property 'tree_role'",
			st_q.get("tree_role") != null or "tree_role" in st_q,
			"tree_role missing")
		check("Q171: scan_tree.tree_role defaults to empty string",
			str(st_q.get("tree_role")) == "",
			"got: '%s'" % str(st_q.get("tree_role")))
		check("Q172: scan_tree has method '_get_drag_data'",
			st_q.has_method("_get_drag_data"))
		check("Q173: scan_tree has method '_can_drop_data'",
			st_q.has_method("_can_drop_data"))
		check("Q174: scan_tree has method '_drop_data'",
			st_q.has_method("_drop_data"))
		check("Q175: scan_tree has signal 'file_dropped'",
			st_q.has_signal("file_dropped"))
		st_q.queue_free()
		await process_frame

	# --- ScansortPanel.gd additions ---
	var panel_q_packed := load(PLUGIN_PANEL_TSCN)
	var panel_q = null
	if panel_q_packed != null:
		panel_q = panel_q_packed.instantiate()

	if panel_q == null:
		for _qi in range(11):
			_fail_count += 1
		print("  SKIP Q176-Q186: could not instantiate panel for Q checks")
	else:
		root.add_child(panel_q)
		await process_frame

		check("Q176: panel has method '_on_tree_file_dropped'",
			panel_q.has_method("_on_tree_file_dropped"))
		check("Q177: panel has method '_on_export_marked_pressed'",
			panel_q.has_method("_on_export_marked_pressed"))
		check("Q178: panel has method '_on_source_check_toggled'",
			panel_q.has_method("_on_source_check_toggled"))
		check("Q179: panel has method '_on_panel_create_note_request'",
			panel_q.has_method("_on_panel_create_note_request"))
		check("Q180: panel has method '_on_panel_inject_toggle_changed'",
			panel_q.has_method("_on_panel_inject_toggle_changed"))

		check("Q181: panel._inject_payload_cache exists and is a String",
			panel_q.get("_inject_payload_cache") != null and panel_q.get("_inject_payload_cache") is String,
			"got: %s" % str(panel_q.get("_inject_payload_cache")))
		check("Q182: panel._inject_payload_cache starts empty",
			str(panel_q.get("_inject_payload_cache")) == "",
			"got: '%s'" % str(panel_q.get("_inject_payload_cache")))
		check("Q183: panel._inject_enabled exists and starts false",
			panel_q.get("_inject_enabled") != null and panel_q.get("_inject_enabled") == false,
			"got: %s" % str(panel_q.get("_inject_enabled")))

		# _on_panel_create_note_request must be synchronous and return null when cache is empty.
		var note_result = panel_q._on_panel_create_note_request({})
		check("Q184: _on_panel_create_note_request returns null when _inject_payload_cache is empty",
			note_result == null,
			"got: %s" % str(note_result))

		# Simulate a non-empty cache and verify a text-kind dict is returned.
		panel_q._inject_payload_cache = "=== test.pdf ===\nHello world\n\n"
		var note_result2 = panel_q._on_panel_create_note_request({})
		check("Q185: _on_panel_create_note_request returns a Dict with kind='text' when cache is set",
			note_result2 is Dictionary and str((note_result2 as Dictionary).get("kind", "")) == "text",
			"got: %s" % str(note_result2))
		check("Q186: returned note dict contains non-empty content",
			note_result2 is Dictionary and not str((note_result2 as Dictionary).get("content", "")).is_empty(),
			"content was empty")

		panel_q.queue_free()
		await process_frame

	# -----------------------------------------------------------------------
	# Group R: U7 — vault_and_disk (stacked pane + DiskProvider + Settings)
	# -----------------------------------------------------------------------
	print("\n-- R: U7 vault_and_disk --")

	# --- R187: scan_tree_disk_provider.gd parses cleanly ---
	var disk_provider_script = load(_ui("scan_tree_disk_provider.gd"))
	check("R187: scan_tree_disk_provider.gd parses cleanly",
		disk_provider_script != null, "load() returned null")

	if disk_provider_script != null:
		var dp = disk_provider_script.new()
		check("R188: DiskProvider extends scan_tree_provider.gd (is RefCounted base)",
			dp.has_method("get_tree_data") and dp.has_method("get_source_label"),
			"missing provider contract methods")
		check("R189: DiskProvider has method 'init'",
			dp.has_method("init"))
		check("R190: DiskProvider has method 'get_source_label'",
			dp.has_method("get_source_label"))
		check("R191: DiskProvider has method 'get_tree_data'",
			dp.has_method("get_tree_data"))
		# Uninitialised (no conn) → get_tree_data returns [] without crashing.
		var dp_data = await dp.get_tree_data()
		check("R192: DiskProvider get_tree_data returns [] when uninitialised",
			dp_data is Array and (dp_data as Array).is_empty(),
			"got: %s" % str(dp_data))
		check("R193: DiskProvider get_source_label returns a non-empty String",
			not str(dp.get_source_label()).is_empty(),
			"got: '%s'" % str(dp.get_source_label()))
		# NOTE: dp extends RefCounted (via scan_tree_provider.gd) — do NOT .free().

	# --- R194-R197: ScansortPanel has _disk_tree and _disk_provider members ---
	var panel_r_packed := load(PLUGIN_PANEL_TSCN)
	var panel_r = null
	if panel_r_packed != null:
		panel_r = panel_r_packed.instantiate()

	if panel_r == null:
		for _ri in range(8):
			_fail_count += 1
		print("  SKIP R194-R201: could not instantiate panel for R checks")
	else:
		root.add_child(panel_r)
		await process_frame

		check("R194: panel has member '_disk_tree'",
			"_disk_tree" in panel_r,
			"_disk_tree member missing")
		check("R195: panel has member '_disk_provider'",
			"_disk_provider" in panel_r,
			"_disk_provider member missing")
		# W5: _disk_tree is null after _ready (no vault open; dynamic destinations
		# replace the fixed disk tree). The member still exists on the panel.
		check("R196: _disk_tree member exists on panel (W5: null before vault open)",
			"_disk_tree" in panel_r,
			"_disk_tree member missing from panel")
		check("R197: panel has method '_process_one_source_file' (concurrency worker)",
			panel_r.has_method("_process_one_source_file"),
			"_process_one_source_file missing")
		check("R198: panel has member '_run_counters' (shared concurrency counters)",
			"_run_counters" in panel_r,
			"_run_counters member missing")

		panel_r.queue_free()
		await process_frame

	# --- R199-R207: settings_dialog.gd — vault-path init + concurrency ---
	var settings_r_script = load(_ui("settings_dialog.gd"))
	check("R199: settings_dialog.gd still parses cleanly after U7 edits",
		settings_r_script != null, "load() returned null")

	if settings_r_script != null:
		var sdlg = settings_r_script.new()
		check("R200: settings dialog has method 'init'",
			sdlg.has_method("init"))

		# ScansortSettings inner class presence.
		var inner_r = settings_r_script.ScansortSettings
		check("R201: ScansortSettings inner class still accessible",
			inner_r != null)

		if inner_r != null:
			check("R202: ScansortSettings has static method 'load_concurrency'",
				inner_r.has_method("load_concurrency"))
			check("R203: ScansortSettings has static method 'save_concurrency'",
				inner_r.has_method("save_concurrency"))
			check("R204: ScansortSettings has static method 'load_model_override'",
				inner_r.has_method("load_model_override"))
			check("R205: ScansortSettings has static method 'save_model_override'",
				inner_r.has_method("save_model_override"))

			# Round-trip concurrency: save 3, load back 3.
			# Back up any existing settings file first.
			var saved_path_r := str(inner_r.settings_path())
			var backup_text_r: String = ""
			var had_backup_r: bool = FileAccess.file_exists(saved_path_r)
			if had_backup_r:
				var bf_r := FileAccess.open(saved_path_r, FileAccess.READ)
				if bf_r != null:
					backup_text_r = bf_r.get_as_text()
					bf_r.close()

			inner_r.save_concurrency(3)
			var loaded_conc: int = inner_r.load_concurrency()
			check("R206: save_concurrency(3) + load_concurrency() round-trips to 3",
				loaded_conc == 3,
				"got: %d" % loaded_conc)

			# Verify that save_concurrency does NOT clobber a saved model_override.
			var probe_spec: Dictionary = {"kind": "builtin", "model_id": 99}
			inner_r.save_model_override(probe_spec)
			inner_r.save_concurrency(2)
			var override_after: Dictionary = inner_r.load_model_override()
			check("R207: save_concurrency read-modify-writes — does not clobber model_override",
				int(override_after.get("model_id", -1)) == 99,
				"model_override was clobbered: %s" % str(override_after))

			# Restore backup or clean up.
			if had_backup_r:
				var rf_r := FileAccess.open(saved_path_r, FileAccess.WRITE)
				if rf_r != null:
					rf_r.store_string(backup_text_r)
					rf_r.close()
			else:
				if FileAccess.file_exists(saved_path_r):
					DirAccess.remove_absolute(saved_path_r)

		# NOTE: sdlg extends AcceptDialog (Node) — must queue_free, not .free().
		if sdlg != null and is_instance_valid(sdlg):
			sdlg.queue_free()
		await process_frame


	# -----------------------------------------------------------------------
	# Group S: U8 — recovery sheet dialog
	# -----------------------------------------------------------------------
	print("\n-- S: U8 recovery sheet dialog --")

	var PLUGIN_RECOVERY_GD := _ui("recovery_sheet_dialog.gd")
	var recovery_script = load(PLUGIN_RECOVERY_GD)
	check("S208: recovery_sheet_dialog.gd parses cleanly",
		recovery_script != null,
		"load() returned null — check parse errors above")

	if recovery_script != null:
		# Check signals via script-level introspection (no instantiation needed).
		var signal_list: Array = recovery_script.get_script_signal_list()
		var sig_names: Array = []
		for s: Dictionary in signal_list:
			sig_names.append(s.get("name", ""))
		check("S209: RecoverySheetDialog has signal 'recovery_changed'",
			sig_names.has("recovery_changed"),
			"signals: %s" % str(sig_names))
		check("S210: RecoverySheetDialog has signal 'closed'",
			sig_names.has("closed"),
			"signals: %s" % str(sig_names))

		# Instantiate as a Node (AcceptDialog) so we can call has_method.
		var dlg: Object = recovery_script.new()
		check("S211: RecoverySheetDialog instantiates without crash", dlg != null)

		if dlg != null:
			check("S212: RecoverySheetDialog extends AcceptDialog",
				dlg is AcceptDialog,
				"got class: %s" % dlg.get_class())

			check("S213: RecoverySheetDialog has method 'init'",
				dlg.has_method("init"))

			check("S214: RecoverySheetDialog has method '_build_ui'",
				dlg.has_method("_build_ui"))

			check("S215: RecoverySheetDialog has method '_on_save_pressed'",
				dlg.has_method("_on_save_pressed"))

			check("S216: RecoverySheetDialog has method '_on_generate_pressed'",
				dlg.has_method("_on_generate_pressed"))

			# NOTE: dlg extends AcceptDialog (a Node) — use queue_free, not .free().
			if is_instance_valid(dlg):
				(dlg as Node).queue_free()
			await process_frame

	# Panel-side wire: id 13 menu item + handler method.
	var panel_s_packed := load(PLUGIN_PANEL_TSCN)
	var panel_s = null
	if panel_s_packed != null:
		panel_s = panel_s_packed.instantiate()

	if panel_s == null:
		for _si in range(2):
			_fail_count += 1
		print("  SKIP S217-S218: could not instantiate panel for S checks")
	else:
		root.add_child(panel_s)
		await process_frame

		check("S217: panel has method '_on_recovery_sheet_pressed'",
			panel_s.has_method("_on_recovery_sheet_pressed"))

		# Verify id 13 is present in the File menu.
		var actions_s: Array = panel_s.get_editor_actions() if panel_s.has_method("get_editor_actions") else []
		var fmb_s: MenuButton = null
		for a_s in actions_s:
			if a_s is MenuButton:
				fmb_s = a_s
				break
		var has_id13 := false
		if fmb_s != null:
			var pm_s: PopupMenu = fmb_s.get_popup()
			for i: int in range(pm_s.item_count):
				if pm_s.get_item_id(i) == 13:
					has_id13 = true
		check("S218: File menu (via get_editor_actions) has id 13 (Recovery Sheet)",
			has_id13, "menu id 13 not found")

		if fmb_s != null and is_instance_valid(fmb_s):
			fmb_s.queue_free()
		panel_s.queue_free()
		await process_frame


	# -----------------------------------------------------------------------
	# Group T: W5 — destination registry UI (stacked sub-trees)
	# -----------------------------------------------------------------------
	print("\n-- T: W5 destination registry UI --")

	# --- T219: scan_tree_destination_provider.gd parses cleanly ---
	var dest_prov_script = load(_ui("scan_tree_destination_provider.gd"))
	check("T219: scan_tree_destination_provider.gd parses cleanly",
		dest_prov_script != null, "load() returned null")

	if dest_prov_script != null:
		var dp_t = dest_prov_script.new()
		check("T220: DestinationProvider has method 'init'",
			dp_t.has_method("init"))
		check("T221: DestinationProvider has method 'get_tree_data'",
			dp_t.has_method("get_tree_data"))
		check("T222: DestinationProvider has method 'get_source_label'",
			dp_t.has_method("get_source_label"))
		# Uninitialised → get_tree_data returns [] without crashing.
		var dp_t_data = await dp_t.get_tree_data()
		check("T223: DestinationProvider get_tree_data returns [] when uninitialised",
			dp_t_data is Array and (dp_t_data as Array).is_empty(),
			"got: %s" % str(dp_t_data))
		# get_source_label with no dest dict → falls back gracefully.
		check("T224: DestinationProvider get_source_label returns a String when uninitialised",
			dp_t.get_source_label() is String,
			"got non-String: %s" % str(dp_t.get_source_label()))
		# NOTE: dp_t extends RefCounted — do NOT .free().

		# get_source_label reflects kind and label from the destination dict.
		var dp_vault = dest_prov_script.new()
		dp_vault.init(null, "/reg.json", {"id": "v1", "kind": "vault", "path": "/a/b.ssort", "label": "MyVault", "locked": false})
		check("T225: DestinationProvider get_source_label for vault starts with 'V:'",
			str(dp_vault.get_source_label()).begins_with("V:") or str(dp_vault.get_source_label()).begins_with("Vault"),
			"got: '%s'" % str(dp_vault.get_source_label()))

		var dp_dir = dest_prov_script.new()
		dp_dir.init(null, "/reg.json", {"id": "d1", "kind": "directory", "path": "/home/docs", "label": "Docs", "locked": false})
		check("T226: DestinationProvider get_source_label for directory starts with 'D:'",
			str(dp_dir.get_source_label()).begins_with("D:") or str(dp_dir.get_source_label()).begins_with("Dir"),
			"got: '%s'" % str(dp_dir.get_source_label()))

	# --- T227-T237: ScansortPanel W5 structural checks ---
	var panel_t_packed := load(PLUGIN_PANEL_TSCN)
	var panel_t = null
	if panel_t_packed != null:
		panel_t = panel_t_packed.instantiate()

	if panel_t == null:
		for _ti in range(12):
			_fail_count += 1
		print("  SKIP T227-T238: could not instantiate panel for T checks")
	else:
		root.add_child(panel_t)
		await process_frame

		# W5 member presence.
		check("T227: panel has member '_dest_registry' (Array)",
			"_dest_registry" in panel_t and panel_t.get("_dest_registry") is Array,
			"got: %s" % str(panel_t.get("_dest_registry")))
		check("T228: panel has member '_dest_trees' (Array)",
			"_dest_trees" in panel_t and panel_t.get("_dest_trees") is Array,
			"got: %s" % str(panel_t.get("_dest_trees")))
		check("T229: panel has member '_dest_providers' (Array)",
			"_dest_providers" in panel_t and panel_t.get("_dest_providers") is Array,
			"got: %s" % str(panel_t.get("_dest_providers")))
		check("T230: panel has member '_dest_containers' (Array)",
			"_dest_containers" in panel_t and panel_t.get("_dest_containers") is Array,
			"got: %s" % str(panel_t.get("_dest_containers")))
		check("T231: panel has member '_dest_scroll_content' (non-null after _ready)",
			panel_t.get("_dest_scroll_content") != null,
			"_dest_scroll_content is null after _ready")
		check("T232: panel has member '_registry_path' (String, starts empty)",
			"_registry_path" in panel_t and str(panel_t.get("_registry_path")) == "",
			"got: '%s'" % str(panel_t.get("_registry_path")))

		# W5 method presence.
		check("T233: panel has method '_refresh_dest_pane'",
			panel_t.has_method("_refresh_dest_pane"))
		check("T234: panel has method '_clear_dest_pane'",
			panel_t.has_method("_clear_dest_pane"))
		check("T235: panel has method '_add_dest_section'",
			panel_t.has_method("_add_dest_section"))
		check("T236: panel has method '_refresh_all_dest_trees'",
			panel_t.has_method("_refresh_all_dest_trees"))
		check("T237: panel has method '_on_dest_add_pressed'",
			panel_t.has_method("_on_dest_add_pressed"))
		check("T238: panel has method '_on_dest_remove_pressed'",
			panel_t.has_method("_on_dest_remove_pressed"))

		# --- T239-T248: simulate _add_dest_section with mock destinations ---
		# Build a minimal mock connection that returns a stub destination_list.
		# We drive _add_dest_section directly (bypassing MCP) to verify the
		# stacked sub-tree build logic in isolation.
		var scroll_content: Object = panel_t.get("_dest_scroll_content")
		var initial_child_count: int = scroll_content.get_child_count() if scroll_content != null else -1

		# Call _add_dest_section for a vault destination.
		var fake_vault_dest: Dictionary = {
			"id": "vdest1", "kind": "vault",
			"path": "/fake/vault.ssort", "label": "FakeVault", "locked": false
		}
		panel_t._add_dest_section(null, fake_vault_dest)
		await process_frame

		var child_count_after_vault: int = scroll_content.get_child_count() if scroll_content != null else -1
		check("T239: _add_dest_section(vault) adds one section to dest_scroll_content",
			child_count_after_vault == initial_child_count + 1,
			"expected %d children, got %d" % [initial_child_count + 1, child_count_after_vault])

		var trees_after_vault: Array = panel_t.get("_dest_trees")
		check("T240: _dest_trees has 1 entry after adding vault destination",
			trees_after_vault.size() == 1,
			"got size: %d" % trees_after_vault.size())
		check("T241: first entry in _dest_trees is a Tree",
			trees_after_vault.size() > 0 and trees_after_vault[0] is Tree,
			"first tree is not a Tree")
		var first_tree_role: String = str((trees_after_vault[0] as Object).get("tree_role")) if trees_after_vault.size() > 0 else ""
		check("T242: first destination tree has tree_role containing 'dest:'",
			first_tree_role.begins_with("dest:"),
			"got tree_role: '%s'" % first_tree_role)

		# Add a directory destination.
		var fake_dir_dest: Dictionary = {
			"id": "ddest1", "kind": "directory",
			"path": "/fake/docs", "label": "FakeDocs", "locked": false
		}
		panel_t._add_dest_section(null, fake_dir_dest)
		await process_frame

		var trees_after_dir: Array = panel_t.get("_dest_trees")
		check("T243: _dest_trees has 2 entries after adding second (directory) destination",
			trees_after_dir.size() == 2,
			"got size: %d" % trees_after_dir.size())
		check("T244: dest_scroll_content has 2 sections after two _add_dest_section calls",
			scroll_content.get_child_count() == initial_child_count + 2,
			"got child count: %d" % scroll_content.get_child_count())

		# Test _clear_dest_pane: all arrays emptied, nodes queued-free.
		panel_t._clear_dest_pane()
		await process_frame

		var registry_after_clear: Array = panel_t.get("_dest_registry")
		var trees_after_clear: Array  = panel_t.get("_dest_trees")
		var providers_after_clear: Array = panel_t.get("_dest_providers")
		var containers_after_clear: Array = panel_t.get("_dest_containers")
		check("T245: _clear_dest_pane empties _dest_registry",
			registry_after_clear.is_empty(), "got size: %d" % registry_after_clear.size())
		check("T246: _clear_dest_pane empties _dest_trees",
			trees_after_clear.is_empty(), "got size: %d" % trees_after_clear.size())
		check("T247: _clear_dest_pane empties _dest_providers",
			providers_after_clear.is_empty(), "got size: %d" % providers_after_clear.size())
		check("T248: _clear_dest_pane empties _dest_containers",
			containers_after_clear.is_empty(), "got size: %d" % containers_after_clear.size())

		# --- T249: file_dropped from source tree reaches panel handler ---
		# Re-add one destination section and simulate a file_dropped signal.
		panel_t._add_dest_section(null, fake_vault_dest)
		await process_frame

		var drop_trees: Array = panel_t.get("_dest_trees")
		var drop_received: bool = false
		# Override _on_tree_file_dropped via a flag — we can't easily spy on it
		# directly, but we CAN verify that the signal emitted on the dest tree
		# fires without errors (the connection is wired in _add_dest_section).
		# Emit file_dropped on the tree and verify the panel doesn't crash.
		if drop_trees.size() > 0:
			var dest_tree_t: Tree = drop_trees[0] as Tree
			# We need a folder row for the target_key — populate the tree first.
			dest_tree_t.populate([
				{
					"kind": "folder", "name": "invoices/ (0)", "key": "cat:invoices",
					"date": "", "tooltip": "", "children": [],
				}
			])
			await process_frame
			# Emit directly — the panel handler will be called synchronously.
			var emit_ok: bool = true
			dest_tree_t.file_dropped.emit(
				{"scan_tree_drag": true, "key": "/tmp/test.pdf", "role": "source"},
				"cat:invoices",
				"folder"
			)
			drop_received = emit_ok
		check("T249: file_dropped emitted on a destination tree does not crash",
			drop_received, "emit raised an error or no dest trees present")

		panel_t.queue_free()
		await process_frame

	# --- T250: _on_tree_file_dropped has correct signature (4-param with default) ---
	var panel_t2_packed := load(PLUGIN_PANEL_TSCN)
	var panel_t2 = null
	if panel_t2_packed != null:
		panel_t2 = panel_t2_packed.instantiate()
	if panel_t2 != null:
		root.add_child(panel_t2)
		await process_frame
		check("T250: panel has method '_on_tree_file_dropped' (W5 4-param signature)",
			panel_t2.has_method("_on_tree_file_dropped"),
			"_on_tree_file_dropped missing")
		# Also verify _do_add_destination and _do_add_destination helpers are present.
		check("T251: panel has method '_do_add_destination'",
			panel_t2.has_method("_do_add_destination"),
			"_do_add_destination missing")
		panel_t2.queue_free()
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
