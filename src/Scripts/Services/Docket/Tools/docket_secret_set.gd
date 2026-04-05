extends RefCounted
class_name DocketSecretSet
## MCP tool: store an encrypted secret in the docket vault.


func get_definition() -> Dictionary:
	return {
		"name": "docket_secret_set",
		"description": "Store an encrypted secret in the docket vault. Requires a vault password configured in preferences. Set requires_2fa=true and provide secondary_password for double encryption.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"handle": {"type": "string", "description": "Unique name for this secret (e.g. 'api_key', 'db_password')"},
				"value": {"type": "string", "description": "The secret value to encrypt and store"},
				"requires_2fa": {"type": "boolean", "description": "Whether to double-encrypt with a secondary password"},
				"secondary_password": {"type": "string", "description": "Secondary password for double encryption (required when requires_2fa=true)"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["handle", "value"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var handle: String = str(args.get("handle", "")).strip_edges()
	var value: String = str(args.get("value", ""))
	var requires_2fa: bool = args.get("requires_2fa", false) == true
	var secondary_pw: String = str(args.get("secondary_password", ""))

	if handle.is_empty():
		return {"error": "'handle' is required"}
	if value.is_empty():
		return {"error": "'value' is required"}
	if requires_2fa and secondary_pw.is_empty():
		return {"error": "'secondary_password' is required when requires_2fa is true"}

	# Load vault password
	var password := UserPrefs.load_vault_password()
	if password.is_empty():
		var hint := UserPrefs.load_vault_password_hint()
		var hint_msg := " Hint: %s" % hint if not hint.is_empty() else ""
		return {"error": "Vault password not configured. Set it in Preferences first.%s" % hint_msg}

	# Get or create vault salt
	var salt: PackedByteArray
	var key: PackedByteArray

	if db.has_vault():
		salt = db.get_vault_salt()
		key = VaultCrypto.derive_key(password, salt)
		if not db.verify_vault(key):
			return {"error": "Vault password does not match. Check Preferences."}
	else:
		# First secret — initialize vault
		salt = VaultCrypto.generate_salt()
		key = VaultCrypto.derive_key(password, salt)
		db.init_vault(key, salt)

	var is_update := not db.get_secret_raw(handle).is_empty()

	if requires_2fa:
		var secondary_key := VaultCrypto.derive_key(secondary_pw, salt)
		var outer := VaultCrypto.encrypt_2fa(value, key, secondary_key)
		db.set_secret(handle, outer.ciphertext, outer.iv, outer.mac, true)
	else:
		var encrypted := VaultCrypto.encrypt(value, key)
		db.set_secret(handle, encrypted.ciphertext, encrypted.iv, encrypted.mac, false)

	return {"handle": handle, "status": "updated" if is_update else "created"}
