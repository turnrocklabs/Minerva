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
@onready var _search_line_edit: LineEdit = %SearchLineEdit
@onready var _exclude_patterns_edit: LineEdit = %ExcludePatternsEdit
@onready var _file_count_label: Label = %FileCountLabel
@onready var _total_size_label: Label = %TotalSizeLabel
@onready var _change_dir_button: Button = %ChangeDirButton

## Common exclude patterns that can be toggled
var _default_exclude_patterns := [".git", ".godot", "node_modules", "__pycache__", ".vs", ".vscode", "bin", "obj"]
var _active_exclude_patterns: Array[String] = []


class PackageObject extends RefCounted:
	var original_path: String
	var item: TreeItem
	var children: Array[PackageObject]
	var file_size: int = 0
	var is_file: bool = false

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
		is_file = file

		item.set_metadata(0, self)

		item.set_text(0, path.get_file())  # Just the folder name
		item.set_icon(0, PackageEditor._file_icon if file else PackageEditor._folder_icon)
		item.add_button(0, PackageEditor._check_on, 0)
		item.collapsed = collapsed

		# Get file size if it's a file
		if is_file and FileAccess.file_exists(path):
			file_size = FileAccess.get_file_as_bytes(path).size()
			item.set_text(1, _format_size(file_size))

	func create_child(subdir: String, file: = false) -> PackageObject:
		var child_item: = item.create_child()

		var obj: = PackageObject.new(child_item, subdir, file, true)

		children.append(obj)

		return obj

	## Get total size of this object and all enabled children
	func get_total_size() -> int:
		if not enabled:
			return 0

		var total := file_size
		for child in children:
			total += child.get_total_size()
		return total

	## Get count of enabled files (not folders)
	func get_file_count() -> int:
		if not enabled:
			return 0

		var count := 1 if is_file else 0
		for child in children:
			count += child.get_file_count()
		return count

	## Check if path matches search query
	func matches_search(query: String) -> bool:
		if query.is_empty():
			return true

		var path_lower := original_path.to_lower()
		var query_lower := query.to_lower()

		return path_lower.contains(query_lower)

	## Helper to format file size
	static func _format_size(bytes: int) -> String:
		var size_float := float(bytes)
		var units := ["B", "kB", "MB", "GB"]
		var unit_index := 0
		while size_float >= 1000.0 and unit_index < units.size() - 1:
			size_float /= 1000.0
			unit_index += 1
		return "%.1f %s" % [size_float, units[unit_index]]


var _root_obj: PackageObject


static func create() -> PackageEditor:
	var pkg_editor: = _scn.instantiate()

	return pkg_editor



func populate_directory_preview_tree(dir: String) -> int:
	_dir_tree.clear()  # Clear existing tree

	# Setup tree columns
	_dir_tree.columns = 2
	_dir_tree.set_column_title(0, "Name")
	_dir_tree.set_column_title(1, "Size")
	_dir_tree.set_column_expand(0, true)
	_dir_tree.set_column_expand(1, false)
	_dir_tree.set_column_custom_minimum_width(1, 80)
	_dir_tree.column_titles_visible = true

	var root_item := _dir_tree.create_item()

	_root_obj = PackageObject.new(root_item, dir)

	# Set default exclude patterns
	_exclude_patterns_edit.text = ", ".join(_default_exclude_patterns)
	_parse_exclude_patterns()

	var dir_access := DirAccess.open(dir)
	if dir_access:
		_populate_dir_recursive(dir_access, _root_obj, dir)
		_update_stats()
		return OK
	else:
		return DirAccess.get_open_error()

func _populate_dir_recursive(dir_access: DirAccess, parent_obj: PackageObject, current_path: String) -> void:
	# Process subdirectories
	dir_access.include_hidden = false
	for subdir in dir_access.get_directories():
		# Check if subdirectory should be excluded
		if _should_exclude(subdir):
			continue

		var absolute_path := current_path.path_join(subdir)
		var subdir_access := DirAccess.open(absolute_path)

		var obj: = parent_obj.create_child(absolute_path)

		if subdir_access:
			_populate_dir_recursive(subdir_access, obj, absolute_path)

	# Process files
	for file in dir_access.get_files():
		# Check if file should be excluded
		if _should_exclude(file):
			continue

		var absolute_path := current_path.path_join(file)
		parent_obj.create_child(absolute_path, true)


## Check if a file or folder name should be excluded
func _should_exclude(item_name: String) -> bool:
	for pattern in _active_exclude_patterns:
		if pattern.is_empty():
			continue

		# Simple pattern matching (exact match or wildcard)
		if pattern.contains("*"):
			# Convert wildcard pattern to regex
			var regex_pattern := pattern.replace(".", "\\.").replace("*", ".*")
			var regex := RegEx.new()
			regex.compile("^" + regex_pattern + "$")
			if regex.search(item_name):
				return true
		elif item_name == pattern or item_name.begins_with(pattern + "."):
			return true

	return false


## Parse exclude patterns from the text field
func _parse_exclude_patterns() -> void:
	_active_exclude_patterns.clear()
	var patterns_text := _exclude_patterns_edit.text

	if patterns_text.is_empty():
		return

	for pattern in patterns_text.split(","):
		var trimmed := pattern.strip_edges()
		if not trimmed.is_empty():
			_active_exclude_patterns.append(trimmed)


## Update file count and total size labels
func _update_stats() -> void:
	if not _root_obj:
		_file_count_label.text = "Files: 0"
		_total_size_label.text = "Size: 0 B"
		return

	var file_count := _root_obj.get_file_count()
	var total_size := _root_obj.get_total_size()

	_file_count_label.text = "Files: %d" % file_count
	_total_size_label.text = "Size: %s" % PackageObject._format_size(total_size)


## Apply search filter to tree (show/hide items based on search)
func _apply_search_filter(query: String) -> void:
	if not _root_obj:
		return

	_apply_search_recursive(_root_obj, query)


## Recursively apply search filter
func _apply_search_recursive(obj: PackageObject, query: String) -> bool:
	var matches := obj.matches_search(query)
	var any_child_matches := false

	# Check children
	for child in obj.children:
		if _apply_search_recursive(child, query):
			any_child_matches = true

	# Show item if it matches or any child matches
	var should_show := matches or any_child_matches or query.is_empty()
	obj.item.visible = should_show

	return should_show


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

	# Update stats when items are toggled
	_update_stats()


func _on_dir_tree_item_activated() -> void:
	var selected_item: = _dir_tree.get_selected()

	var obj: PackageObject = selected_item.get_metadata(0)

	SingletonObject.editor_pane.add(Editor.Type.TEXT, obj.original_path)


func _on_search_text_changed(new_text: String) -> void:
	_apply_search_filter(new_text)


func _on_apply_exclude_button_pressed() -> void:
	if not _root_obj:
		return

	_parse_exclude_patterns()

	# Rebuild the tree with new exclusions
	var dir := _root_obj.original_path
	populate_directory_preview_tree(dir)


func _on_reset_button_pressed() -> void:
	_exclude_patterns_edit.text = ", ".join(_default_exclude_patterns)
	_on_apply_exclude_button_pressed()


func _on_change_dir_button_pressed() -> void:
	_entry_file_dialog.popup_centered()


## Helper to await dialog result - returns true if confirmed, false if canceled
func _await_dialog_result(dialog: AcceptDialog) -> bool:
	# Use array to work around lambda capture-by-value
	var result := [false]
	var done := [false]

	dialog.confirmed.connect(func():
		result[0] = true
		done[0] = true
	)
	dialog.canceled.connect(func():
		result[0] = false
		done[0] = true
	)

	# Wait until one of the signals fires
	while not done[0]:
		await get_tree().process_frame

	return result[0]


func _on_package_button_pressed() -> void:
	if not SingletonObject.autocoder_manager.artifact_registry_adapter:
		SingletonObject.ErrorDisplay("Can't upload", "Please connect to core first!")
		return

	# Show metadata editor dialog (already added to SingletonObject in _create_upload_metadata_dialog)
	var metadata_dialog := _create_upload_metadata_dialog()
	metadata_dialog.popup_centered()

	# Wait for either confirmed or canceled signal
	var result = await _await_dialog_result(metadata_dialog)

	if not result:
		metadata_dialog.queue_free()
		return

	# Extract metadata from dialog using find_child (dynamic nodes don't support % syntax)
	var filename_edit: LineEdit = metadata_dialog.find_child("FilenameEdit", true, false)
	var description_edit: LineEdit = metadata_dialog.find_child("DescriptionEdit", true, false)
	var tags_edit: LineEdit = metadata_dialog.find_child("TagsEdit", true, false)
	var framework_edit: LineEdit = metadata_dialog.find_child("FrameworkEdit", true, false)
	var language_edit: LineEdit = metadata_dialog.find_child("LanguageEdit", true, false)
	var visibility_option: OptionButton = metadata_dialog.find_child("VisibilityOption", true, false)

	var metadata := {
		"filename": filename_edit.text if not filename_edit.text.is_empty() else _root_obj.original_path.get_file() + ".tar.gz",
		"description": description_edit.text,
		"framework": framework_edit.text,
		"language": language_edit.text,
		"visibility": "public" if visibility_option.selected == 0 else "private",
	}

	# Parse tags
	var tags: Array = []
	if not tags_edit.text.is_empty():
		for tag in tags_edit.text.split(","):
			var trimmed := tag.strip_edges()
			if not trimmed.is_empty():
				tags.append(trimmed)

	if not tags.is_empty():
		metadata["tags"] = tags

	metadata_dialog.queue_free()

	# Create artifact (this will handle filtering based on enabled state in a future update)
	var local_artifact: = Artifact.create_from_dir(_root_obj.original_path, metadata)

	if not local_artifact:
		SingletonObject.ErrorDisplay("Can't create", "Can't create artifact for upload")
		return

	var artifact: = await SingletonObject.autocoder_manager.artifact_registry_adapter.upload(local_artifact)

	if not artifact:
		SingletonObject.ErrorDisplay("Can't upload", "Can't upload artifact")
		return

	artifact_uploaded.emit(artifact)

	# Show success dialog with option to view in browser
	_show_upload_success_dialog(artifact)


## Create metadata editor dialog for upload
func _create_upload_metadata_dialog() -> AcceptDialog:
	var dialog := AcceptDialog.new()
	dialog.title = "Upload Artifact - Set Metadata"
	dialog.dialog_text = ""
	dialog.min_size = Vector2i(500, 450)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	dialog.add_child(vbox)

	# Filename
	var filename_label := Label.new()
	filename_label.text = "Filename (will be .tar.gz):"
	vbox.add_child(filename_label)

	var filename_edit := LineEdit.new()
	filename_edit.unique_name_in_owner = true
	filename_edit.name = "FilenameEdit"
	filename_edit.text = _root_obj.original_path.get_file()
	filename_edit.placeholder_text = "my_package"
	vbox.add_child(filename_edit)

	# Description
	var desc_label := Label.new()
	desc_label.text = "Description:"
	vbox.add_child(desc_label)

	var description_edit := LineEdit.new()
	description_edit.unique_name_in_owner = true
	description_edit.name = "DescriptionEdit"
	description_edit.placeholder_text = "Brief description of this package"
	vbox.add_child(description_edit)

	# Tags
	var tags_label := Label.new()
	tags_label.text = "Tags (comma-separated):"
	vbox.add_child(tags_label)

	var tags_edit := LineEdit.new()
	tags_edit.unique_name_in_owner = true
	tags_edit.name = "TagsEdit"
	tags_edit.placeholder_text = "template, starter, game"
	vbox.add_child(tags_edit)

	# Framework
	var framework_label := Label.new()
	framework_label.text = "Framework:"
	vbox.add_child(framework_label)

	var framework_edit := LineEdit.new()
	framework_edit.unique_name_in_owner = true
	framework_edit.name = "FrameworkEdit"
	framework_edit.text = "godot"
	framework_edit.placeholder_text = "godot, unity, react, etc."
	vbox.add_child(framework_edit)

	# Language
	var language_label := Label.new()
	language_label.text = "Language:"
	vbox.add_child(language_label)

	var language_edit := LineEdit.new()
	language_edit.unique_name_in_owner = true
	language_edit.name = "LanguageEdit"
	language_edit.text = "gdscript"
	language_edit.placeholder_text = "gdscript, csharp, javascript, etc."
	vbox.add_child(language_edit)

	# Visibility
	var visibility_label := Label.new()
	visibility_label.text = "Visibility:"
	vbox.add_child(visibility_label)

	var visibility_option := OptionButton.new()
	visibility_option.unique_name_in_owner = true
	visibility_option.name = "VisibilityOption"
	visibility_option.add_item("Public")
	visibility_option.add_item("Private")
	visibility_option.selected = 0
	vbox.add_child(visibility_option)

	SingletonObject.add_child(dialog)

	return dialog


## Show upload success dialog with option to view artifact in browser
func _show_upload_success_dialog(artifact: Artifact) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Upload Successful!"
	dialog.dialog_text = ""
	dialog.min_size = Vector2i(500, 250)
	dialog.ok_button_text = "Close"

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	dialog.add_child(vbox)

	# Success message
	var success_label := Label.new()
	success_label.text = "✓ Artifact uploaded successfully!"
	vbox.add_child(success_label)

	vbox.add_child(HSeparator.new())

	# Artifact details
	var details_label := Label.new()
	details_label.text = "Filename: %s\nSize: %s\nVisibility: %s" % [
		artifact.filename,
		artifact.get_size_formatted(),
		artifact.visibility
	]
	vbox.add_child(details_label)

	# URI (clickable via button)
	var uri_label := Label.new()
	uri_label.text = "URI:"
	vbox.add_child(uri_label)

	var uri_hbox := HBoxContainer.new()
	uri_hbox.add_theme_constant_override("separation", 4)
	vbox.add_child(uri_hbox)

	var uri_edit := LineEdit.new()
	uri_edit.text = artifact.artifact_uri
	uri_edit.editable = false
	uri_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	uri_hbox.add_child(uri_edit)

	var copy_button := Button.new()
	copy_button.text = "Copy"
	copy_button.pressed.connect(func():
		DisplayServer.clipboard_set(artifact.artifact_uri)
		SingletonObject.create_toast_notification("URI copied to clipboard", ToastNotification.Type.INFO)
	)
	uri_hbox.add_child(copy_button)

	vbox.add_child(HSeparator.new())

	# View in browser button
	var view_button := Button.new()
	view_button.text = "📦 View in Artifact Browser"
	view_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var autocoder_mgr = SingletonObject.autocoder_manager  # Capture for lambda
	view_button.pressed.connect(func():
		dialog.hide()
		if autocoder_mgr and autocoder_mgr.submit_job_manager:
			autocoder_mgr.submit_job_manager.open_artifact_browser_with_selection(artifact.artifact_uri)
		else:
			SingletonObject.ErrorDisplay("Can't open browser", "Autocoder manager not available")
	)
	vbox.add_child(view_button)

	SingletonObject.add_child(dialog)
	dialog.popup_centered()
