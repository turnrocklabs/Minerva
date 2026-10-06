extends "res://Scripts/Services/Docket/Tools/tool_registry.gd"
## Expose the real scratch DB's path to content recovery journals.

func get_db(project: String = "") -> DocketDB:
	return _project_dbs.get(project, _db)
