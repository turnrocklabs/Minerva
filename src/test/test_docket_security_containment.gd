extends SceneTree
## Real JSONL/SQLite projects; executor owns running this suite.
var failures := 0
var folder := ""

func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func check(label: String, condition: bool) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + label)

func decrypt(db: DocketDB, handle: String, password: String) -> String:
	var raw := db.get_secret_raw(handle)
	if raw.is_empty():
		return ""
	return VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, VaultCrypto.derive_key(password, db.get_vault_salt()))

func _run() -> void:
	folder = OS.get_cache_dir().path_join("minerva_security_%d" % randi())
	DirAccess.make_dir_recursive_absolute(folder)
	var source := DocketDBJsonl.create_new_jsonl(folder.path_join("source.jsonl"))
	var target := DocketDBJsonl.create_new_jsonl(folder.path_join("target.jsonl"))
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://Scripts/Services/Docket/Core/data/schema.json"))
	# Deferred load: tool dependencies require the autoloads to exist.
	var registry = load("res://Scripts/Services/Docket/Tools/tool_registry.gd").new()
	registry.init(schema, source, {"source": source, "target": target})
	var id := "01a00000000070008000000000000001"
	var other := "01a00000000070008000000000000002"
	source.insert_item(id, DataModel.create_item(schema, "work_item", {"title": "Source candidate", "tags": ["security"]}))
	target.insert_item(other, DataModel.create_item(schema, "work_item", {"title": "Target candidate"}))
	for filter in [
		{"title); DROP TABLE items;--": "x"}, {"unknown__in": ["x"]},
		{"conditions": [{"field": "title OR 1=1", "value": "x"}]},
		{"$or": [{"field": "unknown", "value": "x"}]},
		{"field": "title", "value": "x", "1=1 OR id": 0},
		{"conditions": [{"$or": [], "field": "title OR 1=1", "value": "x"}]},
		{"$and": [{"conditions": [], "field": "title); DROP TABLE items;--"}]},
		{"OR": [{"field": "title", "value": "x"}]},
	]:
		var refused: Dictionary = registry.call_tool("docket_query", {"filter": filter})
		check("invalid filter refused with item table intact", str(refused.get("error", "")).contains("Invalid filter field") and source.has_item(id) and source.get_item(id).title == "Source candidate")
	for filter in [
		{"status__in": [source.get_item(id).status], "tags_contains": "security"},
		{"$and": [{"field": "tags", "value": "security"}, {"$or": [{"field": "title", "value": "Source candidate"}]}]},
		{"conditions": [{"field": "tags", "value": "security"}, {"conj": "AND", "field": "title", "value": "Source candidate"}]},
	]:
		var valid: Dictionary = registry.call_tool("docket_query", {"filter": filter})
		check("valid filters still return rows", not valid.has("error") and valid.get("count", 0) == 1)
	var unique_id := "02b00000000070008000000000000003"
	source.insert_item(unique_id, DataModel.create_item(schema, "work_item", {"title": "Unique prefix"}))
	var unique: Dictionary = registry.call_tool("docket_get", {"id": "02b0"})
	check("unique prefix resolves", not unique.has("error") and str(unique).contains(unique_id))
	var ambiguity: Dictionary = registry.call_tool("docket_get", {"id": "01a0"})
	check("ambiguity names both projects and items", ambiguity.get("error", "").contains("Source candidate") and ambiguity.get("error", "").contains("Target candidate") and ambiguity.error.contains("source:") and ambiguity.error.contains("target:"))
	var before := FileAccess.get_file_as_bytes(source.get_path())
	var writes := source.writes
	var unknown: Dictionary = registry.call_tool("docket_mirror", {"source_id": id, "target_id": id, "target_project": "missing", "fields": {"title": "Corrupted"}})
	check("unknown mirror project writes nothing", unknown.has("error") and source.writes == writes and FileAccess.get_file_as_bytes(source.get_path()) == before and source.get_item(id).title == "Source candidate")
	for number in range(12):
		var crowded_id := "03c000000000700080000000%08x" % number
		target.insert_item(crowded_id, DataModel.create_item(schema, "work_item", {"title": "Crowded candidate"}))
	var crowded: Dictionary = registry.call_tool("docket_get", {"id": "03c0"})
	check("large ambiguity stays bounded", crowded.get("error", "").begins_with("Ambiguous ID") and str(crowded.error).length() < 1000)
	# The primary can be named even when it is absent from project_dbs.
	registry.init(schema, source, {"target": target})
	var named_primary: Dictionary = registry.call_tool("docket_mirror", {"source_id": unique_id, "target_id": unique_id, "target_project": source.get_project_name(), "fields": {"title": "Unique prefix"}})
	check("named primary mirror works", not named_primary.has("error") and source.get_item(unique_id).title == "Unique prefix")
	registry.init(schema, source, {"source": source, "target": target})
	# Different salts force real destination re-encryption, including history.
	var password := "temporary-test-password"
	for db in [source, target]:
		var salt := VaultCrypto.generate_salt()
		db.init_vault(VaultCrypto.derive_key(password, salt), salt)
	var unrelated := VaultCrypto.encrypt("source remains readable", VaultCrypto.derive_key(password, source.get_vault_salt()))
	source.set_secret("unrelated", unrelated.ciphertext, unrelated.iv, unrelated.mac)
	for handle in [id, id + ":notes"]:
		var encrypted := VaultCrypto.encrypt("old " + handle, VaultCrypto.derive_key(password, source.get_vault_salt()))
		source.set_secret(handle, encrypted.ciphertext, encrypted.iv, encrypted.mac)
		encrypted = VaultCrypto.encrypt("current " + handle, VaultCrypto.derive_key(password, source.get_vault_salt()))
		source.rotate_secret(handle, encrypted.ciphertext, encrypted.iv, encrypted.mac, "test")
	var wrong: Dictionary = registry.call_tool("docket_move", {"id": id, "target_project": "target", "vault_password": "wrong"})
	check("wrong password retains readable source", wrong.has("error") and source.has_item(id) and decrypt(source, id, password) == "current " + id and not target.has_item(id))
	# A future destination is refused by the existing mutation guard.
	var future_path := folder.path_join("future.jsonl")
	var future := FileAccess.open(future_path, FileAccess.WRITE)
	future.store_string(FileAccess.get_file_as_string(target.get_path()).replace('"1.0.0"', '"2.0.0"'))
	future.close()
	var readonly := DocketDBJsonl.open_jsonl(future_path)
	registry.init(schema, source, {"source": source, "future": readonly})
	var refused_move: Dictionary = registry.call_tool("docket_move", {"id": id, "target_project": "future", "vault_password": password})
	check("readonly destination retains source", refused_move.has("error") and source.has_item(id) and not readonly.has_item(id))
	readonly.close()
	registry.init(schema, source, {"source": source, "target": target})
	# Fail after initializing a previously vaultless destination inside import.
	var vaultless := DocketDBJsonl.create_new_jsonl(folder.path_join("vaultless.jsonl"))
	var orphan := VaultCrypto.encrypt("collision", VaultCrypto.derive_key(password, source.get_vault_salt()))
	vaultless.set_secret(id, orphan.ciphertext, orphan.iv, orphan.mac)
	var vaultless_bytes := FileAccess.get_file_as_bytes(vaultless.get_path())
	var vaultless_meta := vaultless._exec_select("SELECT key, value FROM docket_meta ORDER BY key;").duplicate(true)
	registry.init(schema, source, {"source": source, "vaultless": vaultless})
	var late_failure: Dictionary = registry.call_tool("docket_move", {"id": id, "target_project": "vaultless", "vault_password": password})
	check("failed move rolls back SQL and JSONL vault metadata", late_failure.has("error") and vaultless._exec_select("SELECT key, value FROM docket_meta ORDER BY key;") == vaultless_meta and FileAccess.get_file_as_bytes(vaultless.get_path()) == vaultless_bytes and not vaultless.has_vault() and not vaultless.has_item(id))
	check("late import failure preserves source", source.has_item(id) and decrypt(source, id, password) == "current " + id)
	vaultless.delete_secret(id)
	source.set_secret(unique_id, orphan.ciphertext, orphan.iv, orphan.mac)
	var first_vault_move: Dictionary = registry.call_tool("docket_move", {"id": unique_id, "target_project": "vaultless", "vault_password": password})
	check("first destination vault commits with readable ciphertext", not first_vault_move.has("error") and vaultless.has_vault() and not source.has_item(unique_id) and decrypt(vaultless, unique_id, password) == "collision")
	vaultless.close()
	DirAccess.remove_absolute(folder.path_join("vaultless.jsonl.cache"))
	vaultless = DocketDBJsonl.open_jsonl(folder.path_join("vaultless.jsonl"))
	check("first destination vault persists", decrypt(vaultless, unique_id, password) == "collision")
	vaultless.close()
	registry.init(schema, source, {"source": source, "target": target})
	# An import collision must roll back instead of deleting the source.
	target.insert_item(id, DataModel.create_item(schema, "work_item", {"title": "Collision"}))
	var collision: Dictionary = registry.call_tool("docket_move", {"id": id, "target_project": "target", "vault_password": password})
	check("failed import retains source and vault", collision.has("error") and source.has_item(id) and decrypt(source, id, password) == "current " + id)
	target.delete_item(id)
	target.write_error = ""
	var moved: Dictionary = registry.call_tool("docket_move", {"id": id, "target_project": "target", "vault_password": password})
	check("move succeeds and destination is readable", not moved.has("error") and not source.has_item(id) and target.has_item(id) and decrypt(target, id, password) == "current " + id)
	check("source vault remains readable", decrypt(source, "unrelated", password) == "source remains readable")
	source.close()
	target.close()
	DirAccess.remove_absolute(folder.path_join("source.jsonl.cache"))
	source = DocketDBJsonl.open_jsonl(folder.path_join("source.jsonl"))
	check("persisted source vault readable", decrypt(source, "unrelated", password) == "source remains readable")
	source.close()
	# Force rebuild from persisted JSONL rather than trusting the cache.
	DirAccess.remove_absolute(folder.path_join("target.jsonl.cache"))
	target = DocketDBJsonl.open_jsonl(folder.path_join("target.jsonl"))
	for handle in [id, id + ":notes"]:
		check("persisted vault entry readable", decrypt(target, handle, password) == "current " + handle)
		var versions := target.get_secret_versions(handle)
		check("persisted history exists", versions.size() == 1)
		if versions.size() == 1:
			var version: Dictionary = versions[0]
			check("persisted history readable", VaultCrypto.decrypt(version.ciphertext, version.iv, version.mac, VaultCrypto.derive_key(password, target.get_vault_salt())) == "old " + handle)
	target.close()
	var dir := DirAccess.open(folder)
	for file in dir.get_files():
		DirAccess.remove_absolute(folder.path_join(file))
	DirAccess.remove_absolute(folder)
	print("Security containment: %d failures" % failures)
	quit(1 if failures else 0)
