class_name Editor
extends Control

## Editor node is responsible for acting as a CodeEdit or TextureRect
## depending if it handles text or graphics file.
## A file path can be associated with it to save the conent of the node to it

## @tutorial Editor.create(Editor.TYPE.Text)

static var scene = preload("res://Scenes/Editor.tscn")

signal save_dialog(dialog_result: DIALOG_RESULT)
enum DIALOG_RESULT { Save, Cancel, Close }

@onready var code_edit: EditorCodeEdit = $CodeEdit
@onready var texture_rect: TextureRect = $TextureRect

enum TYPE {
	Text,
	Graphics,
}

var file: String
var type: TYPE
var _file_saved := false

static func create(type_: TYPE, file_ = null) -> Editor:
	var editor = scene.instantiate()
	editor.type = type_
	if file_: editor.file = file_

	match type_:
		Editor.TYPE.Text:
			editor.get_node("CodeEdit").visible = true
		Editor.TYPE.Graphics:
			editor.get_node("TextureRect").visible = true

	return editor

func _ready():
	($CloseDialog as ConfirmationDialog).add_button("Close", true, "close")

	if file:
		match type:
			TYPE.Text: _load_text_file(file)
			TYPE.Graphics: _load_graphics_file(file)


func _load_text_file(filename: String):
	var fa_object = FileAccess.open(filename, FileAccess.READ)
	code_edit.text = fa_object.get_as_text()


func _load_graphics_file(filename: String):
	var image = Image.load_from_file(filename)
	var texture_item = ImageTexture.create_from_image(image)
	texture_rect.texture = texture_item

## Prompts user to save the file
## show_save_file_dialog determines if user should be asked wether he wants to save the editor first
## otherwise if shows save file dialog straing away
func prompt_close(show_save_file_dialog := false) -> bool:
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
			return code_edit.starting_version == code_edit.get_saved_version()
		TYPE.Graphics:
			return true

	return false


func _on_save_dialog_canceled():
	save_dialog.emit(DIALOG_RESULT.Close)


func _on_save_dialog_confirmed():
	save_dialog.emit(DIALOG_RESULT.Save)



func _on_close_dialog_custom_action(action: StringName):
	if action == "close":
		save_dialog.emit(DIALOG_RESULT.Close)
		$CloseDialog.hide()


func _on_file_dialog_file_selected(path: String):
	var save_file = FileAccess.open(path, FileAccess.WRITE)

	match type:
		TYPE.Text:
			save_file.store_string(code_edit.text)
		TYPE.Graphics:
			pass
	
	_file_saved = true

