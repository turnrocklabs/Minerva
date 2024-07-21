class_name PackageProjectWindow
extends PersistentWindow

@export var original_files_tree: Tree
@export var package_files_tree: Tree

@export var directory_icon: Texture
@export var file_icon: Texture

var data: Dictionary


func _on_about_to_popup():
	var common_parents = PackageProject.generate_path_groups()
	
	populate_package_files_tree(common_parents)
	populate_original_files_tree(common_parents)


func populate_original_files_tree(common_parents: Dictionary) -> void:

	pass


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
				else:
					current = section_items.pop_front()
