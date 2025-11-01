class_name PackageEditor
extends VBoxContainer

static var _scn: = preload("res://Scripts/UI/Controls/PackageEditor/PackageEditor.tscn")

static var _file_icon: = preload("res://assets/icons/file/file.svg")
static var _folder_icon: = preload("res://assets/icons/folder.svg")


@onready var _package_margin_container: MarginContainer = %PackageMarginContainer
@onready var _dir_tree: Tree = %DirTree
@onready var _entry_margin_container: MarginContainer = %EntryMarginContainer
@onready var _entry_file_dialog: FileDialog = %EntryFileDialog

static func create() -> PackageEditor:
	var pkg_editor: = _scn.instantiate()

	return pkg_editor



func populate_directory_preview_tree(dir: String) -> int:
	_dir_tree.clear()  # Clear existing tree
	var root_item := _dir_tree.create_item()
	root_item.set_text(0, dir.get_file())  # Just the folder name
	root_item.set_icon(0, _folder_icon)
	
	var dir_access := DirAccess.open(dir)
	if dir_access:
		_populate_dir_recursive(dir_access, root_item, dir)
		return OK
	else:
		return DirAccess.get_open_error()

func _populate_dir_recursive(dir_access: DirAccess, parent_item: TreeItem, current_path: String) -> void:
	# Process subdirectories
	for subdir in dir_access.get_directories():
		var item := parent_item.create_child()
		item.set_text(0, subdir)
		item.set_icon(0, _folder_icon)
		item.collapsed = true
		
		var subdir_path := current_path.path_join(subdir)
		var subdir_access := DirAccess.open(subdir_path)
		if subdir_access:
			_populate_dir_recursive(subdir_access, item, subdir_path)
	
	# Process files
	for file in dir_access.get_files():
		var item := parent_item.create_child()
		item.set_text(0, file)
		item.set_icon(0, _file_icon)
		
	

func _on_select_entry_dir_button_pressed() -> void:
	_entry_file_dialog.popup_centered()


func _on_entry_file_dialog_dir_selected(dir: String) -> void:

	var err: = populate_directory_preview_tree(dir)

	if err != OK:
		SingletonObject.ErrorDisplay(
			"Can't access",
			"An error occurred when trying to access the path: %s (%s)" % [dir, error_string(DirAccess.get_open_error())]
		)

		return

	_entry_margin_container.visible = false
	_package_margin_container.visible = true
