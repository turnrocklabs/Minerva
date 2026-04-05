extends RefCounted
class_name DocketProjectAdd


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_add",
		"description": "Load a docket project by file path. Creates the file if it doesn't exist and create=true.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "Absolute path to the .dct file"},
				"create": {"type": "boolean", "description": "Create file if missing (default false)"},
			},
			"required": ["path"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var create: bool = args.get("create", false) == true

	if path.is_empty():
		return {"error": "path is required"}

	# Check if already loaded
	for proj_name in project_dbs:
		var pdb: DocketDB = project_dbs[proj_name]
		if pdb.get_path() == path:
			return {"error": "Project already loaded: %s" % proj_name}

	if not FileAccess.file_exists(path) and not create:
		return {"error": "File not found: %s (pass create=true to create)" % path}

	if not add_fn.is_valid():
		return {"error": "Project management not available in this mode"}

	return add_fn.call(path)
