extends RefCounted
class_name DocketMove


func get_definition() -> Dictionary:
	return {
		"name": "docket_move",
		"description": "Move an item from one project to another. Transfers all data (tags, events, comments, attachments) and updates cross-project parent/blocked_by references.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"vault_password": {"type": "string", "description": "Optional vault password for re-encryption; defaults to Preferences"},
				"secondary_password": {"type": "string", "description": "Required to move 2FA vault content"},
				"target_project": {"type": "string", "description": "Name of the target project"},
			},
			"required": ["id", "target_project"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _primary_db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var item_id: String = str(args.get("id", ""))
	var target_project: String = str(args.get("target_project", ""))

	if item_id.is_empty() or target_project.is_empty():
		return {"error": "Missing 'id' or 'target_project'"}

	# If no multi-project context, can't move
	if project_dbs.is_empty():
		return {"error": "No projects loaded — cannot move items"}

	# Find source DB
	var source_db: DocketDB = null
	var source_name: String = ""
	for proj_name in project_dbs:
		var pdb: DocketDB = project_dbs[proj_name]
		if pdb.has_item(item_id):
			source_db = pdb
			source_name = proj_name
			break
	if source_db == null:
		return {"error": "Item not found: %s" % item_id}

	# Find target DB (case-insensitive match)
	var target_db: DocketDB = null
	var canonical_target := target_project
	for proj_name in project_dbs:
		if proj_name.to_lower() == target_project.to_lower():
			target_db = project_dbs[proj_name]
			canonical_target = proj_name
			break
	if target_db == null:
		return {"error": "Target project not found: %s" % target_project}
	if source_db == target_db:
		return {"error": "Item is already in project '%s'" % canonical_target}

	source_db.write_error = ""
	target_db.write_error = ""
	# Export full item (data + events + comments + attachments)
	var exported := source_db.export_item_full(item_id)
	if exported.is_empty():
		return {"error": "Failed to export item %s" % item_id}

	var new_id: String = item_id if DocketDB._is_uuid7(item_id) else target_db.next_uuid7_id()
	var vault_failure := _prepare_vault(args, source_db, target_db, item_id, new_id, exported)
	if not vault_failure.is_empty():
		return {"error": vault_failure}
	var refs_updated := 0

	var failure := target_db.import_item_full(new_id, exported)
	if not failure.is_empty():
		return {"error": "Move import failed: " + failure}
	var unsaved := target_db.persist()
	if not unsaved.is_empty():
		return {"error": "Move destination save failed: " + unsaved}
	source_db.delete_item(item_id)
	if not source_db.write_error.is_empty() or source_db.has_item(item_id):
		return {"error": "Move destination saved, but source deletion failed: " + source_db.write_error}
	unsaved = source_db.persist()
	if not unsaved.is_empty():
		return {"error": "Move destination saved, but source save failed: " + unsaved}
	if not DocketDB._is_uuid7(item_id):
		# Legacy IDs need cross-project references rewritten after deletion.
		var old_qualified := "%s:%s" % [source_name, item_id]
		var new_qualified := "%s:%s" % [canonical_target, new_id]
		for proj_name in project_dbs:
			var pdb: DocketDB = project_dbs[proj_name]
			refs_updated += pdb.rewrite_refs(old_qualified, new_qualified, item_id, new_qualified)

	return {
		"old_id": item_id,
		"new_id": new_id,
		"old_project": source_name,
		"new_project": canonical_target,
		"refs_updated": refs_updated,
	}


## Re-encrypt before import; never copy source ciphertext under a new vault salt.
func _prepare_vault(args: Dictionary, source: DocketDB, target: DocketDB, old_id: String, new_id: String, exported: Dictionary) -> String:
	var records: Array = []
	for suffix in ["", ":notes"]:
		var handle: String = old_id + suffix
		var current := source.get_secret_raw(handle)
		if not current.is_empty():
			current["handle"] = new_id + suffix
			records.append(current)
		for version in source.get_secret_versions(handle):
			version["handle"] = new_id + suffix
			version["requires_2fa"] = current.get("requires_2fa", false)
			records.append(version)
	if records.is_empty():
		return ""
	var password := str(args.get("vault_password", ""))
	if password.is_empty():
		password = UserPrefs.load_vault_password()
	var source_key := VaultCrypto.derive_key(password, source.get_vault_salt())
	if password.is_empty() or not source.verify_vault(source_key):
		return "Move requires the source vault password"
	var salt := target.get_vault_salt() if target.has_vault() else VaultCrypto.generate_salt()
	var target_key := VaultCrypto.derive_key(password, salt)
	if target.has_vault() and not target.verify_vault(target_key):
		return "Destination vault password does not match"
	exported["secrets"] = []
	exported["secret_versions"] = []
	for record in records:
		var plain := VaultCrypto.decrypt(record.ciphertext, record.iv, record.mac, source_key)
		if record.requires_2fa:
			var secondary := str(args.get("secondary_password", ""))
			if secondary.is_empty():
				return "Move requires secondary_password for 2FA vault content"
			plain = VaultCrypto.decrypt_2fa(record.ciphertext, record.iv, record.mac, source_key, VaultCrypto.derive_key(secondary, source.get_vault_salt()))
		if plain.is_empty():
			return "Move vault authentication failed; source retained"
		var encrypted := VaultCrypto.encrypt(plain, target_key)
		if record.requires_2fa:
			encrypted = VaultCrypto.encrypt_2fa(plain, target_key, VaultCrypto.derive_key(str(args.secondary_password), salt))
		record.merge(encrypted, true)
		exported["secret_versions" if record.has("version") else "secrets"].append(record)
	if not target.has_vault():
		exported["vault_init"] = {"key": target_key, "salt": salt}
	return ""
