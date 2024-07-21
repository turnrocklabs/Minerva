class_name PackageProject
extends RefCounted

static func find_common_parent(paths: Array) -> String:
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

static func package_project(open_files: Array) -> Dictionary:
	var root_groups = {}
	var folder_names = {}
	
	# Group files by root directory and collect folder names
	for file in open_files:
		var normalized_path = file.replace("\\", "/")
		var root = get_root_path(normalized_path)
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
		var common_parent = find_common_parent(root_groups[group_key])
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

static func get_root_path(path: String) -> String:
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

static func generate_path_groups() -> Dictionary:
	var groups = package_project(
		[
			"D:/shared_proj/main.py",
			"D:/shared_proj/data/obj.py",
			"D:/shared_proj/data/test.py",
			"D:/shared_proj/src/value.py",
			"D:/minerva/src/main.gdscript",
			"D:/minerva/docs/readme.md",
			"D:/smth/readme.md",
			"C:/smth/test.py",
			"C:/smth/download.bin",
		]
	)

	print(groups)

	return groups
