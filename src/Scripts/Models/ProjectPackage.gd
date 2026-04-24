class_name ProjectPackage
extends RefCounted

## Buffer size when reading files for zip import/export.
## Make sure it's a power of 2.
const FILE_READ_BUFFER = 8192

const project_fp = "project.minproj" # name of project file inside the zip
const pkg_base_dir = "files" # folder where in zip file packaged files reside
const editor_files_key = "Editors" # Where in project_data are editor paths

## Key used in each Editors[i] manifest entry to record the packed sidecar path.
## Design §9.1: set to the package-relative sidecar path when a sidecar was found.
const sidecar_manifest_key = "sidecar"

## Key used in each Editors[i] manifest entry to record plugin-export metadata.
## Design §8.2: set to a Dictionary with path rewrites when a plugin collect was run.
const plugin_export_manifest_key = "plugin_export"

## Path of the package file
var path: String

## Project data in context of the package file (editor file paths changed).
var data: Dictionary

## Instance of [class ZIPReader] that is reading the package file at [property path].
var reader: ZIPReader

var _error: String

## Returns error message for last failed operation that returned an error code from [enum ERROR].
func get_last_error() -> String:
	return _error

## Opens a [.minpackage] file.[br]
## Returns [OK] on success.
func open_package(package_path: String) -> int:
	close()
	reader = ZIPReader.new()

	var err: = reader.open(package_path)
	if err != OK:
		_error = "Couldn't open the package file."
		return err
	
	if not reader.file_exists(project_fp):
		_error = "Couldn't find %s inside the package file." % project_fp
		return ERR_FILE_NOT_FOUND

	data = JSON.parse_string(reader.read_file(project_fp).get_string_from_utf8())

	path = package_path
	return OK

## Closes the package file reader
func close():
	if reader: reader.close()


## Generates package file that includes project and editor files in one bundle.[br]
## [param project_data] is dictionary that holds serialized data of current project
## that MUST contain [param original_files] open in editor.[br]
## [param original_files] is an array open editor file paths.[br]
## [param package_files] is an array of same size as [param original_files]
## that maps where in bundle the appropriate original file should be placed.[br]
## [param save_path] is where the resulting bundle file will be.[br]
## Returns [int] error. To know what happened use the [method get_last_error] method.
## Note: Call [method collect_plugin_exports] BEFORE this method if you want plugin
## sidecar files to be included in the package (design §8.2).
func save_package(
	project_data: Dictionary,
	original_files: PackedStringArray,
	package_files: PackedStringArray,
	save_path: String
) -> int:
	data = project_data.duplicate(true) # copy the data so the original doesn't get changed
	
	# Make sure both arrays are the same size
	if original_files.size() != package_files.size():
		_error = "Original and Package file path provided are not the same size (%s != %s)" % [original_files.size(), package_files.size()]
		return ERR_INVALID_DATA
	
	var writer: = ZIPPacker.new()

	var err = writer.open(save_path)
	if err != OK: return err

	# loop through file paths to copy them from original to package destination inside the zip file
	for i in range(original_files.size()):
		var original_path: String = original_files[i]
		var package_path: String = package_files[i]
		
		var fa: = FileAccess.open(original_path, FileAccess.READ)

		if not fa:
			_error = "Failed to read the file: %s" % original_path
			return FileAccess.get_open_error()
		
		# all files go into the `files` directory
		writer.start_file("%s/%s" % [pkg_base_dir, package_path])

		while fa.get_position() < fa.get_length():
			writer.write_file(fa.get_buffer(FILE_READ_BUFFER))
		
		writer.close_file()
		
		# replace project original path with the package path
		var editor_file: Dictionary

		for j in range(data["Editors"].size()):
			var e_data = data["Editors"][j]
			if e_data["file"] == fa.get_path():
				editor_file = e_data
		
		if not editor_file:
			_error = "Project data editors doesn't contain editor with path: %s" % fa.get_path()
			return ERR_INVALID_DATA
		
		editor_file["file"] = package_path

		# ── Annotation sidecar (design §9.1) ──────────────────────────────────
		# Check whether a sidecar exists for this document.  A missing sidecar
		# is silently skipped — zero-annotation documents have no sidecar (§7.5).
		var sidecar_disk_path: String = AnnotationSidecar.sidecar_path_for(original_path)
		if FileAccess.file_exists(sidecar_disk_path):
			var sidecar_data: Dictionary = AnnotationSidecar.read_sidecar(original_path)
			if sidecar_data.is_empty():
				# Sidecar exists but couldn't be parsed (corrupt — already backed up
				# by read_sidecar).  Log and continue; pack succeeds without sidecar.
				push_warning(
					("ProjectPackage: sidecar for '%s' exists but could not be read "
					% original_path) +
					"(corrupt?). Skipping sidecar in package."
				)
			else:
				# Rewrite per-annotation payload paths to package-relative form.
				# The registry dispatches to each kind's optional rewrite_paths().
				var registry := AnnotationRegistry.new()
				var rewritten_annotations: Array = []
				for ann in sidecar_data.get("annotations", []):
					rewritten_annotations.append(
						registry.dispatch_rewrite_paths(ann, "pack", pkg_base_dir)
					)
				sidecar_data["annotations"] = rewritten_annotations

				# Write the rewritten sidecar JSON into the zip alongside the document.
				var sidecar_pkg_path: String = ("%s/%s.annotations.json") % [pkg_base_dir, package_path]
				writer.start_file(sidecar_pkg_path)
				writer.write_file(JSON.stringify(sidecar_data).to_utf8_buffer())
				writer.close_file()

				# Record the sidecar entry in the manifest so unpack knows to restore it.
				editor_file[sidecar_manifest_key] = package_path + ".annotations.json"


	writer.start_file(project_fp)
	writer.write_file(JSON.stringify(data).to_utf8_buffer())
	writer.close_file()

	writer.close()

	project_data = data
	path = save_path

	return OK


## Given the directory path [param dir], ensures it's a valid absolute directory path
## that exists on the filesystem.[br]
## Returns [OK] if so.
func _validate_directory(dir: String) -> int:
	dir = dir.get_base_dir()
	if not dir.is_absolute_path():
		_error = "Destination parameter (%s) is not valid absolute path."
		return ERR_INVALID_PARAMETER

	# create destination path if it doesn't exist
	if not DirAccess.dir_exists_absolute(dir):
		var dir_err: = DirAccess.make_dir_recursive_absolute(dir)
		
		if dir_err != OK:
			_error = "Failed assert destination path (%s) exists." % dir
			return dir_err

	return OK

## If error occurred during unpacking of the package,
## this function will clean the partially unpacked files by deleting them
func error_cleanup(paths: PackedStringArray):
	for p in paths:
		print("PackageProject: Cleaning up %s" % p)
		DirAccess.remove_absolute(p)



## Unpack a .minpackage file.[br]
## [param files_destination] is the directory where editor files will be written.[br]
## [param project_destination] is the path where the .minproj file will be written.[br]
## Returns [int] error.
## Note: Call [method apply_plugin_exports] AFTER this method if you want plugin
## absolute-path rewrites to be applied (design §8.2).
func unpack(files_destination: String, project_destination: String) -> int:
	if not reader:
		_error = "Package reader unconfigured."
		return ERR_UNCONFIGURED

	# _validate_directory will automatically populate _error
	var file_err: = _validate_directory(files_destination)
	if file_err != OK: return file_err

	var project_err : = _validate_directory(project_destination)
	if project_err != OK: return project_err

	var written_files: = PackedStringArray()

	# No way to read specific buffer size, gotta read the whole file
	var project_data: Dictionary = JSON.parse_string( reader.read_file(project_fp).get_string_from_utf8() )

	var editors: Array = project_data[editor_files_key]

	for i in range(editors.size()):
		var pkg_path: = str(editors[i]["file"])
		var buffer: = reader.read_file("%s/%s" % [pkg_base_dir, pkg_path])

		var write_path: = "%s/%s" % [files_destination, pkg_path]

		var dir_err: = DirAccess.make_dir_recursive_absolute(write_path.get_base_dir())
		if dir_err != OK:
			_error = "Failed to create the directory (%s)." % write_path.get_base_dir()
			error_cleanup(written_files)
			return DirAccess.get_open_error()


		var fa: = FileAccess.open(write_path, FileAccess.WRITE)
		if not fa:
			_error = "Failed to open file (%s) for writing." % write_path
			error_cleanup(written_files)
			return FileAccess.get_open_error()

		fa.store_buffer(buffer)
		written_files.append(fa.get_path_absolute())

		editors[i]["file"] = write_path

		# ── Annotation sidecar unpack (design §9.2) ───────────────────────────
		# If the manifest entry includes a sidecar field, extract and rewrite it.
		var sidecar_pkg_rel: String = str(editors[i].get(sidecar_manifest_key, ""))
		if not sidecar_pkg_rel.is_empty():
			var sidecar_zip_path: String = "%s/%s" % [pkg_base_dir, sidecar_pkg_rel]
			if reader.file_exists(sidecar_zip_path):
				var sidecar_raw: PackedByteArray = reader.read_file(sidecar_zip_path)
				var sidecar_data: Variant = JSON.parse_string(sidecar_raw.get_string_from_utf8())

				if sidecar_data is Dictionary and (sidecar_data as Dictionary).has("annotations"):
					# Rewrite payload paths from package-relative back to absolute.
					var registry := AnnotationRegistry.new()
					var rewritten_annotations: Array = []
					for ann in (sidecar_data as Dictionary).get("annotations", []):
						rewritten_annotations.append(
							registry.dispatch_rewrite_paths(ann, "unpack", files_destination)
						)
					(sidecar_data as Dictionary)["annotations"] = rewritten_annotations

					# Write the sidecar to disk alongside the unpacked document.
					var sidecar_write_path: String = "%s/%s" % [files_destination, sidecar_pkg_rel]
					var sidecar_dir_err: = DirAccess.make_dir_recursive_absolute(
						sidecar_write_path.get_base_dir()
					)
					if sidecar_dir_err != OK:
						push_warning(
							("ProjectPackage: could not create directory for sidecar '%s'. "
							% sidecar_write_path) +
							"Sidecar not written."
						)
					else:
						var sfa: = FileAccess.open(sidecar_write_path, FileAccess.WRITE)
						if sfa == null:
							push_warning(
								"ProjectPackage: could not write sidecar '%s'." % sidecar_write_path
							)
						else:
							sfa.store_string(JSON.stringify(sidecar_data))
							written_files.append(sfa.get_path_absolute())
				else:
					push_warning(
						("ProjectPackage: sidecar '%s' in package is corrupt or empty. "
						% sidecar_zip_path) +
						"Skipping."
					)
			else:
				push_warning(
					("ProjectPackage: manifest references sidecar '%s' but it is not "
					% sidecar_zip_path) +
					"present in the package. Skipping."
				)

	var proj_fa: = FileAccess.open(project_destination, FileAccess.WRITE)
	if not proj_fa:
		_error = "Failed to open file (%s) for writing." % project_destination
		error_cleanup(written_files)
		return FileAccess.get_open_error()

	proj_fa.store_string(JSON.stringify(project_data))

	return OK


## Async pre-pass for plugin project_export.collect_channel (design §8.2).
##
## Call this BEFORE save_package() when you want plugin-contributed sidecar files
## included in the package.  Mutates `project_data` in-place: for each PLUGIN_SCENE
## editor entry whose plugin declares a collect_channel, the plugin is asked for the
## files it wants packed, those files are written to `staging_dir` (a temporary flat
## directory), and path rewrites are applied to the editor's plugin_state.payload.
## The manifest key `plugin_export` is set on each qualifying editor entry.
##
## `staging_dir` must be a writable absolute path.  Call site creates it; this method
## does NOT clean it up.  PackageProjectWindow feeds it into the `original_files` /
## `package_files` arrays for save_package.
##
## Returns an Array of {original_abs, pack_rel} Dictionaries for any plugin sidecar
## files that should be included in the package alongside the regular editor files.
func collect_plugin_exports(
		project_data: Dictionary,
		plugin_manager,
		staging_dir: String
) -> Array:
	var extra_files: Array = []
	if plugin_manager == null:
		return extra_files

	for editor_entry in project_data.get("Editors", []):
		if not (editor_entry is Dictionary):
			continue
		if editor_entry.get("type") != Editor.Type.PLUGIN_SCENE:
			continue

		var plugin_id: String = str(editor_entry.get("plugin_id", ""))
		if plugin_id.is_empty():
			continue

		var db = plugin_manager.get_db()
		if db == null:
			continue
		var def: PluginDefinition = db.get_by_id(plugin_id)
		if def == null or def.project_export_collect_channel.is_empty():
			continue
		if def.state != PluginDefinition.State.RUNNING:
			push_warning(
				("ProjectPackage.collect_plugin_exports: plugin '%s' not running; " +
				"skipping collect.") % plugin_id
			)
			continue

		var conn = plugin_manager.get_connection(plugin_id)  # MCPServerConnection; untyped for duck-typing in tests
		if conn == null:
			push_warning(
				("ProjectPackage.collect_plugin_exports: no connection for plugin '%s'; " +
				"skipping collect.") % plugin_id
			)
			continue

		var call_result = await conn.call_tool(
			def.project_export_collect_channel,
			{
				"file_path": str(editor_entry.get("file", "")),
				"panel_name": str(editor_entry.get("panel_name", "")),
			}
		)

		if not (call_result is Dictionary):
			push_warning(
				("ProjectPackage.collect_plugin_exports: plugin '%s' collect_channel " +
				"returned unexpected result; skipping.") % plugin_id
			)
			continue

		# Collect plugin-declared sidecar files.
		var files_list: Array = call_result.get("files", [])
		var packed_files: Array[String] = []
		for file_entry in files_list:
			if not (file_entry is Dictionary):
				continue
			var src_abs: String = str(file_entry.get("src_abs", ""))
			var pack_rel: String = str(file_entry.get("pack_rel", ""))
			if src_abs.is_empty() or pack_rel.is_empty():
				continue
			if not FileAccess.file_exists(src_abs):
				push_warning(
					("ProjectPackage.collect_plugin_exports: plugin '%s' returned " +
					"non-existent file '%s'; skipping.") % [plugin_id, src_abs]
				)
				continue
			# Stage the file so save_package can copy it into the zip.
			var staged: String = staging_dir.path_join(pack_rel)
			DirAccess.make_dir_recursive_absolute(staged.get_base_dir())
			DirAccess.copy_absolute(src_abs, staged)
			extra_files.append({"original_abs": staged, "pack_rel": pack_rel})
			packed_files.append(pack_rel)

		# Apply path rewrites to plugin_state.payload.
		var rewrites: Dictionary = call_result.get("paths_to_rewrite", {})
		if not rewrites.is_empty():
			var plugin_state: Dictionary = editor_entry.get("plugin_state", {})
			var payload: Dictionary = plugin_state.get("payload", {}).duplicate(true)
			for field_path in rewrites:
				var pack_rel_val: String = str(rewrites[field_path])
				if payload.has(field_path):
					payload[field_path] = pack_rel_val
			plugin_state["payload"] = payload
			editor_entry["plugin_state"] = plugin_state

		editor_entry[plugin_export_manifest_key] = {
			"packed_files": packed_files,
			"rewrites": rewrites,
		}

	return extra_files


## Async post-pass for plugin project_export.apply_channel (design §8.2).
##
## Call this AFTER unpack() to let plugins rewrite internal absolute paths.
## For each PLUGIN_SCENE editor entry that has a `plugin_export` manifest key,
## the plugin's apply_channel is called with the unpack destination directory.
func apply_plugin_exports(
		project_data: Dictionary,
		files_destination: String,
		plugin_manager
) -> void:
	if plugin_manager == null:
		return

	for editor_entry in project_data.get("Editors", []):
		if not (editor_entry is Dictionary):
			continue
		if editor_entry.get("type") != Editor.Type.PLUGIN_SCENE:
			continue
		var plugin_export_meta: Dictionary = editor_entry.get(plugin_export_manifest_key, {})
		if plugin_export_meta.is_empty():
			continue

		var plugin_id: String = str(editor_entry.get("plugin_id", ""))
		if plugin_id.is_empty():
			continue

		var db = plugin_manager.get_db()
		if db == null:
			continue
		var def: PluginDefinition = db.get_by_id(plugin_id)
		if def == null or def.project_export_apply_channel.is_empty():
			continue
		if def.state != PluginDefinition.State.RUNNING:
			push_warning(
				("ProjectPackage.apply_plugin_exports: plugin '%s' not running; " +
				"skipping apply.") % plugin_id
			)
			continue

		var conn = plugin_manager.get_connection(plugin_id)  # MCPServerConnection; untyped for duck-typing in tests
		if conn == null:
			push_warning(
				("ProjectPackage.apply_plugin_exports: no connection for plugin '%s'; " +
				"skipping apply.") % plugin_id
			)
			continue

		var call_result = await conn.call_tool(
			def.project_export_apply_channel,
			{
				"unpack_dir": files_destination,
				"file_path": str(editor_entry.get("file", "")),
				"panel_name": str(editor_entry.get("panel_name", "")),
			}
		)

		if call_result is Dictionary and call_result.get("isError", false):
			push_warning(
				("ProjectPackage.apply_plugin_exports: plugin '%s' apply_channel " +
				"returned an error: %s") % [plugin_id, str(call_result)]
			)


## This function tries to find the lowest common parent directory for all passed file paths.
## Returns the directory path
static func _find_common_parent(paths: Array) -> String:
	if paths.size() == 0:
		return ""

	var normalized_paths = []
	for path_ in paths:
		normalized_paths.append(path_.replace("\\", "/").get_base_dir())

	var split_paths = []
	for path_ in normalized_paths:
		split_paths.append(path_.split("/"))

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
static func _get_root_path(path_: String) -> String:
	var parts = path_.split("/")
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
