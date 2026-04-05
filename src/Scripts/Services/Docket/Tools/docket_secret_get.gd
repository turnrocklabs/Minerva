extends RefCounted
class_name DocketSecretGet
## MCP tool: decrypt and retrieve a secret from the docket vault.


func get_definition() -> Dictionary:
	return {
		"name": "docket_secret_get",
		"description": "Retrieve and decrypt a secret from the docket vault. Requires a vault password configured in preferences. For 2FA secrets, provide secondary_password.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"handle": {"type": "string", "description": "Name of the secret to retrieve"},
				"version": {"type": "integer", "description": "Retrieve a specific archived version (optional)"},
				"secondary_password": {"type": "string", "description": "Secondary password for 2FA-protected secrets"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["handle"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var handle: String = str(args.get("handle", "")).strip_edges()

	if handle.is_empty():
		return {"error": "'handle' is required"}

	# Load vault password
	var password := UserPrefs.load_vault_password()
	if password.is_empty():
		var hint := UserPrefs.load_vault_password_hint()
		var hint_msg := " Hint: %s" % hint if not hint.is_empty() else ""
		return {"error": "Vault password not configured. Set it in Preferences first.%s" % hint_msg}

	if not db.has_vault():
		return {"error": "No vault initialized in this docket. Store a secret first."}

	var salt := db.get_vault_salt()
	var key := VaultCrypto.derive_key(password, salt)

	if not db.verify_vault(key):
		return {"error": "Vault password does not match. Check Preferences."}

	# Check if requesting a specific version
	var version: int = int(args.get("version", 0))
	if version > 0:
		var versions := db.get_secret_versions(handle)
		for ver in versions:
			if ver.version == version:
				var ver_plaintext := VaultCrypto.decrypt(ver.ciphertext, ver.iv, ver.mac, key)
				if ver_plaintext.is_empty():
					return {"error": "Decryption failed for '%s' version %d." % [handle, version]}
				return {"handle": handle, "version": version, "value": ver_plaintext}
		return {"error": "Version %d not found for '%s'" % [version, handle]}

	var raw := db.get_secret_raw(handle)
	if raw.is_empty():
		return {"error": "Secret not found: %s" % handle}

	# Check 2FA requirement
	if raw.get("requires_2fa", false):
		var secondary_pw: String = str(args.get("secondary_password", ""))
		if secondary_pw.is_empty():
			return {"error": "This secret requires a secondary password", "requires_2fa": true}
		var secondary_key := VaultCrypto.derive_key(secondary_pw, salt)
		var inner_plaintext := VaultCrypto.decrypt_2fa(raw.ciphertext, raw.iv, raw.mac, key, secondary_key)
		if inner_plaintext.is_empty():
			return {"error": "Decryption failed for '%s'. Wrong secondary password or corrupted data." % handle}
		return {"handle": handle, "value": inner_plaintext, "requires_2fa": true}

	var plaintext := VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)
	if plaintext.is_empty():
		return {"error": "Decryption failed for '%s'. Data may be corrupted." % handle}

	return {"handle": handle, "value": plaintext}
