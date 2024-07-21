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
@onready var whiteB = %WhiteBoard
@onready var graphics_editor = %GraphicsEditor
@onready var _note_check_button: CheckButton = %CheckButton

enum TYPE {
	Text,
	Graphics,
	WhiteBoard,
}

var file: String
var type: TYPE
var _file_saved := false

## Wether the editor can prompt user to save the content.
var prompt_save:= true

 # checks if the editor has been saved at least once
var file_saved_in_disc := false # this is used when you press the save button on the file menu

static func create(type_: TYPE, file_ = null) -> Editor:
	var editor = scene.instantiate()
	editor.type = type_
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


func _load_text_file(filename: String):
	var fa_object = FileAccess.open(filename, FileAccess.READ)
	code_edit.text = fa_object.get_as_text()
	%SaveButton.disabled = false


func _load_graphics_file(filename: String):
	var image = Image.load_from_file(filename)
	graphics_editor.setup_from_image(image)
	%SaveButton.disabled = false

	# var texture_item = ImageTexture.create_from_image(image)
	# whiteB.get_node("%EditPic").texture = texture_item
	#texture_rect.texture = texture_item

## Prompts user to save the file
## show_save_file_dialog determines if user should be asked wether he wants to save the editor first
## otherwise if shows save file dialog straing away
func prompt_close(show_save_file_dialog := false) -> bool:
	var dialog_filters: = ($FileDialog as FileDialog).filters # we may need to temporarily alter file dialog filters

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
		($FileDialog as FileDialog).filters = dialog_filters
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
	%SaveButton.disabled = false


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

#region bottom of the pane buttons
func _on_save_button_pressed():
	prompt_close(true)


func _on_create_note_button_pressed() -> void:
	if TYPE.Text == type:
		SingletonObject.NotesTab.add_note("Note from Editor", code_edit.text)
		return
	if TYPE.Graphics == type:
		SingletonObject.NotesTab.add_image_note("From file Editor", graphics_editor.image, "Sketch")
		return
	if TYPE.WhiteBoard == type:
		SingletonObject.NotesTab.add_image_note("whiteboard", %PlaceForScreen.get_viewport().get_texture().get_image(), "white board")
		return

#endregion bottom of the pane buttons

func delete_chars() -> void:
	if TYPE.Text != type:
		return
	if code_edit.get_selected_text().length() < 1:
		code_edit.backspace()
		code_edit.grab_focus()
		return
	code_edit.delete_selection()
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


func create_note() -> MemoryItem:
	if TYPE.Text == type:
		return await SingletonObject.NotesTab.add_note("Editor Note", code_edit.text)
	
	elif TYPE.Graphics == type:
		return await SingletonObject.NotesTab.add_image_note("Editor Note", graphics_editor.image, "Sketch")

	elif TYPE.WhiteBoard == type:
		return await SingletonObject.NotesTab.add_image_note("Editor Note", %PlaceForScreen.get_viewport().get_texture().get_image(), "white board")
	
	return null


func _on_check_button_toggled(toggled_on: bool):
	if not type in [TYPE.Text]: return # only works for text editors for now

	# If memory item is somehow deleted from `SingletonObject.ThreadList` this will break
	# but user can't do that since the note is not visible
	if not has_meta("memory_item"):
		set_meta("memory_item", await create_note())
	
	var item: MemoryItem = get_meta("memory_item")

	var present = SingletonObject.ThreadList.any(func(thread: MemoryThread): return item in thread.MemoryItemList)

	if not present and toggled_on: # if this item is not present in any thread, create new
		item = await create_note()
		set_meta("memory_item", item)

	item.Enabled = toggled_on
	item.Visible = false
	item.Locked = true
	SingletonObject.NotesTab.render_threads() # rerender it since it's not visible now


func _exit_tree():
	if not has_meta("memory_item"): return
	
	var item: MemoryItem = get_meta("memory_item")

	var thread: = SingletonObject.get_thread(item.OwningThread)

	thread.MemoryItemList.erase(item)