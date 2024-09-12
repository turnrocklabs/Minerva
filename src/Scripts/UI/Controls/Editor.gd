class_name Editor
extends Control
## Editor node is responsible for acting as a CodeEdit or TextureRect
## depending if it handles text or graphics file.
## A file path can be associated with it to save the conent of the node to it

## @tutorial Editor.create(Editor.Type.TEXT)

static var scene = preload("res://Scenes/Editor.tscn")

signal content_changed()
signal save_dialog(dialog_result: DIALOG_RESULT)
enum DIALOG_RESULT { Save, Cancel, Close }

@onready var code_edit: EditorCodeEdit = %CodeEdit
@onready var texture_rect: TextureRect = %TextureRect
@onready var graphics_editor: GraphicsEditor = %GraphicsEditor
@onready var _note_check_button: CheckButton = %CheckButton

enum Type {
	TEXT,
	GRAPHICS,
	WhiteBoard, # TODO: To be removed
	NOTE_EDITOR,
}

## May contain the object that is being edited by this editor.[br]
## Eg. ChatImage, Note, etc..[br]
## Allows switching to existing editor intead of
## opening a new one for same associated object.
var associated_object

## Callable that overrides what happens when user clicks the editor "save" button.
var _save_override: Callable

var tab_title: String = ""
var file: String
var type: Type
var _file_saved := false
var last_save_path: String
var supported_text_exts: PackedStringArray
## Wether the editor can prompt user to save the content.
var prompt_save:= true

 # checks if the editor has been saved at least once
var file_saved_in_disc := false # this is used when you press the save button on the file menu

static func create(type_: Type, file_ = null, name_ = null, associated_object_ = null) -> Editor:
	var editor = scene.instantiate()
	editor.type = type_
	editor.associated_object = associated_object_
	
	if name_:
		editor.tab_title = name_
	if file_: 
		editor.file = file_

	match type_:
		Editor.Type.TEXT, Editor.Type.NOTE_EDITOR:
			editor.get_node("%CodeEdit").visible = true
			editor.get_node("%CodeEdit").text_changed.connect(editor._on_editor_changed)
		Editor.Type.GRAPHICS:
			editor.get_node("%GraphicsEditor").visible = true
			## TODO: Implement changed signal for graphics editor
			# editor.get_node("%GraphicsEditor").changed.connect(editor._on_editor_changed)

	return editor

func _ready():
	($CloseDialog as ConfirmationDialog).add_button("Close", true, "close")
	if file:
		match type:
			Type.TEXT: _load_text_file(file)
			Type.GRAPHICS: _load_graphics_file(file)
	
	_note_check_button.disabled = type != Type.TEXT and type != Type.GRAPHICS
	
	#set the text formats that are supported we add a "*" to the start of every ext
	for ext in SingletonObject.supported_text_fortmats:
		ext = "*." +ext 
		supported_text_exts.append(ext)
	$FileDialog.filters = supported_text_exts
	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = $FileDialog.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 12)
	SingletonObject.UpdateLastSavePath.connect(update_last_path)


func update_last_path(new_path: String) -> void:
	SingletonObject.last_save_path = new_path + "/"


func _load_text_file(filename: String):
	var fa_object = FileAccess.open(filename, FileAccess.READ)
	if fa_object:
		code_edit.text = fa_object.get_as_text()
		code_edit.saved_content = code_edit.text
	# %SaveButton.disabled = false


func _load_graphics_file(filename: String):
	var image = Image.load_from_file(filename)
	graphics_editor.setup_from_image(image)
	# %SaveButton.disabled = false

# func _gui_input(event: InputEvent):
# 	print(event)
# 	if not event is InputEventKey: return

# 	if event.is_action_pressed("save"):
# 		print("SAVEE SAVEEEE ", get_viewport().gui_get_focus_owner())
# 		get_viewport().set_input_as_handled()

## Changes the function that runs when user clicks the "save" button
## from the [method prompt_close] to [parameter save_function].[br]
## To revert back pass the empty [parameter save_function]:[br]
## [code]override_save(Callable.new())[/code]
func override_save(save_function: Callable) -> void:
	_save_override = save_function


## Prompts user to save the file
## show_save_file_dialog determines if user should be asked wether he wants to save the editor first
## otherwise if shows save file dialog straing away
func prompt_close(show_save_file_dialog := false, new_entry:= false, open_in_this_path: String = "") -> bool:
	#var dialog_filters: = ($FileDialog as FileDialog).filters # we may need to temporarily alter file dialog filters
	if open_in_this_path != "":
		$FileDialog.current_path = open_in_this_path
	
	match type:
		Type.GRAPHICS:
			$FileDialog.filters = PackedStringArray(["*.png"])
			
	if not prompt_save: return true
	if not show_save_file_dialog:
		$CloseDialog.popup_centered(Vector2i(300, 100))

		var should_save = await save_dialog
		
		if should_save == DIALOG_RESULT.Cancel:
			return false
		elif should_save == DIALOG_RESULT.Close:
			return true
	
	if not file:
		($FileDialog as FileDialog).title = "Save \"%s\" editor" % tab_title
		var line_edit: LineEdit = $FileDialog.get_line_edit()
		if type == Type.TEXT or type == Type.NOTE_EDITOR:
			line_edit.text = tab_title + "." + SingletonObject.supported_text_fortmats[0]
		else:
			line_edit.text = tab_title
		$FileDialog.popup_centered(Vector2i(700, 500))

		await ($FileDialog as FileDialog).visibility_changed
		#($FileDialog as FileDialog).filters = dialog_filters
	else:
		if new_entry:# this is used for the save as.. feature
			($FileDialog as FileDialog).title = "Save \"%s\" editor" % tab_title
			
			
			$FileDialog.popup_centered(Vector2i(700, 500))
			
			await ($FileDialog as FileDialog).visibility_changed
			#($FileDialog as FileDialog).filters = dialog_filters
		else:
			_on_file_dialog_file_selected(file)
	
	# _file_saved is set when user select a save file in `_on_file_dialog_file_selected`
	# if we saved the file close the editor, and revert the _file_saved
	if _file_saved:
		_file_saved = false
		return true
	# if user canceled the file select dialog, just return to the edtior
	else:
		return false

## Calls the save implementation that could be altered by [method override_save],[br]
## and then updates the unsaved changes icon.
func save():
	if _save_override.is_valid():
		_save_override.call()
	else:
		if SingletonObject.last_saved_path:
			await prompt_close(true, false, SingletonObject.last_save_path)
		else:
			await prompt_close(true)
	
	# Post save emit the signals to update the saved state icon
	match type:
		Type.TEXT, Type.NOTE_EDITOR:
			code_edit.text_changed.emit()
		Type.GRAPHICS:
			pass # TODO: implement for graphics files


func is_content_saved() -> bool:
	match type:
		Type.TEXT:
			return code_edit.text == code_edit.saved_content
		Type.NOTE_EDITOR:
			# Note.gd adds a `associated_object` meta for memory item the note is rendering
			var memory_item: MemoryItem = get_meta('associated_object')
			return code_edit.text == memory_item.Content
		Type.GRAPHICS:
			return true ## TODO: Implement checking if graphics file is saved
	
	return false


func _on_gui_input(event: InputEvent) -> void:
	check_jump_to_line(event)


func _on_code_edit_gui_input(event: InputEvent) -> void:
	check_jump_to_line(event)


func check_jump_to_line(event: InputEvent) -> void:
	if event.is_action_pressed("jump_to_line")and !%JumpToLinePanel.visible and (type == Type.TEXT or type == Type.NOTE_EDITOR):
		var string_format = "you are currently on line %d, character %d, type a line number between %d and %d to jump to"
		var column = code_edit.get_caret_column()
		if column < 1:
			column = 1
		var line = code_edit.get_caret_line()
		if line < 1:
			line = 1
		var line_count = code_edit.get_line_count()
		if line_count < 1:
			line_count = 1
		
		var new_text = string_format % [line, column, 1, line_count]
		%JumpToLineLabel.text = new_text
		%JumpToLineEdit.call_deferred("grab_focus")
		%JumpToLinePanel.call_deferred("show")


func _on_jump_to_line_edit_text_submitted(new_text: String) -> void:
	%JumpToLinePanel.call_deferred("hide")
	var line_to_jump_to: = 0
	if new_text.is_valid_int():
		line_to_jump_to = new_text.to_int()
		code_edit.set_caret_line(line_to_jump_to -1)


func _on_editor_changed():
	%JumpToLineEdit.max_length = str(%CodeEdit.get_line_count()).length()
	content_changed.emit()

func _on_save_dialog_canceled():
	save_dialog.emit(DIALOG_RESULT.Cancel)


func _on_save_dialog_confirmed():
	save_dialog.emit(DIALOG_RESULT.Save)


func _on_close_dialog_custom_action(action: StringName):
	if action == "close":
		save_dialog.emit(DIALOG_RESULT.Close)
		$CloseDialog.hide()


func _on_file_dialog_file_selected(path: String):
	save_file_to_disc(path)


func save_file_to_disc(path: String):
	file = path
	match type:
		Type.TEXT:
			var save_file = FileAccess.open(path, FileAccess.WRITE)
			save_file.store_string(code_edit.text)
			code_edit.tag_saved_version()
			code_edit.saved_content = code_edit.text # update the saved content
			
		Type.GRAPHICS:
			var dialog = ($FileDialog as FileDialog)
			var _filters = dialog.filters
			dialog.filters = [".png"]
			dialog.filters = _filters

			var img = graphics_editor.image
			if img: img.save_png(path)
			
	_file_saved = true
	file_saved_in_disc = true
	#SingletonObject.last_saved_path = path.get_base_dir() + "/"
	SingletonObject.UpdateLastSavePath.emit(path.get_base_dir())
	if SingletonObject.config_has_saved_section("LastSavedPath"):
		SingletonObject.config_clear_section("LastSavedPath")
		SingletonObject.save_to_config_file("LastSavedPath", "path", SingletonObject.last_saved_path)
	tab_title = path.get_file()
	var indx = SingletonObject.editor_pane.Tabs.get_tab_idx_from_control(self)
	SingletonObject.editor_pane.Tabs.set_tab_title(indx, tab_title)


#region bottom of the pane buttons

func _on_save_button_pressed():
	save()


func _on_create_note_button_pressed() -> void:
	if Type.TEXT == type:
		if tab_title:
			SingletonObject.NotesTab.add_note( tab_title, code_edit.text)
		elif file:
			SingletonObject.NotesTab.add_note(file.get_file(), code_edit.text)
		else:
			SingletonObject.NotesTab.add_note("Note from Editor", code_edit.text)
		return
	if Type.GRAPHICS == type:
		if tab_title:
			SingletonObject.NotesTab.add_image_note(tab_title, graphics_editor.image, "Sketch")
		elif file:
			SingletonObject.NotesTab.add_image_note(file.get_file(), graphics_editor.image, "Sketch")
		else:
			SingletonObject.NotesTab.add_image_note("From file Editor", graphics_editor.image, "Sketch")
		return
	if Type.WhiteBoard == type:
		if file:
			SingletonObject.NotesTab.add_image_note(file.get_file(), %PlaceForScreen.get_viewport().get_texture().get_image(), "white board")
		else:
			SingletonObject.NotesTab.add_image_note("whiteboard", %PlaceForScreen.get_viewport().get_texture().get_image(), "white board")


#this functions calls the file linked to the editor to be loaded again into memory
func _on_reload_button_pressed() -> void:
	_load_text_file(file)


#this emits a signal that gets picked by the projectMenuActions to save open editor tabs
func _on_save_open_editor_tabs_button_pressed() -> void:
	SingletonObject.SaveOpenEditorTabs.emit()

#endregion bottom of the pane buttons

#region Top Editor buttons
func delete_chars() -> void:
	if Type.TEXT != type:
		return
	
	code_edit.backspace()
	
	code_edit.grab_focus()


func add_new_line() -> void:
	if Type.TEXT != type:
		return
	code_edit.insert_text_at_caret("\n")
	code_edit.grab_focus()


func undo_action():
	if Type.TEXT != type:
		return
	code_edit.undo()
	code_edit.grab_focus()


func clear_text():
	if Type.TEXT != type:
		return
	%CodeEdit.clear()
	code_edit.grab_focus()


func _on_audio_btn_pressed():
	SingletonObject.AtT.FieldForFilling = %CodeEdit
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %AudioBTN
	%AudioBTN.modulate = Color(Color.LIME_GREEN)

#endregion Top Editor buttons


## Creates a Note from this Editor.[br]
## If [member type] of this editor is not supported `null` is returned.
func _create_note() -> MemoryItem:
	var memory_item: = SingletonObject.NotesTab.create_note("Editor Note")
	
	if type == Type.TEXT:
		memory_item.Type = SingletonObject.note_type.TEXT
		memory_item.Content = code_edit.text
	
	elif type == Type.GRAPHICS:
		memory_item.Type = SingletonObject.note_type.IMAGE
		memory_item.MemoryImage = graphics_editor.image

	else:
		return null # type not supported
	
	return memory_item


func _on_check_button_toggled(toggled_on: bool):
	var item: MemoryItem

	if not has_meta("memory_item"):
		item = _create_note()
		if not item:
			SingletonObject.ErrorDisplay("Failed", "Failed to create memory item from the editor.")
			_note_check_button.button_pressed = false
			return
		
		item.toggled.connect(
			func(on: bool):
				_note_check_button.button_pressed = on
		)

		set_meta("memory_item", item)
		SingletonObject.DetachedNotes.append(item)
	else:
		item = get_meta("memory_item")
		var present = SingletonObject.DetachedNotes.any(func(item_: MemoryItem): return item_ == item)

		if not present:
			SingletonObject.DetachedNotes.append(item)

	item.Enabled = toggled_on
