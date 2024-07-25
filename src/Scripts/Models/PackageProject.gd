class_name PackageProject
extends RefCounted

## Most of this code was generated using Claude Sonnet

## If `generate_package_file` function failed, this signal is emited
signal package_generation_failed(error: int, message: String)

## Buffer size when reading files for zip import/export.
## Make sure it's a power of 2.
const FILE_READ_BUFFER = 8192

const project_fp = "project.minproj"
const pkg_base_dir = "files"

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
## [codeblock]
## }
## 	"d/shared_proj": [
## 		{ "original": "D:/shared_proj/main.py", "package": "d/shared_proj/main.py" }
## 	]
## }
## [/codeblock]
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
		writer.start_file("%s/%s" % [pkg_base_dir, package_path])

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

	writer.start_file(project_fp)
	writer.write_file(JSON.stringify(project_data).to_utf8_buffer())
	writer.close_file()

	writer.close()

	return OK

#region Unpacking

var _unpack_err: String
func get_unpack_package_file_error() -> String:
	return _unpack_err



## Given the directory path [param dir], ensures it's a valid absolute directory path
## that exists on the filesystem.[br]
## Returns [OK] if so.
func _validate_directory(dir: String) -> int:
	dir = dir.get_base_dir()
	if not dir.is_absolute_path():
		_unpack_err = "Destination parameter (%s) is not valid absolute path."
		return ERR_INVALID_PARAMETER

	# create destination path if it doesn't exist
	if not DirAccess.dir_exists_absolute(dir):
		var dir_err: = DirAccess.make_dir_recursive_absolute(dir)
		
		if dir_err != OK:
			_unpack_err = "Failed assert destination path (%s) exists." % dir
			return dir_err

	return OK

## If error occurred during unpacking of the package,
## this function will clean the partially unpacked files by deleting them
func error_cleanup(paths: PackedStringArray):
	for p in paths:
		print("PackageProject: Cleaning up %s" % p)
		DirAccess.remove_absolute(p)



func unpack_package_file(package_file: String, files_destination: String, project_destination: String) -> int:
	
	# _validate_directory will automatically populate _unpack_err
	var ferr: = _validate_directory(files_destination)
	if ferr != OK: return ferr

	var perr : = _validate_directory(project_destination)
	if perr != OK: return perr

	var reader: = ZIPReader.new()

	var err := reader.open(package_file)
	if err != OK:
		_unpack_err = "Failed to open package file (%s) for reading." % package_file
		return err

	var written_files: = PackedStringArray()

	# No way to read specific buffer size, gotta read the whole file
	var project_data: Dictionary = JSON.parse_string( reader.read_file(project_fp).get_string_from_utf8() )

	var editors: Array[String] = project_data["Editors"]

	for i in range(editors.size()):
		var pkg_path: = editors[i]
		var buffer: = reader.read_file("%s/%s" % [pkg_base_dir, pkg_path])

		var write_path: = "%s/%s" % [files_destination, pkg_path]

		var fa: = FileAccess.open(write_path, FileAccess.WRITE)
		if not fa:
			_unpack_err = "Failed to open file (%s) for writing." % write_path
			error_cleanup(written_files)
			return FileAccess.get_open_error()

		fa.store_buffer(buffer)
		written_files.append(fa.get_path_absolute())

		editors[i] = write_path

	var proj_fa: = FileAccess.open(project_destination, FileAccess.WRITE)
	if not proj_fa:
		_unpack_err = "Failed to open file (%s) for writing." % project_destination
		error_cleanup(written_files)
		return FileAccess.get_open_error() 

	return OK

#endregion