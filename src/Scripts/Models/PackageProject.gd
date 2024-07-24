class_name PackageProject
extends RefCounted

## Most of this code was generated using Claude Sonnet

## If `generate_package_file` function failed, this signal is emited
signal package_generation_failed(error: int, message: String)

## Buffer size when reading files for zip import/export.
## Make sure it's a power of 2.
const FILE_READ_BUFFER = 8192


## This function tries to find the lowest common parent directory for all passed file paths.
## Returns the directory path
static func _find_common_parent(paths: Array) -> String:
	if paths.size() == 0:
		return ""

	var normalized_paths = []
	for path in paths:
		normalized_paths.append(path.replace("\\", "/").get_base_dir())

	var split_paths = []
	for path in normalized_paths:
		split_paths.append(path.split("/"))

	var common_prefix = split_paths[0]
	for path_parts in split_paths.slice(1, split_paths.size()):
		var new_prefix = []
		for i in range(min(common_prefix.size(), path_parts.size())):
			if common_prefix[i] == path_parts[i]:
				new_prefix.append(common_prefix[i])
			else:
				break
		common_prefix = new_prefix

	return "/".join(common_prefix)


## Gets package root for the given path.
## Eg. for Windows it returns the drive letter name `C:/` -> `c/`
static func _get_root_path(path: String) -> String:
	var parts = path.split("/")
	if parts[0] == "":
		# Unix-like root
		return "/"
	elif parts[0].length() == 2 and parts[0].ends_with(":"):
		# Windows drive letter
		return parts[0] + "/"
	else:
		# Relative path or other cases
		return ""


## Given the list of file paths this function returns dictionary of files grouped by common parent.
## The dictionary key is group file path, the value is list of directories with `original` and `package` paths for file.
## [code]
## }
## 	"d/shared_proj": [
## 		{ "original": "D:/shared_proj/main.py", "package": "d/shared_proj/main.py" }
## 	]
## }
## [/code]
static func generate_path_groups(open_files: Array) -> Dictionary:
	var root_groups = {}
	var folder_names = {}
	
	# Group files by root directory and collect folder names
	for file in open_files:
		var normalized_path = file.replace("\\", "/")
		var root = _get_root_path(normalized_path)
		var path_parts = normalized_path.split("/")
		
		if path_parts.size() >= 3:  # We need at least drive, folder, and file
			var top_folder = path_parts[1]  # Get the first folder after the drive
			var group_key = root[0].to_lower() + "/" + top_folder
			if not root_groups.has(group_key):
				root_groups[group_key] = []
			root_groups[group_key].append(normalized_path)
			
			if not folder_names.has(top_folder):
				folder_names[top_folder] = []
			if not folder_names[top_folder].has(root):
				folder_names[top_folder].append(root)
	
	var result = {}
	
	# Process each group
	for group_key in root_groups:
		var common_parent = _find_common_parent(root_groups[group_key])
		var package_from = group_key
		
		result[package_from] = []
		for file in root_groups[group_key]:
			var relative_path = file.substr(common_parent.length()).strip_edges(true, false)
			if relative_path.begins_with("/"):
				relative_path = relative_path.substr(1)
			var package_path = package_from + "/" + relative_path if relative_path else package_from
			package_path = package_path.replace("//", "/")  # Remove any double slashes
			result[package_from].append({
				"original": file,
				"package": package_path
			})
	
	return result



static func package_project() -> Dictionary:
	var groups = generate_path_groups(
		[
			"D:/shared_proj/main.py",
			"D:/shared_proj/data/obj.py",
		]
	)

	return groups

## Generates package file that includes project and editor files in one bundle.[br]
## [param project_data] is dictionary that holds serialized data of current project
## that MUST contain [param original_files] open in editor.[br]
## [param original_files] is an array open editor file paths.[br]
## [param package_files] is an array of same size as [param original_files]
## that maps where in bundle the appropriate original file should be placed
## [param save_path] is where the resulting bundle file will be. [br]
## Returns [int] error. To know what happened connect to [signal package_generation_failed]
## before running this function.
func generate_package_file(
	project_data: Dictionary,
	original_files: PackedStringArray,
	package_files: PackedStringArray,
	save_path: String
) -> int:
	project_data = project_data.duplicate(true) # copy the data so the original doesn't get changed
	
	# Make sure both arrays are the same size
	if original_files.size() != package_files.size():
		package_generation_failed.emit(
			ERR_INVALID_DATA,
			"Original and Package file path provided are not the same size (%s != %s)" % [original_files.size(), package_files.size()]
		)
		return ERR_INVALID_DATA
	
	var writer: = ZIPPacker.new()

	var err = writer.open(save_path)
	if err != OK: return err

	# loop through file paths to copy them from original to package destination insize the zip file
	for i in range(original_files.size()):
		var original_path: String = original_files[i]
		var package_path: String = package_files[i]
		
		var fa: = FileAccess.open(original_path, FileAccess.READ)

		if not fa:
			var open_err: = FileAccess.get_open_error()
			package_generation_failed.emit(open_err, "Failed to read the file: %s" % original_path)
			return open_err
		
		# all files go into the `files` directory
		writer.start_file("files/%s" % package_path)

		while fa.get_position() < fa.get_length():
			writer.write_file(fa.get_buffer(FILE_READ_BUFFER))
		
		writer.close_file()
		
		# replace project original path with the package path
		var editors = (project_data["Editors"] as Array[String])
		var idx: = editors.find(fa.get_path())
		if idx == -1:
			package_generation_failed.emit(ERR_INVALID_DATA, "Project data editors doesn't contain editor with path: %s" % fa.get_path())
			return ERR_INVALID_DATA
		editors[idx] = package_path

	writer.start_file("project.minproj")
	writer.write_file(JSON.stringify(project_data).to_utf8_buffer())
	writer.close_file()

	writer.close()

	return OK



