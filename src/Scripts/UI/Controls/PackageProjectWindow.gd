class_name PackageProjectWindow
extends PersistentWindow

@export var destination_label: Label
@export var package_files_tree: Tree
@export var file_dialog: FileDialog

@export var directory_icon: Texture
@export var file_icon: Texture

var data: Dictionary
var files: PackedStringArray
var save_path: String:
	set(value):
		save_path = value
		destination_label.text = "Save Path: %s" % save_path


var com: Dictionary

func _on_about_to_popup():
	save_path = "D:/package.minpackage"
	var common_parents = PackageProject.generate_path_groups(
		[
			"D:/shared_proj/test.py",
			"D:/shared_proj/data/obj.py",
		]
	)
	
	populate_package_files_tree(common_parents)

	com = common_parents



func populate_package_files_tree(common_parents: Dictionary) -> void:
	package_files_tree.clear()

	var root: = package_files_tree.create_item()

	for file_paths in common_parents.values():
		for paths_data in file_paths:
			
			var current: = root
			for section: String in paths_data["package"].split("/"):
				# check if this section already exists as child of the current on
				var section_items = current.get_children().filter(func(item: TreeItem): return item.get_text(0) == section)

				# create new item if theres not one for this section already
				if section_items.is_empty():
					current = current.create_child()
					current.set_text(0, section)
					
					if section.get_extension().is_empty():
						current.set_icon(0, directory_icon)
						current.set_meta("type", "dir")
					else:
						current.set_icon(0, file_icon)
						current.set_meta("type", "file")
						current.set_meta("original_file", paths_data["original"])
				else:
					current = section_items.pop_front()


## Recursively loops through tree items and returns all tree items that represent a file
func _get_file_items(current: TreeItem) -> Array[TreeItem]:
	if current.get_meta("type", "") == "file": return [current]

	var items: Array[TreeItem] = []
	for child in current.get_children():
		items.append_array(_get_file_items(child))

	return items

## Givent tree item, it will go up the hierarchy and compose a string that represents it's path.
func _construct_package_file_path(item: TreeItem) -> String:
	var sections: = PackedStringArray()

	var current: = item
	while current != item.get_tree().get_root():
		sections.append(current.get_text(0))
		current = current.get_parent()

	# since we went from file UP the hierarchy the sections are reversed
	sections.reverse()
	return "/".join(sections)


## Gets file paths from the file tree, handling changes made by user.
func get_final_file_paths() -> Dictionary:
	
	var file_items: = _get_file_items(package_files_tree.get_root())

	var original_files = PackedStringArray()
	var package_files = PackedStringArray()
	
	for item in file_items:
		original_files.append(item.get_meta("original_file"))
		package_files.append(_construct_package_file_path(item))

	return {
		"original_files": original_files,
		"package_files": package_files
	}



func _on_package_button_pressed():
	var packager: = PackageProject.new()

	packager.package_generation_failed.connect(
		func(err: int, message: String):
			print("Error %s: %s" % [error_string(err), message])
	, CONNECT_ONE_SHOT)

	var files_data: = get_final_file_paths()
	packager.generate_package_file(data, files_data["original_files"], files_data["package_files"], "D:/package.zip")


func _on_file_dialog_file_selected(path: String):
	save_path = path


func _on_change_destionation_button_pressed():
	file_dialog.current_path = save_path
	file_dialog.popup_centered()
