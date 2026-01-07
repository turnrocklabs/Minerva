class_name PackageEditor
extends VBoxContainer

## Emitted when user selects the package root directory
signal directory_selected(path: String)

## Emitted when a local artifact has been uploaded to artifact registry
signal artifact_uploaded(artifact: Artifact)

static var _scn: = preload("res://Scripts/UI/Controls/PackageEditor/PackageEditor.tscn")

@warning_ignore("unused_private_class_variable")
static var _file_icon: = preload("res://assets/icons/file/file.svg")
@warning_ignore("unused_private_class_variable")
static var _folder_icon: = preload("res://assets/icons/folder.svg")
@warning_ignore("unused_private_class_variable")
static var _check_off: = preload("res://assets/icons/unchecked.svg")
@warning_ignore("unused_private_class_variable")
static var _check_on: = preload("res://assets/icons/checked.svg")

@onready var _package_margin_container: MarginContainer = %PackageMarginContainer
@onready var _dir_tree: Tree = %DirTree
@onready var _entry_margin_container: MarginContainer = %EntryMarginContainer
@onready var _entry_file_dialog: FileDialog = %EntryFileDialog


class PackageObject extends RefCounted:
	var original_path: String
	var item: TreeItem
	var children: Array[PackageObject]
	
	var enabled: = true:
		set(value):
			enabled = value
			item.set_button(0, 0, PackageEditor._check_on if enabled else PackageEditor._check_off)
			
			@warning_ignore("STANDALONE_TERNARY")
			item.clear_custom_bg_color(0) if enabled else item.set_custom_bg_color(0, Color.DIM_GRAY)

			for child in children:
				child.enabled = value


	func _init(item_: TreeItem, path: String, file: = false, collapsed: = false) -> void:
		original_path = path
		item = item_

		item.set_metadata(0, self)

		item.set_text(0, path.get_file())  # Just the folder name
		item.set_icon(0, PackageEditor._file_icon if file else PackageEditor._folder_icon)
		item.add_button(0, PackageEditor._check_on, 0)
		item.collapsed = collapsed

	func create_child(subdir: String, file: = false) -> PackageObject:
		var child_item: = item.create_child()

		var obj: = PackageObject.new(child_item, subdir, file, true)

		children.append(obj)

		return obj


var _root_obj: PackageObject


static func create() -> PackageEditor:
	var pkg_editor: = _scn.instantiate()

	return pkg_editor



func populate_directory_preview_tree(dir: String) -> int:
	_dir_tree.clear()  # Clear existing tree
	var root_item := _dir_tree.create_item()
	
	_root_obj = PackageObject.new(root_item, dir)
	
	var dir_access := DirAccess.open(dir)
	if dir_access:
		_populate_dir_recursive(dir_access, _root_obj, dir)
		return OK
	else:
		return DirAccess.get_open_error()

func _populate_dir_recursive(dir_access: DirAccess, parent_obj: PackageObject, current_path: String) -> void:
	# Process subdirectories
	dir_access.include_hidden = true
	for subdir in dir_access.get_directories():
		var absolute_path := current_path.path_join(subdir)
		var subdir_access := DirAccess.open(absolute_path)
		
		var obj: = parent_obj.create_child(absolute_path)

		if subdir_access:
			_populate_dir_recursive(subdir_access, obj, absolute_path)
	
	# Process files
	for file in dir_access.get_files():
		var absolute_path := current_path.path_join(file)
		parent_obj.create_child(absolute_path, true)
	

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

	directory_selected.emit(dir)


func _on_dir_tree_button_clicked(item: TreeItem, _column: int, _id: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT: return

	var obj: PackageObject = item.get_metadata(0)
	obj.enabled = not obj.enabled


func _on_dir_tree_item_activated() -> void:
	var selected_item: = _dir_tree.get_selected()

	var obj: PackageObject = selected_item.get_metadata(0)

	SingletonObject.editor_pane.add(Editor.Type.TEXT, obj.original_path)


func _on_package_button_pressed() -> void:
	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't upload", "Please connect to core first!")
		return
	

	var local_artifact: = Artifact.create_from_dir(
		_root_obj.original_path,
		{
			"filename": _root_obj.original_path.get_file(),
			"description": "test description",
		}
	)

	if not local_artifact:
		SingletonObject.ErrorDisplay("Can't create", "Can't create artifact for upload")
		return

	var artifact: = await SingletonObject.autocoder_manager.artifact_registry_adapter.upload(local_artifact)

	if not artifact:
		SingletonObject.ErrorDisplay("Can't upload", "Can't upload artifact")
		return
	
	SingletonObject.create_toast_notification(
		"Artifact %s uploaded" % artifact.filename,
		ToastNotification.Type.SUCCESS
	)

	artifact_uploaded.emit(artifact)
