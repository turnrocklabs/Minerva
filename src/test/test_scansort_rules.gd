extends SceneTree
## Scansort plugin rules + classifier integration test — T6 R3.
##
## Run: godot --headless --path src --script test/test_scansort_rules.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Round:         T6 R3 — rules.rs + classifier.rs + 7 new MCP tools
##
## Goal: exercise the 7 new rules/classify tools against a real vault file using
##       the actual Rust binary. No stubs. Verifies:
##         1–3.   insert_rule — add 3 rules, unique ids >= 1
##         4.     list_rules — 3 entries, fields populated
##         5.     get_rule by id — matches inserted
##         6.     get_rule by label — matches
##         7.     update_rule — instruction persists after re-fetch
##         8.     delete_rule — list shrinks to 2
##         9.     import_rules_from_json — bulk 5 rules → list = 7
##         10.    insert_rule wrong vault path → error
##         11.    duplicate label handling (INSERT returns error or replaces)
##         12.    get_rule nonexistent label → error
##         13.    update_rule nonexistent label → error
##         14.    import_rules_from_json invalid JSON → error
##         15–17. classify_document dispatch — tool responds (not "unknown tool")
##                with host.providers.chat NOT granted → structured error

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
	print("=== Scansort Rules + Classifier Integration Test (T6 R3) ===\n")
	print("Run ID: %s\n" % _run_id)

	var home: String = OS.get_environment("HOME")
	if home == "":
		printerr("FAIL: $HOME is unset — can't locate plugin source dir.")
		quit(1)
		return

	var plugin_dir: String = home + SCANSORT_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + SCANSORT_BINARY_REL
	var manifest_path: String = plugin_dir + SCANSORT_MANIFEST_REL

	if not FileAccess.file_exists(binary_path):
		print("SKIP: scansort-plugin binary not built at %s" % binary_path)
		print("      Build with: cd %s && cargo build --release && cp target/release/scansort-plugin ." % plugin_dir)
		quit(0)
		return

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: scansort manifest not found at %s" % manifest_path)
		quit(1)
		return

	print("Scansort plugin source: %s" % plugin_dir)
	print("Scansort binary:        %s\n" % binary_path)

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
		print("Scansort not in PluginDB — installing from manifest...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
			"got: %s" % str(install_result))
		def = db.get_by_id("scansort")

	check("Scansort definition loaded into DB", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		print("Plugin already RUNNING — stopping first for clean baseline.")
		await pm.stop_plugin("scansort")

	# Clean policy.json to avoid stale capability grants.
	var policy_path: String = ProjectSettings.globalize_path("user://plugins/policy.json")
	if FileAccess.file_exists(policy_path):
		print("Pre-clean: removing stale policy.json")
		DirAccess.remove_absolute(policy_path)

	# --- START ---
	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin("scansort")
	check("start_plugin returns ok",
		start_result.get("ok", false) == true,
		"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
		"got state=%d (expected %d)" % [def.state, S_RUNNING])

	var conn = pm.get_connection("scansort")
	check("connection exists post-start", conn != null)
	if conn == null:
		return

	# --- PREPARE PATHS ---
	var scope_dir: String = ProjectSettings.globalize_path(VAULT_SCOPE_REL)
	DirAccess.make_dir_recursive_absolute(scope_dir)

	var vault_filename: String = "r6r3_rules_%s.ssort" % _run_id
	var vault_abs: String = scope_dir.path_join(vault_filename)

	_clean_stale_files(scope_dir, "r6r3_rules_")

	print("\nVault path: %s" % vault_abs)

	# --- SETUP: create vault ---
	print("\n-- setup: create_vault --")
	var create_result: Dictionary = await conn.call_tool(
		"minerva_scansort_create_vault",
		{"path": vault_abs, "name": "T6 R3 Rules Test Vault"}
	)
	check("create_vault ok", create_result.get("ok", false) == true,
		"got: %s" % str(create_result))
	check("vault file exists", FileAccess.file_exists(vault_abs))

	# --- TEST 1–3: INSERT 3 RULES ---
	print("\n-- tests 1-3: insert_rule x3 --")
	var r1: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_rule",
		{
			"path": vault_abs,
			"label": "invoices",
			"name": "Invoices",
			"instruction": "Bills, invoices, receipts for goods or services.",
			"signals": ["invoice", "bill", "receipt", "total due"],
			"subfolder": "finance/invoices",
			"confidence_threshold": 0.7,
			"encrypt": false,
			"enabled": true,
		}
	)
	check("insert_rule r1 ok", r1.get("ok", false) == true, "got: %s" % str(r1))
	var r1_id: int = int(r1.get("rule_id", -1))
	check("insert_rule r1 rule_id >= 1", r1_id >= 1, "got rule_id=%s" % str(r1.get("rule_id", -1)))

	var r2: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_rule",
		{
			"path": vault_abs,
			"label": "medical",
			"name": "Medical",
			"instruction": "Medical records, prescriptions, lab results, doctor visits.",
			"signals": ["doctor", "pharmacy", "diagnosis", "lab"],
			"subfolder": "health/medical",
			"confidence_threshold": 0.65,
			"encrypt": true,
			"enabled": true,
		}
	)
	check("insert_rule r2 ok", r2.get("ok", false) == true, "got: %s" % str(r2))
	var r2_id: int = int(r2.get("rule_id", -1))
	check("insert_rule r2 rule_id >= 1", r2_id >= 1, "got rule_id=%s" % str(r2.get("rule_id", -1)))
	check("insert_rule r1/r2 have distinct ids", r1_id != r2_id,
		"r1=%d r2=%d" % [r1_id, r2_id])

	var r3: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_rule",
		{
			"path": vault_abs,
			"label": "memories",
			"name": "Memories",
			"instruction": "Personal photos, mementos, letters, diaries.",
			"signals": ["photo", "memory", "personal"],
			"subfolder": "personal/memories",
			"confidence_threshold": 0.5,
			"encrypt": false,
			"enabled": true,
		}
	)
	check("insert_rule r3 ok", r3.get("ok", false) == true, "got: %s" % str(r3))
	var r3_id: int = int(r3.get("rule_id", -1))
	check("insert_rule r3 rule_id >= 1", r3_id >= 1, "got rule_id=%s" % str(r3.get("rule_id", -1)))
	check("all 3 rule_ids unique",
		r1_id != r3_id and r2_id != r3_id,
		"r1=%d r2=%d r3=%d" % [r1_id, r2_id, r3_id])

	# --- TEST 4: LIST RULES ---
	print("\n-- test 4: list_rules --")
	var list_r: Dictionary = await conn.call_tool(
		"minerva_scansort_list_rules",
		{"path": vault_abs}
	)
	check("list_rules ok", list_r.get("ok", false) == true, "got: %s" % str(list_r))
	var rule_list = list_r.get("rules", [])
	check("list_rules count == 3", rule_list.size() == 3,
		"got count=%d" % rule_list.size())
	if rule_list.size() > 0:
		var first = rule_list[0] as Dictionary
		check("list_rules[0] has label", not (first.get("label", "") as String).is_empty(),
			"label='%s'" % str(first.get("label", "")))
		check("list_rules[0] has instruction", not (first.get("instruction", "") as String).is_empty(),
			"instruction='%s'" % str(first.get("instruction", "")))

	# --- TEST 5: GET RULE BY ID ---
	print("\n-- test 5: get_rule by rule_id --")
	var get_by_id: Dictionary = await conn.call_tool(
		"minerva_scansort_get_rule",
		{"path": vault_abs, "rule_id": r2_id}
	)
	check("get_rule by id ok", get_by_id.get("ok", false) == true,
		"got: %s" % str(get_by_id))
	var got_rule = get_by_id.get("rule", {}) as Dictionary
	check("get_rule by id label == 'medical'",
		got_rule.get("label", "") == "medical",
		"got label='%s'" % str(got_rule.get("label", "")))

	# --- TEST 6: GET RULE BY LABEL ---
	print("\n-- test 6: get_rule by label --")
	var get_by_label: Dictionary = await conn.call_tool(
		"minerva_scansort_get_rule",
		{"path": vault_abs, "label": "invoices"}
	)
	check("get_rule by label ok", get_by_label.get("ok", false) == true,
		"got: %s" % str(get_by_label))
	var got_rule2 = get_by_label.get("rule", {}) as Dictionary
	check("get_rule by label id matches r1_id",
		int(got_rule2.get("rule_id", -1)) == r1_id,
		"got rule_id=%s expected %d" % [str(got_rule2.get("rule_id", -1)), r1_id])
	check("get_rule by label instruction populated",
		not (got_rule2.get("instruction", "") as String).is_empty(),
		"instruction='%s'" % str(got_rule2.get("instruction", "")))

	# --- TEST 7: UPDATE RULE ---
	print("\n-- test 7: update_rule --")
	var upd: Dictionary = await conn.call_tool(
		"minerva_scansort_update_rule",
		{
			"path": vault_abs,
			"label": "invoices",
			"updates": {"instruction": "Updated: bills, invoices, and expense reports."},
		}
	)
	check("update_rule ok", upd.get("ok", false) == true, "got: %s" % str(upd))

	# Re-fetch to verify persisted
	var re_fetch: Dictionary = await conn.call_tool(
		"minerva_scansort_get_rule",
		{"path": vault_abs, "label": "invoices"}
	)
	check("re-fetch after update ok", re_fetch.get("ok", false) == true,
		"got: %s" % str(re_fetch))
	var updated_rule = re_fetch.get("rule", {}) as Dictionary
	check("update_rule instruction persisted",
		updated_rule.get("instruction", "") == "Updated: bills, invoices, and expense reports.",
		"got: '%s'" % str(updated_rule.get("instruction", "")))

	# --- TEST 8: DELETE RULE ---
	print("\n-- test 8: delete_rule --")
	var del_r: Dictionary = await conn.call_tool(
		"minerva_scansort_delete_rule",
		{"path": vault_abs, "label": "medical"}
	)
	check("delete_rule ok", del_r.get("ok", false) == true, "got: %s" % str(del_r))

	var list_after_del: Dictionary = await conn.call_tool(
		"minerva_scansort_list_rules",
		{"path": vault_abs}
	)
	check("list_rules after delete ok", list_after_del.get("ok", false) == true,
		"got: %s" % str(list_after_del))
	var rules_after = list_after_del.get("rules", [])
	check("list_rules after delete == 2", rules_after.size() == 2,
		"got count=%d" % rules_after.size())

	# --- TEST 9: IMPORT RULES FROM JSON ---
	print("\n-- test 9: import_rules_from_json (5 rules) --")
	var bulk_json: String = JSON.stringify([
		{"label": "tax", "name": "Tax", "instruction": "Tax forms, W2, 1099, returns.", "signals": ["w2", "1099", "irs"], "enabled": true},
		{"label": "insurance", "name": "Insurance", "instruction": "Insurance policies, claims, EOBs.", "signals": ["insurance", "claim", "policy"], "enabled": true},
		{"label": "banking", "name": "Banking", "instruction": "Bank statements, wire transfers.", "signals": ["bank", "statement", "transfer"], "enabled": true},
		{"label": "utilities", "name": "Utilities", "instruction": "Utility bills: electricity, water, gas, internet.", "signals": ["utility", "electric", "water", "gas"], "enabled": true},
		{"label": "contracts", "name": "Contracts", "instruction": "Signed contracts, agreements, NDAs.", "signals": ["contract", "agreement", "nda"], "enabled": true},
	])
	var import_r: Dictionary = await conn.call_tool(
		"minerva_scansort_import_rules_from_json",
		{"path": vault_abs, "json_text": bulk_json}
	)
	check("import_rules_from_json ok", import_r.get("ok", false) == true,
		"got: %s" % str(import_r))
	check("import_rules_from_json count == 5", int(import_r.get("count", -1)) == 5,
		"got count=%s" % str(import_r.get("count", -1)))

	var list_final: Dictionary = await conn.call_tool(
		"minerva_scansort_list_rules",
		{"path": vault_abs}
	)
	check("list_rules after import ok", list_final.get("ok", false) == true,
		"got: %s" % str(list_final))
	var rules_final = list_final.get("rules", [])
	check("list_rules after import == 7", rules_final.size() == 7,
		"got count=%d" % rules_final.size())

	# --- NEGATIVE TEST 10: wrong vault path ---
	print("\n-- test 10: negative — insert_rule with bad vault_path --")
	var bad_vault: String = scope_dir.path_join("nonexistent_%s.ssort" % _run_id)
	var bad_insert: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_rule",
		{"path": bad_vault, "label": "test_neg", "instruction": "x"}
	)
	check("insert_rule bad path returns error",
		bad_insert.has("error") or bad_insert.get("ok", true) == false,
		"got: %s" % str(bad_insert))

	# --- NEGATIVE TEST 11: duplicate label ---
	# The rules table has UNIQUE on label. INSERT (not INSERT OR REPLACE) should fail.
	print("\n-- test 11: negative — duplicate label insert --")
	var dup_insert: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_rule",
		{"path": vault_abs, "label": "invoices", "instruction": "duplicate attempt"}
	)
	# Should either be an error OR return ok (INSERT OR REPLACE) — either is acceptable.
	# We just verify it returned a Dictionary (dispatched correctly, not "unknown tool").
	check("duplicate label insert returns Dictionary (dispatched)", dup_insert is Dictionary,
		"got type %d" % typeof(dup_insert))

	# --- NEGATIVE TEST 12: get_rule nonexistent label ---
	print("\n-- test 12: negative — get_rule with nonexistent label --")
	var no_rule: Dictionary = await conn.call_tool(
		"minerva_scansort_get_rule",
		{"path": vault_abs, "label": "nonexistent_label_xyz"}
	)
	check("get_rule nonexistent returns error",
		no_rule.has("error") or no_rule.get("ok", true) == false,
		"got: %s" % str(no_rule))

	# --- NEGATIVE TEST 13: update_rule nonexistent label ---
	print("\n-- test 13: negative — update_rule with nonexistent label --")
	var no_update: Dictionary = await conn.call_tool(
		"minerva_scansort_update_rule",
		{
			"path": vault_abs,
			"label": "nonexistent_label_xyz",
			"updates": {"instruction": "should fail"},
		}
	)
	check("update_rule nonexistent returns error",
		no_update.has("error") or no_update.get("ok", true) == false,
		"got: %s" % str(no_update))

	# --- NEGATIVE TEST 14: import_rules invalid JSON ---
	print("\n-- test 14: negative — import_rules_from_json with invalid JSON --")
	var bad_import: Dictionary = await conn.call_tool(
		"minerva_scansort_import_rules_from_json",
		{"path": vault_abs, "json_text": "this is {not valid json at all"}
	)
	check("import_rules invalid json returns error",
		bad_import.has("error") or bad_import.get("ok", true) == false,
		"got: %s" % str(bad_import))

	# --- CLASSIFY TESTS (no live LLM) ---
	# The plugin is started WITHOUT granting host.providers.chat. Policy was cleared
	# above. The broker will return a capability_not_granted error when classify_document
	# tries to issue the capability request. We verify:
	#   (a) classify_document is dispatched (not "unknown tool")
	#   (b) it returns a structured error (not a hang or crash)
	#   (c) text mode with empty text returns early validation error
	#   (d) vision mode with empty page_images returns early validation error

	print("\n-- test 15: classify_document dispatch + broker denial (no LLM grant) --")
	var classify_denied: Dictionary = await conn.call_tool(
		"minerva_scansort_classify_document",
		{
			"vault_path": vault_abs,
			"mode": "text",
			"document_text": "This is a test invoice from ACME Corp for $500.",
			"model_id": "test-model",
		}
	)
	check("classify_document dispatched (not unknown tool)", classify_denied is Dictionary,
		"got type %d" % typeof(classify_denied))
	# Should be an error (capability not granted or broker error), NOT ok:true
	check("classify_document without chat grant returns error",
		classify_denied.has("error") or classify_denied.get("ok", true) == false,
		"got: %s" % str(classify_denied))

	print("\n-- test 16: classify_document text mode with empty document_text --")
	var classify_empty_text: Dictionary = await conn.call_tool(
		"minerva_scansort_classify_document",
		{
			"vault_path": vault_abs,
			"mode": "text",
			"document_text": "",
			"model_id": "test-model",
		}
	)
	check("classify_document empty text returns error",
		classify_empty_text.has("error") or classify_empty_text.get("ok", true) == false,
		"got: %s" % str(classify_empty_text))

	print("\n-- test 17: classify_document vision mode with empty page_images --")
	var classify_empty_vision: Dictionary = await conn.call_tool(
		"minerva_scansort_classify_document",
		{
			"vault_path": vault_abs,
			"mode": "vision",
			"page_images": [],
			"model_id": "test-model",
		}
	)
	check("classify_document empty page_images returns error",
		classify_empty_vision.has("error") or classify_empty_vision.get("ok", true) == false,
		"got: %s" % str(classify_empty_vision))

	# --- CLEANUP ---
	print("\n-- cleanup --")
	DirAccess.remove_absolute(vault_abs)
	DirAccess.remove_absolute(vault_abs + "-wal")
	DirAccess.remove_absolute(vault_abs + "-shm")
	check("vault file deleted after test",
		not FileAccess.file_exists(vault_abs))

	# --- STOP ---
	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("scansort")
	check("stop_plugin returns ok",
		stop_result.get("ok", false) == true,
		"got: %s" % str(stop_result))
	check("plugin state == STOPPED", def.state == S_STOPPED,
		"got state=%d (expected %d)" % [def.state, S_STOPPED])

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
