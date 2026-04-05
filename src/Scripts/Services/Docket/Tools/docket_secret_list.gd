extends RefCounted
class_name DocketSecretList
## MCP tool: list all secret handles (no decryption needed).


func get_definition() -> Dictionary:
	return {
		"name": "docket_secret_list",
		"description": "List all secret handles stored in the docket vault. Does not decrypt values.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(_args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	return {"secrets": db.list_secrets()}
