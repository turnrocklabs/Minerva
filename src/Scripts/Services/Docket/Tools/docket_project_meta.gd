extends RefCounted
class_name DocketProjectMeta

const VALID_STAGES := ["experiment", "incubating", "production", "archived", "stalled", "abandoned"]

const VALID_TRANSITIONS := {
	"": ["experiment", "incubating", "production", "archived", "stalled", "abandoned"],
	"experiment": ["incubating", "stalled", "abandoned"],
	"incubating": ["production", "stalled", "abandoned", "experiment"],
	"production": ["archived", "stalled"],
	"stalled": ["experiment", "incubating", "production", "abandoned"],
	"archived": [],
	"abandoned": ["experiment"],
}


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_meta",
		"description": "Get or set project lifecycle metadata (stage, hypothesis, success criteria). Set mode appends an audit trail record.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"action": {
					"type": "string",
					"enum": ["get", "set"],
					"description": "Action to perform",
				},
				"project": {
					"type": "string",
					"description": "Project name (defaults to primary)",
				},
				"stage": {
					"type": "string",
					"enum": ["experiment", "incubating", "production", "archived", "stalled", "abandoned"],
					"description": "Project lifecycle stage",
				},
				"hypothesis": {
					"type": "string",
					"description": "Project hypothesis",
				},
				"success_criteria": {
					"type": "string",
					"description": "Definition of success for this project",
				},
				"promoted_to": {
					"type": "string",
					"description": "Where the project moved when promoted",
				},
				"note": {
					"type": "string",
					"description": "Free-text note explaining this change",
				},
			},
			"required": ["action"],
		},
	}


@warning_ignore("unused_parameter")
func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	# Resolve target DB
	var target_db := db
	var proj_name: String = str(args.get("project", ""))
	if not proj_name.is_empty() and project_dbs.has(proj_name):
		target_db = project_dbs[proj_name]
	elif not proj_name.is_empty():
		return {"error": "Project not found: %s" % proj_name}

	var action: String = str(args.get("action", ""))

	match action:
		"get":
			return _handle_get(target_db)
		"set":
			return _handle_set(args, target_db)
		_:
			return {"error": "Unknown action: %s" % action}


func _handle_get(target_db: DocketDB) -> Dictionary:
	var name: String = target_db.get_project_name()
	var meta: Dictionary = target_db.get_project_meta()
	if meta.is_empty():
		return {"project": name, "stage": "", "note": "No metadata set"}
	var result := {"project": name}
	result.merge(meta)
	return result


func _handle_set(args: Dictionary, target_db: DocketDB) -> Dictionary:
	var new_stage: String = str(args.get("stage", ""))
	if new_stage.is_empty():
		return {"error": "Missing required field: stage"}
	if not new_stage in VALID_STAGES:
		return {"error": "Invalid stage '%s'. Valid stages: %s" % [new_stage, str(VALID_STAGES)]}

	# Check transition validity
	var current_meta: Dictionary = target_db.get_project_meta()
	var current_stage: String = str(current_meta.get("stage", ""))
	var allowed: Array = VALID_TRANSITIONS.get(current_stage, [])
	if not new_stage in allowed:
		return {
			"error": "Cannot transition from '%s' to '%s'. Valid transitions: %s" % [
				current_stage, new_stage, str(allowed)
			]
		}

	# Build metadata dict from args
	var metadata := {"stage": new_stage}
	for field in ["hypothesis", "success_criteria", "promoted_to", "note"]:
		var val: String = str(args.get(field, ""))
		if not val.is_empty():
			metadata[field] = val

	target_db.set_project_meta(metadata)

	var name: String = target_db.get_project_name()
	var result := {"project": name}
	result.merge(target_db.get_project_meta())
	return result
