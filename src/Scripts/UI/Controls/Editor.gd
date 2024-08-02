class_name Editor
extends Control

## Editor node is responsible for acting as a CodeEdit or TextureRect
## depending if it handles text or graphics file.
## A file path can be associated with it to save the conent of the node to it

## @tutorial Editor.create(Editor.TYPE.Text)

static var scene = preload("res://Scenes/Editor.tscn")

signal save_dialog(dialog_result: DIALOG_RESULT)
enum DIALOG_RESULT { Save, Cancel, Close }

@onready var code_edit: EditorCodeEdit = %CodeEdit
@onready var texture_rect: TextureRect = %TextureRect
@onready var graphics_editor: GraphicsEditor = %GraphicsEditor
@onready var _note_check_button: CheckButton = %CheckButton

enum TYPE {
	Text,
	Graphics,
	WhiteBoard,
	NOTE_EDITOR
}

## Callable that overrides what happens when user clicks the editor "save" button.
var _save_override: Callable

var file: String
var type: TYPE
var _file_saved := false
var supported_text_exts: PackedStringArray
## Wether the editor can prompt user to save the content.
var prompt_save:= true

 # checks if the editor has been saved at least once
var file_saved_in_disc := false # this is used when you press the save button on the file menu

static func create(type_: TYPE, file_ = null, name = null) -> Editor:
	var editor = scene.instantiate()
	editor.type = type_
	if name:
		editor.name = name
	if file_: 
		editor.file = file_

	match type_:
		Editor.TYPE.Text:
			editor.get_node("%CodeEdit").visible = true
		Editor.TYPE.Graphics:
			editor.get_node("%GraphicsEditor").visible = true

	return editor

func _ready():
	($CloseDialog as ConfirmationDialog).add_button("Close", true, "close")
	if file:
		match type:
			TYPE.Text: _load_text_file(file)
			TYPE.Graphics: _load_graphics_file(file)
	
	_note_check_button.disabled = type != TYPE.Text
	
	#set the text formats that are supported we add a "*" to the start of every ext
	for ext in SingletonObject.supported_text_fortmats:
		ext = "*." +ext 
		supported_text_exts.append(ext)
	$FileDialog.filters = supported_text_exts
	
	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = $FileDialog.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 12)


func _load_text_file(filename: String):
	var fa_object = FileAccess.open(filename, FileAccess.READ)
	code_edit.text = fa_object.get_as_text()
	# %SaveButton.disabled = false


func _load_graphics_file(filename: String):
	var image = Image.load_from_file(filename)
	graphics_editor.setup_from_image(image)
	# %SaveButton.disabled = false

## Changes the function that runs when user clicks the "save" button
## from the [method prompt_close] to [parameter save_function].[br]
## To revert back pass the empty [parameter save_function]:[br]
## [code]override_save(Callable.new())[/code]
func override_save(save_function: Callable) -> void:
	_save_override = save_function


## Prompts user to save the file
## show_save_file_dialog determines if user should be asked wether he wants to save the editor first
## otherwise if shows save file dialog straing away
func prompt_close(show_save_file_dialog := false, new_entry:= false) -> bool:
	#var dialog_filters: = ($FileDialog as FileDialog).filters # we may need to temporarily alter file dialog filters

	match type:
		TYPE.Graphics:
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
		($FileDialog as FileDialog).title = "Save \"%s\" editor" % name

		$FileDialog.popup_centered(Vector2i(700, 500))

		await ($FileDialog as FileDialog).visibility_changed
		#($FileDialog as FileDialog).filters = dialog_filters
	else:
		if new_entry:# this is used for the save as.. feature
			($FileDialog as FileDialog).title = "Save \"%s\" editor" % name
			
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

func is_content_saved() -> bool:
	match type:
		TYPE.Text:
			# cuauh changed this line go back if necesary
			return code_edit.starting_version == code_edit.get_saved_version()
			# return code_edit.get_version() == code_edit.get_saved_version()
		TYPE.Graphics:
			return true
	
	return false


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
	# %SaveButton.disabled = false


func save_file_to_disc(path: String):
	file = path
	match type:
		TYPE.Text:
			var save_file = FileAccess.open(path, FileAccess.WRITE)
			save_file.store_string(code_edit.text)
			
		TYPE.Graphics:
			var dialog = ($FileDialog as FileDialog)
			var _filters = dialog.filters
			dialog.filters = [".png"]
			dialog.filters = _filters

			var img = graphics_editor.image
			if img: img.save_png(path)
			
	_file_saved = true
	file_saved_in_disc = true
	name = get_file_name(path)


func get_file_name(path: String) -> String:
	if path.length() <= 1:
		return path
	var split_path = path.split("/")
	return split_path[split_path.size() -1].split(".")[0]


#region bottom of the pane buttons
func _on_save_button_pressed():
	if _save_override.is_valid():
		_save_override.call()
	else:
		prompt_close(true)


func _on_create_note_button_pressed() -> void:
	if TYPE.Text == type:
		if file:
			SingletonObject.NotesTab.add_note(get_file_name(file), code_edit.text)
		else:
			SingletonObject.NotesTab.add_note("Note from Editor", code_edit.text)
		return
	if TYPE.Graphics == type:
		if file:
			SingletonObject.NotesTab.add_image_note(get_file_name(file), graphics_editor.image, "Sketch")
		else:
			SingletonObject.NotesTab.add_image_note("From file Editor", graphics_editor.image, "Sketch")
		return
	if TYPE.WhiteBoard == type:
		if file:
			SingletonObject.NotesTab.add_image_note(get_file_name(file), %PlaceForScreen.get_viewport().get_texture().get_image(), "white board")
		else:
			SingletonObject.NotesTab.add_image_note("whiteboard", %PlaceForScreen.get_viewport().get_texture().get_image(), "white board")

#endregion bottom of the pane buttons

#region Editor buttons
func delete_chars() -> void:
	if TYPE.Text != type:
		return
	
	code_edit.backspace()
	
	code_edit.grab_focus()


func add_new_line() -> void:
	if TYPE.Text != type:
		return
	code_edit.insert_text_at_caret("\n")
	code_edit.grab_focus()


func undo_action():
	if TYPE.Text != type:
		return
	code_edit.undo()
	code_edit.grab_focus()


func clear_text():
	if TYPE.Text != type:
		return
	%CodeEdit.clear()
	code_edit.grab_focus()


func _on_audio_btn_pressed():
	SingletonObject.AtT.FieldForFilling = %CodeEdit
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %AudioBTN
	%AudioBTN.modulate = Color(Color.LIME_GREEN)

#endregion Editor buttons


## Creates a Note from this Editor.[br]
## If [member type] of this editor is not supported `null` is returned.
func _create_note() -> MemoryItem:
	var memory_item: = SingletonObject.NotesTab.create_note("Editor Note")
	
	if type == TYPE.Text:
		memory_item.Type = SingletonObject.note_type.TEXT
		memory_item.Content = code_edit.text
	
	elif type == TYPE.Graphics:
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
			push_error("ALOOOOOOAA")
		
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