extends RefCounted
class_name DocketProjectList


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_list",
		"description": "List all currently loaded docket projects.",
		"inputSchema": {
			"type": "object",
			"properties": {},
		},
	}


@warning_ignore("unused_parameter")
func execute(_args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var projects: Array = []
	for proj_name in project_dbs:
		var pdb: DocketDB = project_dbs[proj_name]
		var entry := {
			"name": proj_name,
			"path": pdb.get_path(),
			"prefix": pdb.get_id_prefix(),
			"primary": pdb == db,
		}
		var meta := pdb.get_project_meta()
		for key in meta:
			entry[key] = meta[key]
		projects.append(entry)
	return {"projects": projects, "count": projects.size()}
