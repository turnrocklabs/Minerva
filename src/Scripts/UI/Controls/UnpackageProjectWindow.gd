class_name UnpackageProjectWindow
extends PersistentWindow

@onready var _dialog: AcceptDialog = %Dialog

@onready var _package_file_dialog: FileDialog = %LoadPackageFileDialog
@onready  var _package_file_line_edit: LineEdit = %PackageLineEdit
@onready  var _package_file_info_label: Label = %PackagePathInfoLabel

@onready var _package_files_tree: Tree = %FilesTree
@onready  var _export_button: Button = %ExportButton

@onready var _project_path_line_edit: LineEdit = %ProjectPathLineEdit
@onready var _files_path_line_edit: LineEdit = %FilesPathLineEdit

@onready var _project_path_file_dialog: FileDialog = %ProjectPathFileDialog
@onready var _files_path_file_dialog: FileDialog = %FilesPathFileDialog

var _error_path_icon: Texture2D = preload("res://assets/icons/breakpoint.svg")

var _project_export_path_valid: bool = false:
	set(value):
		_project_export_path_valid = value
		_project_path_line_edit.right_icon = null if value else _error_path_icon
		_export_button_update()

var _files_export_path_valid: bool = false:
	set(value):
		_files_export_path_valid = value
		_files_path_line_edit.right_icon = null if value else _error_path_icon
		_export_button_update()

var _export_enabled: bool = false:
	set(value):
		_export_enabled = value
		_export_button.disabled = not value

var package_file: String:
	set(value):
		package_file = value
		_package_file_line_edit.text = value
		_on_package_line_edit_text_changed(value) # setting text above won't trigger the signal itself


var package: ProjectPackage:
	set(value):
		package = value
		_export_button_update()

var separation_in_pixels: = 14

func _ready() -> void:
	#var hbox_dialog: HBoxContainer = %Dialog.get_vbox().get_child(0)
	#hbox_dialog.set("theme_override_constants/separation", 12)
	
	var hbox_load_pack_dialog: HBoxContainer = %LoadPackageFileDialog.get_vbox().get_child(0)
	hbox_load_pack_dialog.set("theme_override_constants/separation", separation_in_pixels)
	
	var hbox_files_path_dialog: HBoxContainer = %FilesPathFileDialog.get_vbox().get_child(0)
	hbox_files_path_dialog.set("theme_override_constants/separation", separation_in_pixels)
	
	var hbox_project_path_dialog: HBoxContainer = %ProjectPathFileDialog.get_vbox().get_child(0)
	hbox_project_path_dialog.set("theme_override_constants/separation", separation_in_pixels)



## Updates the export button disabled state.
## Export button is enabled if project and files paths are valid and there is a loaded package
func _export_button_update():
	prints(_project_export_path_valid, _files_export_path_valid, package != null)
	_export_button.disabled = not (_project_export_path_valid and _files_export_path_valid and package)


func _on_load_package_button_pressed():
	_package_file_dialog.popup_centered()


func _on_load_package_file_dialog_file_selected(path: String):
	package_file = path


func _on_package_line_edit_text_changed(new_text: String):
	if new_text.is_empty():
		_package_file_info_label.text = ""
		return

	package = ProjectPackage.new()
	var err: = package.open_package(new_text)

	if err != OK:
		_package_file_info_label.text = "%s: %s" % [error_string(err), package.get_last_error()]
		return

	var editor_files = package.data["Editors"]

	if editor_files:
		_populate_files_tree(editor_files)
		_package_file_info_label.text = "Succesfully opened package file %s" % package.path.get_file()
	else:
		_package_file_info_label.text = "Couldn't load package file %s. Invalid data." % package.path.get_file()



func _populate_files_tree(paths: PackedStringArray):
	_package_files_tree.clear()

	var root: = _package_files_tree.create_item()

	for path in paths:
		var current: = root
		for section: String in path.split("/"):
			# check if this section already exists as child of the current on
			var section_items = current.get_children().filter(func(item: TreeItem): return item.get_text(0) == section)

			# create new item if theres not one for this section already
			if section_items.is_empty():
				current = current.create_child()
				current.set_text(0, section)
				
				if section.get_extension().is_empty():
					
					current.set_meta("type", "dir")
				else:
					current.set_meta("type", "file")

			else:
				current = section_items.pop_front()


func _validate_project_path(path: String):
	if not path.is_absolute_path() or not path.get_file().is_valid_filename():
		_project_export_path_valid = false

func _on_project_path_change_button_pressed():
	_project_path_file_dialog.popup_centered()

func _on_project_path_file_dialog_file_selected(path: String):
	_project_path_line_edit.text = path
	_project_path_line_edit.text_changed.emit()

## when path changes validate it's correct
func _on_project_path_line_edit_text_changed(new_text: String):
	_project_export_path_valid = true
	_validate_project_path(new_text)



func _validate_files_path(path: String):
	if not path.is_absolute_path() or not path.get_extension().is_empty():
		_files_export_path_valid = false

func _on_files_path_change_button_pressed():
	_files_path_file_dialog.popup_centered()

func _on_files_path_file_dialog_dir_selected(dir: String):
	_files_path_line_edit.text = dir
	_files_path_line_edit.text_changed.emit()

func _on_files_path_line_edit_text_changed(new_text: String):
	_files_export_path_valid = true
	_validate_files_path(new_text)


func _on_export_button_pressed():
	var err: = package.unpack(_files_path_line_edit.text, _project_path_line_edit.text)
	
	if err != OK:
		show_message(error_string(err), package.get_last_error())
		return
	
	show_message(error_string(OK), "Succesfully exported the package file.")
	_dialog.visibility_changed.connect(
		func(): if not _dialog.visible: hide(),
		CONNECT_ONE_SHOT
	)


func show_message(title_: String, message: String) -> void:
	_dialog.title = title_
	_dialog.dialog_text = message
	_dialog.popup_centered()


func _on_close_requested() -> void:
	call_deferred("hide")
	
