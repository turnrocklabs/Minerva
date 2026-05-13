extends SceneTree
## Scansort plugin document tool integration test — T6 R1.
##
## Run: godot --headless --path src --script test/test_scansort_documents.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Round:         T6 R1 — documents.rs port + 6 new document MCP tools
##
## Goal: exercise the 6 new document MCP tools against a real vault file using
##       the actual Rust binary. No stubs. Verifies:
##         1. insert_document — ingest a fixture file
##         2. query_documents — list with filters
##         3. get_document — by doc_id
##         4. extract_document — round-trip byte match
##         5. update_document — field mutation persists
##         6. vault_inventory — counts
##         7–9. Negative paths (wrong password vault, bad vault_path, missing doc_id)

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

const SCANSORT_PLUGIN_DIR_REL := "/github/plugins/scansort"
const SCANSORT_BINARY_REL := "/scansort-plugin"
const SCANSORT_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

## Path inside the auto-granted plugin data scope.
const VAULT_SCOPE_REL := "user://plugins/data/scansort/test"

var _pass_count: int = 0
var _fail_count: int = 0

## Unique suffix per run to avoid cross-run collisions.
var _run_id: String = ""


func _init() -> void:
	_run_id = str(Time.get_ticks_usec())
	print("=== Scansort Document Tool Integration Test (T6 R1) ===\n")
	print("Run ID: %s\n" % _run_id)
	print("Purpose: insert/query/get/extract/update/inventory via real Rust binary.\n")

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
	# Wait one frame so autoloads (SingletonObject) have a chance to register.
	await process_frame

	# Wait for SingletonObject.plugin_tool_registry to be non-null.
	var so_node_init = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node_init != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node_init.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout
		var ready_at: int = Time.get_ticks_msec()
		print("SingletonObject.plugin_tool_registry available after %dms" % (ready_at - (deadline_ms - 10000)))

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

	# Ensure plugin is not already RUNNING (stale state from prior run).
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

	var vault_filename: String = "r6_docs_%s.ssort" % _run_id
	var vault_abs: String = scope_dir.path_join(vault_filename)
	var fixture_abs: String = scope_dir.path_join("fixture_%s.txt" % _run_id)
	var extract_abs: String = scope_dir.path_join("extracted_%s.txt" % _run_id)

	# Pre-clean stale files from prior runs (any r6_docs_* files).
	_clean_stale_files(scope_dir, "r6_docs_")

	print("\nVault path:   %s" % vault_abs)
	print("Fixture path: %s" % fixture_abs)

	# --- WRITE FIXTURE FILE ---
	var fixture_content: String = "Scansort T6 R1 fixture document.\nLine 2: some data.\nLine 3: more content for round-trip test.\n"
	var fixture_bytes: PackedByteArray = fixture_content.to_utf8_buffer()
	var fw = FileAccess.open(fixture_abs, FileAccess.WRITE)
	if fw == null:
		printerr("FAIL: could not write fixture file at %s" % fixture_abs)
		_fail_count += 1
		return
	fw.store_buffer(fixture_bytes)
	fw.close()
	check("fixture file written", FileAccess.file_exists(fixture_abs))

	# --- SETUP: create vault + set password + open vault ---
	print("\n-- setup: create_vault --")
	var create_result: Dictionary = await conn.call_tool(
		"minerva_scansort_create_vault",
		{"path": vault_abs, "name": "T6 R1 Docs Test Vault"}
	)
	check("create_vault ok", create_result.get("ok", false) == true,
		"got: %s" % str(create_result))
	check("vault file exists", FileAccess.file_exists(vault_abs))

	print("\n-- setup: set_password --")
	var set_pw: Dictionary = await conn.call_tool(
		"minerva_scansort_set_password",
		{"path": vault_abs, "password": "docs-test-pw"}
	)
	check("set_password ok", set_pw.get("ok", false) == true,
		"got: %s" % str(set_pw))

	print("\n-- setup: open_vault --")
	var open_result: Dictionary = await conn.call_tool(
		"minerva_scansort_open_vault",
		{"path": vault_abs}
	)
	check("open_vault ok", open_result.get("ok", false) == true,
		"got: %s" % str(open_result))

	# --- TEST 1: INSERT DOCUMENT ---
	print("\n-- test 1: minerva_scansort_insert_document --")
	var insert_result: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_document",
		{
			"vault_path": vault_abs,
			"file_path": fixture_abs,
			"category": "test_category",
			"confidence": 0.95,
			"sender": "test_sender",
			"description": "T6 R1 fixture document",
			"doc_date": "2026-05-13",
			"status": "classified",
			"sha256": "",
			"simhash": "",
			"dhash": "",
			"source_path": "",
		}
	)
	check("insert_document returned Dictionary", insert_result is Dictionary,
		"got type %d" % typeof(insert_result))
	check("insert_document ok == true",
		insert_result.get("ok", false) == true,
		"got: %s" % str(insert_result))
	var doc_id = insert_result.get("doc_id", -1)
	# GDScript JSON round-trips give floats; accept whole-number float too.
	var doc_id_int: int = int(doc_id)
	check("insert_document doc_id >= 1",
		doc_id_int >= 1,
		"got doc_id=%s" % str(doc_id))

	# --- TEST 2: QUERY DOCUMENTS ---
	print("\n-- test 2: minerva_scansort_query_documents --")
	var query_result: Dictionary = await conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": vault_abs}
	)
	check("query_documents returned Dictionary", query_result is Dictionary,
		"got type %d" % typeof(query_result))
	check("query_documents ok == true",
		query_result.get("ok", false) == true,
		"got: %s" % str(query_result))
	var docs_list = query_result.get("documents", [])
	check("query_documents returned Array", docs_list is Array,
		"got type %d" % typeof(docs_list))
	check("query_documents has 1 entry", docs_list.size() == 1,
		"got count=%d" % docs_list.size())
	if docs_list.size() > 0:
		var first_doc: Dictionary = docs_list[0]
		check("query_documents[0] sender == 'test_sender'",
			first_doc.get("sender", "") == "test_sender",
			"got sender='%s'" % str(first_doc.get("sender", "")))
		check("query_documents[0] category == 'test_category'",
			first_doc.get("category", "") == "test_category",
			"got category='%s'" % str(first_doc.get("category", "")))
		check("query_documents[0] sha256 not empty",
			not (first_doc.get("sha256", "") as String).is_empty(),
			"got sha256='%s'" % str(first_doc.get("sha256", "")))

	# --- TEST 3: GET DOCUMENT ---
	print("\n-- test 3: minerva_scansort_get_document --")
	var get_result: Dictionary = await conn.call_tool(
		"minerva_scansort_get_document",
		{"vault_path": vault_abs, "doc_id": doc_id_int}
	)
	check("get_document returned Dictionary", get_result is Dictionary,
		"got type %d" % typeof(get_result))
	check("get_document ok == true",
		get_result.get("ok", false) == true,
		"got: %s" % str(get_result))
	var got_doc: Dictionary = get_result.get("document", {})
	check("get_document document is Dictionary", got_doc is Dictionary,
		"got type %d" % typeof(got_doc))
	check("get_document doc_id matches",
		int(got_doc.get("doc_id", -1)) == doc_id_int,
		"got doc_id=%s" % str(got_doc.get("doc_id", "")))
	check("get_document category == 'test_category'",
		got_doc.get("category", "") == "test_category",
		"got: '%s'" % str(got_doc.get("category", "")))
	check("get_document file_size > 0",
		int(got_doc.get("file_size", 0)) > 0,
		"got file_size=%s" % str(got_doc.get("file_size", 0)))

	# --- TEST 4: EXTRACT DOCUMENT (round-trip) ---
	print("\n-- test 4: minerva_scansort_extract_document --")
	var extract_result: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_document",
		{"vault_path": vault_abs, "doc_id": doc_id_int, "dest": extract_abs}
	)
	check("extract_document returned Dictionary", extract_result is Dictionary,
		"got type %d" % typeof(extract_result))
	check("extract_document ok == true",
		extract_result.get("ok", false) == true,
		"got: %s" % str(extract_result))
	check("extract_document output file exists",
		FileAccess.file_exists(extract_abs))

	# Verify byte-for-byte round-trip
	if FileAccess.file_exists(extract_abs):
		var fr = FileAccess.open(extract_abs, FileAccess.READ)
		var extracted_bytes: PackedByteArray = fr.get_buffer(fr.get_length())
		fr.close()
		check("extract_document round-trip byte match",
			extracted_bytes == fixture_bytes,
			"original_size=%d extracted_size=%d" % [fixture_bytes.size(), extracted_bytes.size()])

	# --- TEST 5: UPDATE DOCUMENT ---
	print("\n-- test 5: minerva_scansort_update_document --")
	var update_result: Dictionary = await conn.call_tool(
		"minerva_scansort_update_document",
		{
			"vault_path": vault_abs,
			"doc_id": doc_id_int,
			"updates": {
				"category": "updated_category",
				"description": "Updated by T6 R1 test",
			}
		}
	)
	check("update_document returned Dictionary", update_result is Dictionary,
		"got type %d" % typeof(update_result))
	check("update_document ok == true",
		update_result.get("ok", false) == true,
		"got: %s" % str(update_result))

	# Re-query to verify update visible
	var query_after: Dictionary = await conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": vault_abs}
	)
	check("query_after_update ok", query_after.get("ok", false) == true,
		"got: %s" % str(query_after))
	var docs_after = query_after.get("documents", [])
	if docs_after.size() > 0:
		var updated_doc: Dictionary = docs_after[0]
		check("update_document category persisted",
			updated_doc.get("category", "") == "updated_category",
			"got: '%s'" % str(updated_doc.get("category", "")))
		check("update_document description persisted",
			updated_doc.get("description", "") == "Updated by T6 R1 test",
			"got: '%s'" % str(updated_doc.get("description", "")))

	# --- TEST 6: VAULT INVENTORY ---
	print("\n-- test 6: minerva_scansort_vault_inventory --")
	var inv_result: Dictionary = await conn.call_tool(
		"minerva_scansort_vault_inventory",
		{"vault_path": vault_abs}
	)
	check("vault_inventory returned Dictionary", inv_result is Dictionary,
		"got type %d" % typeof(inv_result))
	check("vault_inventory ok == true",
		inv_result.get("ok", false) == true,
		"got: %s" % str(inv_result))
	var inv_docs = inv_result.get("documents", [])
	check("vault_inventory documents is Array", inv_docs is Array,
		"got type %d" % typeof(inv_docs))
	check("vault_inventory count == 1", inv_docs.size() == 1,
		"got count=%d" % inv_docs.size())
	var inv_count = inv_result.get("count", -1)
	check("vault_inventory count field == 1", int(inv_count) == 1,
		"got count field=%s" % str(inv_count))

	# --- TEST 7: NEGATIVE — wrong password vault ---
	# We create a vault with a different password, then try to insert a doc.
	# The password is stored in the 'project' table but insert_document doesn't
	# use a password arg (documents.rs doesn't encrypt). So instead we test
	# the vault_path-doesn't-exist negative path more rigorously.
	# For negative crypto path: verify_password with wrong pw returns ok:false.
	print("\n-- test 7: negative — verify_password wrong password --")
	var wrong_pw: Dictionary = await conn.call_tool(
		"minerva_scansort_verify_password",
		{"path": vault_abs, "password": "completely-wrong-password"}
	)
	check("wrong_password verify returns Dictionary", wrong_pw is Dictionary,
		"got type %d" % typeof(wrong_pw))
	# Post-T7-R7: transport ok stays true on dispatch success; verified is the
	# semantic mismatch indicator.
	check("wrong_password verify ok == true (transport succeeded)",
		wrong_pw.get("ok", false) == true,
		"got: %s" % str(wrong_pw))
	check("wrong_password verify verified == false (semantic mismatch)",
		wrong_pw.get("verified", true) == false,
		"got: %s" % str(wrong_pw))
	check("wrong_password verify has no 'error' field",
		not wrong_pw.has("error"),
		"got error field: %s" % str(wrong_pw.get("error", "")))

	# --- TEST 8: NEGATIVE — bad vault_path for insert ---
	print("\n-- test 8: negative — insert_document with bad vault_path --")
	var bad_vault_abs: String = scope_dir.path_join("nonexistent_%s.ssort" % _run_id)
	var bad_insert: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_document",
		{
			"vault_path": bad_vault_abs,
			"file_path": fixture_abs,
			"category": "test",
		}
	)
	check("bad_vault insert returned Dictionary", bad_insert is Dictionary,
		"got type %d" % typeof(bad_insert))
	# Should return an error field (not ok:true)
	check("bad_vault insert returns error",
		bad_insert.has("error") or bad_insert.get("ok", true) == false,
		"got: %s" % str(bad_insert))

	# --- TEST 9: NEGATIVE — missing doc_id for get_document ---
	print("\n-- test 9: negative — get_document with nonexistent doc_id=999 --")
	var bad_get: Dictionary = await conn.call_tool(
		"minerva_scansort_get_document",
		{"vault_path": vault_abs, "doc_id": 999}
	)
	check("get_document(999) returned Dictionary", bad_get is Dictionary,
		"got type %d" % typeof(bad_get))
	check("get_document(999) returns error",
		bad_get.has("error") or bad_get.get("ok", true) == false,
		"got: %s" % str(bad_get))

	# --- TEST 10: NEGATIVE — extract nonexistent doc_id ---
	print("\n-- test 10: negative — extract_document with nonexistent doc_id=999 --")
	var bad_extract: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_document",
		{"vault_path": vault_abs, "doc_id": 999, "dest": extract_abs}
	)
	check("extract_document(999) returned Dictionary", bad_extract is Dictionary,
		"got type %d" % typeof(bad_extract))
	check("extract_document(999) returns error",
		bad_extract.has("error") or bad_extract.get("ok", true) == false,
		"got: %s" % str(bad_extract))

	# --- TEST 11: NEGATIVE — query_documents on bad vault path ---
	print("\n-- test 11: negative — query_documents with bad vault_path --")
	var bad_query: Dictionary = await conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": bad_vault_abs}
	)
	check("bad_vault query returned Dictionary", bad_query is Dictionary,
		"got type %d" % typeof(bad_query))
	check("bad_vault query returns error",
		bad_query.has("error") or bad_query.get("ok", true) == false,
		"got: %s" % str(bad_query))

	# --- TEST 12: NEGATIVE — vault_inventory on bad vault path ---
	print("\n-- test 12: negative — vault_inventory with bad vault_path --")
	var bad_inv: Dictionary = await conn.call_tool(
		"minerva_scansort_vault_inventory",
		{"vault_path": bad_vault_abs}
	)
	check("bad_vault inventory returned Dictionary", bad_inv is Dictionary,
		"got type %d" % typeof(bad_inv))
	check("bad_vault inventory returns error",
		bad_inv.has("error") or bad_inv.get("ok", true) == false,
		"got: %s" % str(bad_inv))

	# --- TEST 13: QUERY with category filter ---
	print("\n-- test 13: query_documents with category filter --")
	var cat_query: Dictionary = await conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": vault_abs, "category": "updated_category"}
	)
	check("category filter query ok", cat_query.get("ok", false) == true,
		"got: %s" % str(cat_query))
	var cat_docs = cat_query.get("documents", [])
	check("category filter returns 1 doc", cat_docs.size() == 1,
		"got count=%d" % cat_docs.size())

	# --- TEST 14: QUERY with non-matching category filter ---
	print("\n-- test 14: query_documents with non-matching category filter --")
	var no_match_query: Dictionary = await conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": vault_abs, "category": "nonexistent_category"}
	)
	check("non-matching query ok", no_match_query.get("ok", false) == true,
		"got: %s" % str(no_match_query))
	var no_docs = no_match_query.get("documents", [])
	check("non-matching category returns 0 docs", no_docs.size() == 0,
		"got count=%d" % no_docs.size())

	# --- CLEANUP ---
	print("\n-- cleanup --")
	DirAccess.remove_absolute(vault_abs)
	DirAccess.remove_absolute(vault_abs + "-wal")
	DirAccess.remove_absolute(vault_abs + "-shm")
	DirAccess.remove_absolute(fixture_abs)
	DirAccess.remove_absolute(extract_abs)
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

	# Remove scansort from PluginDB to avoid cross-run pollution.
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
