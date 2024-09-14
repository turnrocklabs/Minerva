class_name PackageProjectWindow
extends PersistentWindow

@export var destination_label: Label
@export var package_files_tree: Tree
@export var file_dialog: FileDialog
@export var dialog: AcceptDialog
@export var info_label: Label

@export_category("Icons")
@export var icon_ignore_true: Texture
@export var icon_ignore_false: Texture
@export var directory_icon: Texture
@export var file_icon: Texture

var data: Dictionary
var files: PackedStringArray
var save_path: String:
	set(value):
		save_path = value
		destination_label.text = "Save Path: %s" % save_path

func _ready() -> void:
	#var hbox_dialog: HBoxContainer = $Dialog.get_vbox().get_child(0)
	#hbox_dialog.set("theme_override_constants/separation", 12)
	
	var hbox_file_dialog: HBoxContainer = $FileDialog.get_vbox().get_child(0)
	hbox_file_dialog.set("theme_override_constants/separation", 14)
	



## Shows a simple [class AcceptDialog]
func show_message(title_: String, message: String) -> void:
	dialog.title = title_
	dialog.dialog_text = message
	dialog.popup_centered()


func _on_about_to_popup():
	save_path = "D:/package.minpackage"
	var file_paths_array = data["Editors"].map(func(f_data: Dictionary): return f_data["file"])

	var common_parents = ProjectPackage.generate_path_groups(file_paths_array)
	
	populate_package_files_tree(common_parents)


## Updates the info label with brief of how many files will be packaged.
func _update_info_label():
	var root: = package_files_tree.get_root()

	var total: = 0
	var ignored: = 0

	var items: Array[TreeItem] = [root]

	while items.size() > 0:
		var item = items.pop_front()
		if item.get_meta("type", "") == "file":
			total += 1
			if item.get_meta("ignored", false):
				ignored += 1

		items.append_array(item.get_children())


	info_label.text = "%s package files (%s ignored)" % [total, ignored]
	


## Sets [param item] ignore state by changing the appearance,[br]
## item [ignored] meta and button icon.
func set_item_ignored_state(item: TreeItem, ignored: bool):
	item.set_meta("ignored", ignored)

	if ignored:
		item.set_custom_color(0, Color.GRAY)
		item.clear_custom_bg_color(0)
		item.set_button(0, 0, icon_ignore_true)
		item.set_button_tooltip_text(0, 0, "Include Item")

	if not ignored:
		item.clear_custom_color(0)
		item.set_custom_bg_color(0, Color(0, 0, 0, 0.5))
		item.set_button(0, 0, icon_ignore_false)
		item.set_button_tooltip_text(0, 0, "Ignore Item")

	for child_item in item.get_children():
		set_item_ignored_state(child_item, ignored)


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
					
					current.add_button(0, icon_ignore_false)

					if section.get_extension().is_empty():
						current.set_icon(0, directory_icon)
						
						current.set_meta("type", "dir")
					else:
						current.set_icon(0, file_icon)
						current.set_meta("type", "file")
						current.set_meta("original_file", paths_data["original"])

				else:
					current = section_items.pop_front()
				
				set_item_ignored_state(current, false)
	
	_update_info_label()

## Recursively loops through tree items and returns all tree items that represent a file
func _get_file_items(current: TreeItem) -> Array[TreeItem]:
	# if item is ignored
	var ignored = current.get_meta("ignored", false)
	if ignored: return []

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
	var packager: = ProjectPackage.new()

	var files_data: = get_final_file_paths()
	var err: = packager.save_package(data, files_data["original_files"], files_data["package_files"], save_path)

	if err != OK:
		show_message(error_string(err), packager.get_last_error())
		return

	show_message("Success", "Successfully saved package at %s" % save_path)
	dialog.visibility_changed.connect(
		func(): if not dialog.visible: hide(),
		CONNECT_ONE_SHOT
	)

func _on_file_dialog_file_selected(path: String):
	save_path = path


func _on_change_destionation_button_pressed():
	file_dialog.current_path = save_path
	file_dialog.popup_centered()


func _on_files_tree_button_clicked(item: TreeItem, _column: int, _id: int, mouse_button_index: int):
	if mouse_button_index != MOUSE_BUTTON_LEFT: return

	# current ignored state will be opposite of previously ignored state which is by default false
	var ignored = not item.get_meta("ignored", false)

	set_item_ignored_state(item, ignored)

	_update_info_label()


func _on_close_requested() -> void:
	call_deferred("hide")
