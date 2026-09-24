extends RefCounted
class_name DocketPersist
## A save barrier: a change a project holds that has not reached its file
## yet (an earlier save failed) is written now. Callers that must know their
## changes are stored, even when a retry changes nothing, end with this.


func get_definition() -> Dictionary:
	return {
		"name": "docket_persist",
		"description": "Make sure every change to a project is saved to its file. Returns an error if it cannot be.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(_args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var unsaved := db.persist()
	if not unsaved.is_empty():
		return {"error": "Docket could not save the project: %s" % unsaved}
	return {"status": "saved"}
