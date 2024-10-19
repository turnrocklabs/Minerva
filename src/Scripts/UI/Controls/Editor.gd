class_name Editor
extends Control
## Editor node is responsible for acting as a CodeEdit or TextureRect
## depending if it handles text or graphics file.
## A file path can be associated with it to save the conent of the node to it

## @tutorial Editor.create(Editor.Type.TEXT)

static var editor_scene = preload("res://Scenes/Editor.tscn")

signal content_changed()
signal save_dialog(dialog_result: DIALOG_RESULT)
enum DIALOG_RESULT { Save, Cancel, Close }

@onready var code_edit: EditorCodeEdit = %CodeEdit
@onready var texture_rect: TextureRect = %TextureRect
@onready var graphics_editor: GraphicsEditor = %GraphicsEditor
@onready var _note_check_button: CheckButton = %CheckButton

#this are control noes for the Ctrl+F UI
@onready var find_string_container: HBoxContainer = %FindStringContainer
@onready var find_string_line_edit: LineEdit = %FindStringLineEdit
@onready var matches_counter_label: Label = %MatchesCounterLabel
@onready var previous_match_button: Button = %PreviousMatchButton
@onready var next_match_button: Button = %NextMatchButton


#this are control nodes for the Ctrl+G popup
@onready var jump_to_line_panel: PopupPanel = %JumpToLinePanel
@onready var jump_to_line_edit: LineEdit = %JumpToLineEdit
@onready var jump_to_line_label: RichTextLabel = %JumpToLineLabel

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
#var file_path: String
var type: Type
var _file_saved := false

var supported_text_exts: PackedStringArray
## Wether the editor can prompt user to save the content.
var prompt_save:= true

 # checks if the editor has been saved at least once
var file_saved_in_disc := false # this is used when you press the save button on the file menu

static func create(type_: Type, file_ = null, name_ = null, associated_object_ = null) -> Editor:
	var editor = editor_scene.instantiate()
	editor.type = type_
	editor.associated_object = associated_object_
	
	if name_:
		editor.tab_title = name_
	if file_: 
		editor.file = file_

	match type_:
		Editor.Type.TEXT, Editor.Type.NOTE_EDITOR:
			editor.get_node("%CodeEdit").visible = true
			#editor.get_node("%CodeEdit").text_changed.connect(editor._on_editor_changed)
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
	code_edit.text_changed.connect(_on_editor_changed)


func update_last_path(new_path: String) -> void:
	SingletonObject.last_saved_path = new_path + "/"


func _load_text_file(filename: String):
	var fa_object = FileAccess.open(filename, FileAccess.READ)
	if fa_object:
		#file_path = file
		code_edit.text = fa_object.get_as_text()
		#code_edit.text_changed.emit() # the signal is not emitted for some reason
		code_edit.saved_content = code_edit.text
	else:
		code_edit.text = "Could not retrive file"
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
		
	else:
		if new_entry:# this is used for the save as.. feature
			($FileDialog as FileDialog).title = "Save \"%s\" editor" % tab_title
			
			
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

## Calls the save implementation that could be altered by [method override_save],[br]
## and then updates the unsaved changes icon.
func save():
	#if _save_override.is_valid(): this got put on the note button github issue #154
		#_save_override.call()
	#else:
	if SingletonObject.last_saved_path:
		await prompt_close(true, false, SingletonObject.last_saved_path)
	else:
		await prompt_close(true)
	
	# Post save emit the signals to update the saved state icon
	match type:
		Type.TEXT, Type.NOTE_EDITOR:
			code_edit.text_changed.emit()
		Type.GRAPHICS:
			graphics_editor.is_image_saved = true
			SingletonObject.UpdateUnsavedTabIcon.emit()
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
			if graphics_editor:
				return graphics_editor.is_image_saved
			else:
				return false
	
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
	if _save_override.is_valid() or associated_object:
		_save_override.call()
		return
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
	#if Type.WhiteBoard == type:
		#if file:
			#SingletonObject.NotesTab.add_image_note(file.get_file(), %PlaceForScreen.get_viewport().get_texture().get_image(), "white board")
		#else:
			#SingletonObject.NotesTab.add_image_note("whiteboard", %PlaceForScreen.get_viewport().get_texture().get_image(), "white board")


#this functions calls the file linked to the editor to be loaded again into memory
func _on_reload_button_pressed() -> void:
	match type:
		Type.GRAPHICS:
			_load_graphics_file(file)
		Type.TEXT:
			_load_text_file(file)


#this emits a signal that gets picked by the projectMenuActions to save open editor tabs
func _on_save_open_editor_tabs_button_pressed() -> void:
	SingletonObject.SaveOpenEditorTabs.emit()

#endregion bottom of the pane buttons

#region Code Editor
#region code editor action commands

#this function catches input when the code editor is focused
func _on_code_edit_gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("jump_to_line"):
		jump_to_line()
	elif  event.is_action_pressed("find_string"):
		find_string_in_code_edit()

#this are variables for Ctrl+F
var text_to_search: String = ""
var results_number: int = 0
var results_to_current: int = 0
#this is called when the user presses 'Ctrl+F'
func find_string_in_code_edit() -> void:
	if !find_string_container.visible:
		find_string_container.show()
	
	if code_edit.get_selected_text() != "":
		
		find_string_line_edit.text = code_edit.get_selected_text()
		
		code_edit.add_selection_for_next_occurrence()
		text_to_search = code_edit.get_selected_text()
		update_search(code_edit.get_selected_text())
		find_string_line_edit.select_all()


func update_search(new_text: String) -> void:
	code_edit.set_search_text(new_text)
	text_to_search = new_text
	code_edit.highlight_all_occurrences = true
	count_text_occurences()


func _on_find_string_line_edit_text_changed(new_text: String) -> void:
	update_search(new_text)
	
	var result: = code_edit.search(text_to_search, TextEdit.SearchFlags.SEARCH_WHOLE_WORDS, code_edit.get_caret_line(),code_edit.get_caret_column())
	if result.x != -1:
		code_edit.set_caret_column(result.x)
		code_edit.set_caret_line(result.y)
		code_edit.select(result.y,result.x, result.y, result.x + text_to_search.length())
	code_edit.add_selection_for_next_occurrence()


func count_text_occurences() -> void:
	results_number = 0
	results_to_current = 0
	
	for line: String in code_edit.text.split("\n"):
		results_number += line.countn(text_to_search,0,0)
	
	var for_indx: = 0
	for i : String in code_edit.text.split("\n"):
		if code_edit.get_caret_line() == for_indx:
			results_to_current += i.countn(text_to_search, 0, code_edit.get_caret_column())
			break
		else:
			results_to_current += i.countn(text_to_search, 0, )
		
		for_indx += 1
	
	update_matches_label(results_to_current, results_number)


func update_matches_label(current_search, occurrences) -> void:
	if occurrences < 1:
		matches_counter_label.text = "No matches"
		matches_counter_label.modulate = Color.RED
	else:
		matches_counter_label.text = "%s of  %s matches: " % [current_search, occurrences]
		matches_counter_label.modulate = Color.WHITE


#region find string buttons
func _on_previous_match_button_pressed() -> void:
	code_edit.deselect()
	if code_edit.get_caret_column() - text_to_search.length() -1  <= 0:
		code_edit.set_caret_column(0)
		if code_edit.get_caret_line() - 1 >= 0:
			code_edit.set_caret_line(code_edit.get_caret_line() - 1)
			code_edit.set_caret_column(code_edit.get_text().split("\n")[code_edit.get_caret_line()].length())
	else:
		code_edit.set_caret_column( code_edit.get_caret_column() - text_to_search.length() - 1)
	
	var result: = code_edit.search(text_to_search, TextEdit.SearchFlags.SEARCH_BACKWARDS, code_edit.get_caret_line(),code_edit.get_caret_column())
	if result.x != -1:
		#print("result from prev:" + str(result))
		code_edit.select(result.y,result.x , result.y, result.x + text_to_search.length())
		code_edit.adjust_viewport_to_caret()
	count_text_occurences()


func _on_next_match_button_pressed() -> void:
	var result: = code_edit.search(text_to_search, 0, code_edit.get_caret_line(),code_edit.get_caret_column())
	if result.x != -1:
		print("result from next:" + str(result))
		code_edit.set_caret_column(result.x)
		code_edit.set_caret_line(result.y)
		code_edit.select(result.y,result.x , result.y, result.x + text_to_search.length())
		code_edit.adjust_viewport_to_caret()
	count_text_occurences()

#close button for the find string UI controls
func _on_close_buton_pressed() -> void:
	code_edit.highlight_all_occurrences = false
	code_edit.set_search_text('')
	find_string_container.hide()

#endregion find string buttons

#this function is called when the user presses 'Ctrl+G'
func jump_to_line() -> void:
	if !jump_to_line_panel.visible and (type == Type.TEXT or type == Type.NOTE_EDITOR):
		var string_format = "you are currently on line %d, character %d, type a line number between %d and %d to jump to."
		
		#this is a ternary operator equivalent
		var column: int = code_edit.get_caret_column() if code_edit.get_caret_column() > 1 else 1
		var line: int = code_edit.get_caret_line() + 1 if code_edit.get_caret_line() > 1 else 1
		var line_count: int = code_edit.get_line_count() if code_edit.get_line_count() > 1 else 1
		
		var new_text = string_format % [line, column, 1, line_count]
		jump_to_line_label.text = new_text
		jump_to_line_edit.call_deferred("grab_focus")
		jump_to_line_panel.call_deferred("show")


func _on_jump_to_line_edit_text_submitted(new_text: String) -> void:
	
	jump_to_line_edit.text = ""
	if new_text.is_valid_int():
		code_edit.set_caret_line(new_text.to_int() -1)
		jump_to_line_panel.call_deferred("hide")
	else:
		jump_to_line_label.text += "\nINPUT PROVIDED WAS NOT VALID." 

#endregion code editor action commands

func _on_editor_changed(text: String = ""):
	if text != "":
		# this line gets the max number cf chars for the line edit e.g.: "12345" = 5
		jump_to_line_edit.max_length = str(code_edit.get_line_count()).length()
		SingletonObject.UpdateUnsavedTabIcon.emit()
		_file_saved = false
		file_saved_in_disc = false

	if has_meta("memory_item"):
		var item: MemoryItem = get_meta("memory_item")
		_update_note(item)

	content_changed.emit()

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
	code_edit.clear()
	code_edit.grab_focus()


func _on_audio_btn_pressed():
	SingletonObject.AtT.FieldForFilling = code_edit
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %AudioBTN
	%AudioBTN.modulate = Color(Color.LIME_GREEN)

#endregion Top Editor buttons
#endregion Code Editor


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

func _update_note(memory_item: MemoryItem) -> void:
	if type == Type.TEXT:
		memory_item.Type = SingletonObject.note_type.TEXT
		memory_item.Content = code_edit.text
	
	elif type == Type.GRAPHICS:
		memory_item.Type = SingletonObject.note_type.IMAGE
		memory_item.MemoryImage = graphics_editor.image



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
