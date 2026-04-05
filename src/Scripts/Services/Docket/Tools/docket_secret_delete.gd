extends RefCounted
class_name DocketSecretDelete
## MCP tool: delete a secret from the docket vault.


func get_definition() -> Dictionary:
	return {
		"name": "docket_secret_delete",
		"description": "Delete a secret from the docket vault by handle.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"handle": {"type": "string", "description": "Name of the secret to delete"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["handle"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var handle: String = str(args.get("handle", "")).strip_edges()

	if handle.is_empty():
		return {"error": "'handle' is required"}

	if db.delete_secret(handle):
		return {"handle": handle, "deleted": true}
	else:
		return {"error": "Secret not found: %s" % handle}
