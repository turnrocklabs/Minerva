extends SceneTree
## Scansort plugin checklist tool integration test — T7 R6.
##
## Run: godot --headless --path src --script test/test_scansort_checklists.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Round:         T7 R6 — checklists.rs port + 7 new MCP tools
##
## Goal: exercise the 7 new checklist tools against a real vault file using the
##       actual Rust binary. Verifies:
##         1–3.   insert_checklist x3 — unique ids
##         4.     list_checklists by tax_year — 3 entries
##         5.     list_checklists with item_type filter
##         6.     get_checklist by id
##         7.     update_checklist
##         8.     toggle_checklist_enabled
##         9.     delete_checklist
##         10.    run_checklist_check
##         11–15. negative paths (wrong password, nonexistent id, missing args)

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const SCANSORT_PLUGIN_DIR_REL := "/github/plugins/scansort"
const SCANSORT_BINARY_REL := "/scansort-plugin"
const SCANSORT_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

const VAULT_SCOPE_REL := "user://plugins/data/scansort/test"

var _pass_count: int = 0
var _fail_count: int = 0
var _run_id: String = ""


func _init() -> void:
	_run_id = str(Time.get_ticks_usec())
	print("=== Scansort Checklist Integration Test (T7 R6) ===\n")
	print("Run ID: %s\n" % _run_id)

	var home: String = OS.get_environment("HOME")
	if home == "":
		printerr("FAIL: $HOME is unset.")
		quit(1)
		return

	var plugin_dir: String = home + SCANSORT_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + SCANSORT_BINARY_REL
	var manifest_path: String = plugin_dir + SCANSORT_MANIFEST_REL

	if not FileAccess.file_exists(binary_path):
		print("SKIP: scansort-plugin binary not built at %s" % binary_path)
		quit(0)
		return

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: manifest missing at %s" % manifest_path)
		quit(1)
		return

	await _run_test(manifest_path)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_test(manifest_path: String) -> void:
	await process_frame

	var so_node_init = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node_init != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node_init.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail_count += 1
		return

	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame

	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id("scansort")

	if def == null:
		print("Scansort not in PluginDB — installing...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin ok", install_result.get("ok", false) == true,
			"got: %s" % str(install_result))
		def = db.get_by_id("scansort")

	check("scansort definition loaded", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		await pm.stop_plugin("scansort")

	var policy_path: String = ProjectSettings.globalize_path("user://plugins/policy.json")
	if FileAccess.file_exists(policy_path):
		DirAccess.remove_absolute(policy_path)

	# --- START ---
	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin("scansort")
	check("start_plugin ok", start_result.get("ok", false) == true,
		"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
		"got state=%d" % def.state)

	var conn = pm.get_connection("scansort")
	check("connection exists post-start", conn != null)
	if conn == null:
		return

	# --- PREPARE VAULT ---
	var scope_dir: String = ProjectSettings.globalize_path(VAULT_SCOPE_REL)
	DirAccess.make_dir_recursive_absolute(scope_dir)
	var vault_filename: String = "r7r6_checklist_%s.ssort" % _run_id
	var vault_abs: String = scope_dir.path_join(vault_filename)
	_clean_stale_files(scope_dir, "r7r6_checklist_")

	print("\nVault path: %s" % vault_abs)

	print("\n-- setup: create_vault --")
	var create_result: Dictionary = await conn.call_tool(
		"minerva_scansort_create_vault",
		{"path": vault_abs, "name": "T7 R6 Checklist Test Vault"}
	)
	check("create_vault ok", create_result.get("ok", false) == true,
		"got: %s" % str(create_result))

	const TAX_YEAR := 2025

	# --- TESTS 1-3: insert 3 checklist items ---
	print("\n-- tests 1-3: insert_checklist x3 --")
	var c1: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_checklist",
		{
			"path": vault_abs,
			"tax_year": TAX_YEAR,
			"item_type": "auto_upload",
			"name": "W-2 from Employer",
			"match_category": "income",
			"match_sender": "Acme Corp",
		}
	)
	check("insert_checklist c1 ok", c1.get("ok", false) == true, "got: %s" % str(c1))
	var c1_id: int = int(c1.get("checklist_id", -1))
	check("c1 checklist_id >= 1", c1_id >= 1, "got id=%d" % c1_id)

	var c2: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_checklist",
		{
			"path": vault_abs,
			"tax_year": TAX_YEAR,
			"item_type": "expected_doc",
			"name": "1099 from broker",
			"match_category": "income",
		}
	)
	check("insert_checklist c2 ok", c2.get("ok", false) == true, "got: %s" % str(c2))
	var c2_id: int = int(c2.get("checklist_id", -1))
	check("c2 checklist_id >= 1", c2_id >= 1, "got id=%d" % c2_id)

	var c3: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_checklist",
		{
			"path": vault_abs,
			"tax_year": TAX_YEAR,
			"item_type": "auto_upload",
			"name": "Charity receipt",
			"match_category": "deductions",
			"match_pattern": "donat",
		}
	)
	check("insert_checklist c3 ok", c3.get("ok", false) == true, "got: %s" % str(c3))
	var c3_id: int = int(c3.get("checklist_id", -1))
	check("c3 checklist_id >= 1", c3_id >= 1, "got id=%d" % c3_id)
	check("all 3 ids unique",
		c1_id != c2_id and c2_id != c3_id and c1_id != c3_id,
		"c1=%d c2=%d c3=%d" % [c1_id, c2_id, c3_id])

	# --- TEST 4: list by year ---
	print("\n-- test 4: list_checklists by tax_year --")
	var list_all: Dictionary = await conn.call_tool(
		"minerva_scansort_list_checklists",
		{"path": vault_abs, "tax_year": TAX_YEAR}
	)
	check("list_checklists ok", list_all.get("ok", false) == true,
		"got: %s" % str(list_all))
	var items_all = list_all.get("items", []) as Array
	check("list returns 3 items", items_all.size() == 3,
		"got %d items" % items_all.size())
	check("list count field matches", int(list_all.get("count", -1)) == 3,
		"got count=%d" % int(list_all.get("count", -1)))

	# --- TEST 5: filter by item_type ---
	print("\n-- test 5: list_checklists item_type filter --")
	var list_auto: Dictionary = await conn.call_tool(
		"minerva_scansort_list_checklists",
		{"path": vault_abs, "tax_year": TAX_YEAR, "item_type": "auto_upload"}
	)
	check("list_checklists auto_upload ok",
		list_auto.get("ok", false) == true, "got: %s" % str(list_auto))
	var items_auto = list_auto.get("items", []) as Array
	check("filter returns 2 auto_upload items", items_auto.size() == 2,
		"got %d items" % items_auto.size())

	# --- TEST 6: get_checklist ---
	print("\n-- test 6: get_checklist by id --")
	var get_r: Dictionary = await conn.call_tool(
		"minerva_scansort_get_checklist",
		{"path": vault_abs, "checklist_id": c2_id}
	)
	check("get_checklist ok", get_r.get("ok", false) == true,
		"got: %s" % str(get_r))
	var got_item = get_r.get("item", {}) as Dictionary
	check("got_item name matches", got_item.get("name", "") == "1099 from broker",
		"got name='%s'" % str(got_item.get("name", "")))
	check("got_item item_type matches", got_item.get("item_type", "") == "expected_doc",
		"got item_type='%s'" % str(got_item.get("item_type", "")))

	# --- TEST 7: update_checklist ---
	print("\n-- test 7: update_checklist --")
	var upd_r: Dictionary = await conn.call_tool(
		"minerva_scansort_update_checklist",
		{
			"path": vault_abs,
			"checklist_id": c1_id,
			"updates": {"name": "W-2 from Acme (renamed)"},
		}
	)
	check("update_checklist ok", upd_r.get("ok", false) == true,
		"got: %s" % str(upd_r))
	var get_after_update: Dictionary = await conn.call_tool(
		"minerva_scansort_get_checklist",
		{"path": vault_abs, "checklist_id": c1_id}
	)
	check("updated name persisted",
		(get_after_update.get("item", {}) as Dictionary).get("name", "") == "W-2 from Acme (renamed)",
		"got: %s" % str(get_after_update.get("item", {})))

	# --- TEST 8: toggle_checklist_enabled ---
	print("\n-- test 8: toggle_checklist_enabled --")
	var tog_r: Dictionary = await conn.call_tool(
		"minerva_scansort_toggle_checklist_enabled",
		{"path": vault_abs, "checklist_id": c3_id, "enabled": false}
	)
	check("toggle_checklist_enabled ok", tog_r.get("ok", false) == true,
		"got: %s" % str(tog_r))
	var get_after_toggle: Dictionary = await conn.call_tool(
		"minerva_scansort_get_checklist",
		{"path": vault_abs, "checklist_id": c3_id}
	)
	var toggled_item = get_after_toggle.get("item", {}) as Dictionary
	check("c3 now disabled",
		toggled_item.get("enabled", true) == false,
		"got enabled=%s" % str(toggled_item.get("enabled", true)))

	# --- TEST 9: delete_checklist ---
	print("\n-- test 9: delete_checklist --")
	var del_r: Dictionary = await conn.call_tool(
		"minerva_scansort_delete_checklist",
		{"path": vault_abs, "checklist_id": c2_id}
	)
	check("delete_checklist ok", del_r.get("ok", false) == true,
		"got: %s" % str(del_r))
	var list_after_delete: Dictionary = await conn.call_tool(
		"minerva_scansort_list_checklists",
		{"path": vault_abs, "tax_year": TAX_YEAR}
	)
	var items_after = list_after_delete.get("items", []) as Array
	check("list shrinks to 2 after delete", items_after.size() == 2,
		"got %d items" % items_after.size())

	# --- TEST 10: run_checklist_check ---
	print("\n-- test 10: run_checklist_check --")
	var run_r: Dictionary = await conn.call_tool(
		"minerva_scansort_run_checklist_check",
		{"path": vault_abs, "tax_year": TAX_YEAR}
	)
	check("run_checklist_check dispatched",
		run_r is Dictionary and not run_r.is_empty(),
		"got: %s" % str(run_r))

	# --- NEGATIVE PATHS ---
	print("\n-- test 11: insert_checklist missing tax_year --")
	var neg_year: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_checklist",
		{
			"path": vault_abs,
			"item_type": "auto_upload",
			"name": "missing year",
		}
	)
	check("insert_checklist without tax_year errors",
		neg_year.has("error") or neg_year.get("ok", true) == false,
		"got: %s" % str(neg_year))

	print("\n-- test 12: insert_checklist missing item_type --")
	var neg_type: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_checklist",
		{
			"path": vault_abs,
			"tax_year": TAX_YEAR,
			"name": "missing type",
		}
	)
	check("insert_checklist without item_type errors",
		neg_type.has("error") or neg_type.get("ok", true) == false,
		"got: %s" % str(neg_type))

	print("\n-- test 13: get_checklist nonexistent id --")
	var neg_get: Dictionary = await conn.call_tool(
		"minerva_scansort_get_checklist",
		{"path": vault_abs, "checklist_id": 99999}
	)
	check("get_checklist nonexistent id errors",
		neg_get.has("error") or neg_get.get("ok", true) == false,
		"got: %s" % str(neg_get))

	print("\n-- test 14: update_checklist nonexistent id --")
	var neg_upd: Dictionary = await conn.call_tool(
		"minerva_scansort_update_checklist",
		{"path": vault_abs, "checklist_id": 99999, "updates": {"name": "ghost"}}
	)
	check("update_checklist nonexistent id errors",
		neg_upd.has("error") or neg_upd.get("ok", true) == false,
		"got: %s" % str(neg_upd))

	print("\n-- test 15: insert_checklist nonexistent vault --")
	var neg_path: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_checklist",
		{
			"path": "/tmp/doesnotexist.ssort",
			"tax_year": TAX_YEAR,
			"item_type": "auto_upload",
			"name": "no vault",
		}
	)
	check("insert_checklist bad path errors",
		neg_path.has("error") or neg_path.get("ok", true) == false,
		"got: %s" % str(neg_path))

	# --- CLEANUP ---
	print("\n-- cleanup --")
	DirAccess.remove_absolute(vault_abs)
	DirAccess.remove_absolute(vault_abs + "-wal")
	DirAccess.remove_absolute(vault_abs + "-shm")
	check("vault file deleted after test",
		not FileAccess.file_exists(vault_abs))

	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("scansort")
	check("stop_plugin ok", stop_result.get("ok", false) == true,
		"got: %s" % str(stop_result))
	check("plugin state == STOPPED", def.state == S_STOPPED,
		"got state=%d" % def.state)

	db.remove("scansort")


func _clean_stale_files(scope_dir: String, prefix: String) -> void:
	var da := DirAccess.open(scope_dir)
	if da == null:
		return
	da.list_dir_begin()
	var fname: String = da.get_next()
	while fname != "":
		if fname.begins_with(prefix):
			DirAccess.remove_absolute(scope_dir.path_join(fname))
		fname = da.get_next()
	da.list_dir_end()


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
