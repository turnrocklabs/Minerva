class_name Editor
extends Control
## Editor node is responsible for acting as a CodeEdit or TextureRect
## depending if it handles text or graphics file.
## A file path can be associated with it to save the content of the node to it

## @tutorial Editor.create(Editor.Type.TEXT)

static var editor_scene = preload("res://Scenes/Editor.tscn")
static var graphics_editor_scene = preload("res://Scenes/GraphicsEditor.tscn")


signal content_changed()
signal save_dialog(dialog_result: DIALOG_RESULT)
enum DIALOG_RESULT { Save, Cancel, Close }

# Flags to represent the saved states
# combining the flags shows the current state of the editor data

## Represents that the editor file is saved, if there is one
const FILE_SAVED: = 0x1

## Represents that the associated object is saved, if there is one
const ASSOCIATED_OBJECT_SAVED: = 0x2

var video_player: VideoPlayer:
	set(value):
		video_player = value
		get_node("%VBoxContainer").add_child(value)

var code_edit: EditorCodeEdit
var graphics_editor: GraphicsEditor
@onready var _note_check_button: CheckButton = %CheckButton

@onready var autowrap_button: Button = %AutowrapButton
@onready var mic_button: Button = %MicButton

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

@onready var text_is_smaller = $VBoxContainer/ButtonsHBoxContainer/TextIsSmaller
@onready var text_is_incoplete = $VBoxContainer/ButtonsHBoxContainer/TextIsIncoplete
@onready var text_is_smaller_and_incoplete = $VBoxContainer/ButtonsHBoxContainer/TextIsSmalleAndIncoplete

enum Type {
	TEXT,
	GRAPHICS,
	WhiteBoard, # TODO: To be removed
	NOTE_EDITOR,
	VIDEO
}

## May contain the object that is being edited by this editor.[br]
## Eg. ChatImage, Note, etc..[br]
## Allows switching to existing editor instead of
## opening a new one for same associated object.
var associated_object:
	set(value):
		associated_object = value
		SingletonObject.UpdateUnsavedTabIcon.emit()

var note_saved: bool = false
## Callable that overrides what happens when user clicks the editor "save" button.
var _save_override: Callable

var tab_title: String = ""
var file: String:
	set(value):
		file = value
		%reloadButton.disabled = false
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

	# runs before onready so we need to use get_node
	var vbox_container: VBoxContainer = editor.get_node("VBoxContainer")
	match type_:
		Editor.Type.TEXT:
			var new_code_edit = EditorCodeEdit.new()
			new_code_edit.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			new_code_edit.caret_blink = true
			new_code_edit.caret_multiple = false
			new_code_edit.highlight_all_occurrences = true
			new_code_edit.highlight_current_line = true
			new_code_edit.gutters_draw_line_numbers = true
			new_code_edit.gutters_zero_pad_line_numbers = true
			new_code_edit.gui_input.connect(editor._on_code_edit_gui_input)
			new_code_edit.text_changed.connect(editor._on_editor_changed)
			new_code_edit.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
			new_code_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			new_code_edit.name = "CodeEdit"
			vbox_container.add_child(new_code_edit)
			#vbox_container.move_child(new_code_edit,0)
			editor.code_edit = new_code_edit
		Editor.Type.GRAPHICS:
			var new_graphics_editor: GraphicsEditor = graphics_editor_scene.instantiate()
			new_graphics_editor.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			new_graphics_editor.masking_color = Color(0.25098, 0.227451, 0.243137, 0.6)
			#new_graphics_editor.changed.connect(editor._on_editor_changed)
			vbox_container.add_child(new_graphics_editor)
			#vbox_container.move_child(new_graphics_editor, 0)
			editor.graphics_editor = new_graphics_editor
			## TODO: Implement changed signal for graphics 
			
		# editor.get_node("%GraphicsEditor").changed.connect(editor._on_editor_changed)
		Editor.Type.VIDEO:
			var new_video_player: VideoPlayer = SingletonObject.video_player_scene.instantiate()
			new_video_player.video_path = file_
			editor.video_player = new_video_player
			editor.get_node("%ButtonsHBoxContainer").queue_free()
			editor.get_node("%FindStringContainer").queue_free()
			
	return editor

func toggle(on: bool) -> void:
	_note_check_button.button_pressed = on


func _ready():
	($CloseDialog as ConfirmationDialog).add_button("Close", true, "close")
	if file:
		match type:
			Type.TEXT: _load_text_file(file)
			Type.GRAPHICS: _load_graphics_file(file)
			Type.VIDEO: video_player.video_path = file
	
	_note_check_button.disabled = type != Type.TEXT and type != Type.GRAPHICS
	
	#set the text formats that are supported we add a "*" to the start of every ext
	for ext in SingletonObject.supported_text_formats:
		ext = "*." +ext 
		supported_text_exts.append(ext)
	$FileDialog.filters = supported_text_exts
	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = $FileDialog.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 12)
	SingletonObject.UpdateLastSavePath.connect(update_last_path)
	#code_edit.text_changed.connect(_on_editor_changed)
	
	if self.type == Type.TEXT:
		mic_button.show()
		autowrap_button.show()
		toggle_autowrap()
	else:
		mic_button.hide() 
		autowrap_button.hide()
	
	text_is_smaller.pressed.connect(_on_close_warrning.bind(text_is_smaller))
	text_is_incoplete.pressed.connect(_on_close_warrning.bind(text_is_incoplete))
	text_is_smaller_and_incoplete.pressed.connect(_on_close_warrning.bind(text_is_smaller_and_incoplete))
	
func update_last_path(new_path: String) -> void:
	SingletonObject.last_saved_path = new_path + "/"


func _load_text_file(filename: String):
	var fa_object = FileAccess.open(filename, FileAccess.READ)
	if fa_object == null:
				var error: = error_string(FileAccess.get_open_error())
				push_warning(error)
				SingletonObject.ErrorDisplay("Couldn't open file", error)
				return
	if fa_object:
		#file_path = file
		code_edit.text = fa_object.get_as_text()
		code_edit.saved_content = code_edit.text
		code_edit.text_changed.emit() # the signal is not emitted for some reason
	else:
		code_edit.text = "Could not retrieve file"
	# %SaveButton.disabled = false


func _load_graphics_file(filename: String):
	var image = Image.load_from_file(filename)
	graphics_editor.setup_from_image(image)
	#_file_saved = true
	#SingletonObject.UpdateUnsavedTabIcon.emit()
	# %SaveButton.disabled = false


## Changes the function that runs when user clicks the "save" button
## from the [method prompt_close] to [parameter save_function].[br]
## To revert back pass the empty [parameter save_function]:[br]
## [code]override_save(Callable.new())[/code]
func override_save(save_function: Callable) -> void:
	_save_override = save_function


## Prompts user to save the file
## show_save_file_dialog determines if user should be asked wether he wants to save the editor first
## otherwise if shows save file dialog straight away
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
		if type == Type.TEXT:
			line_edit.text = tab_title# + "." + SingletonObject.supported_text_formats[0]
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
	# if user canceled the file select dialog, just return to the editor
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
		Type.TEXT:
			code_edit.text_changed.emit()
		Type.GRAPHICS:
			graphics_editor.is_image_saved = true
			SingletonObject.UpdateUnsavedTabIcon.emit()
			pass # TODO: implement for graphics files
	SingletonObject.UpdateUnsavedTabIcon.emit()


## Returns the bitmask of the saved state for the editor.
func get_saved_state() -> int:
	var state: int = 0x0

	match type:
		Type.TEXT:
			# if we have a file and the content matches, add the FILE_SAVED mask
			if file and code_edit.text == code_edit.saved_content:
				state |= FILE_SAVED
			
			# if there's associated_object and the content matches add the ASSOCIATED_OBJECT_SAVED flag
			if associated_object:
				if associated_object is Note:
					if code_edit.text == associated_object.memory_item.Content:
						state |= ASSOCIATED_OBJECT_SAVED
				
				# if it's not a note, just mark it as saved
				else:
					state |= ASSOCIATED_OBJECT_SAVED
			
			# if we have no file or associated object, but the content is marked as saved
			# that usually means that the editors was just created (content is emtry string)
			if not (file or is_instance_valid(associated_object)) and code_edit.text == code_edit.saved_content:
				state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.GRAPHICS:
			# if there's no graphics editor, even tho that's the type, just return all saved states
			if not graphics_editor: state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

			if file and graphics_editor.is_image_saved:
				state |= FILE_SAVED
			
			if associated_object:
				if associated_object is Note:
					state |= ASSOCIATED_OBJECT_SAVED
					# associated_object.memory_item
				
				else:
					state |= ASSOCIATED_OBJECT_SAVED

	return state

## Returns whether the editor content is saved in regards to the file or the associated object.[br]
## [parameter file_save], if set to true will return whether the editor is saved to a file[br],
## or, if false if the editor is saved at the associted object (eg. Note).
func is_content_saved(file_save: = true) -> bool:
	var state: = get_saved_state()

	if file_save: # if there's no file or the file is saved
		return not file or state & FILE_SAVED
	
	return not associated_object or state & ASSOCIATED_OBJECT_SAVED



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
			if save_file == null:
				var error: = error_string(FileAccess.get_open_error())
				push_warning(error)
				SingletonObject.ErrorDisplay("Couldn't open file", error)
				return
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
	var idx = SingletonObject.editor_pane.Tabs.get_tab_idx_from_control(self)
	SingletonObject.editor_pane.Tabs.set_tab_title(idx, tab_title)
	SingletonObject.editor_pane.Tabs.set_tab_tooltip(idx, path)

#region bottom of the pane buttons

func _on_save_button_pressed():
	save()


func _on_create_note_button_pressed() -> void:

	if is_instance_valid(associated_object) and associated_object is Note:
		_update_memory_item(associated_object.memory_item)
		associated_object.memory_item = associated_object.memory_item # force the setter to update the note
		
	else:
		if Type.TEXT == type:
			if file:
				associated_object = SingletonObject.NotesTab.add_note(file.get_file(),false, code_edit.text)
			elif tab_title:
				associated_object = SingletonObject.NotesTab.add_note(tab_title,false, code_edit.text)
			else:
				associated_object = SingletonObject.NotesTab.add_note("Note from Editor",false, code_edit.text)

		if Type.GRAPHICS == type:
			if tab_title:
				associated_object = SingletonObject.NotesTab.add_image_note("Graphic Note", graphics_editor.image, graphics_editor.image.get_meta("caption", ""))
			elif file:
				associated_object =  SingletonObject.NotesTab.add_image_note(file.get_file(), graphics_editor.image, "Sketch")
			else:
				associated_object = SingletonObject.NotesTab.add_image_note("From file Editor", graphics_editor.image, "Sketch")

	SingletonObject.UpdateUnsavedTabIcon.emit()
	


#this functions calls the file linked to the editor to be loaded again into memory
func _on_reload_button_pressed() -> void:
	if file:
		match type:
			Type.GRAPHICS:
				_load_graphics_file(file)
			Type.TEXT:
				_load_text_file(file)
				text_is_smaller.visible = false
				text_is_incoplete.visible = false
				text_is_smaller_and_incoplete.visible = false


#this emits a signal that gets picked by the projectMenuActions to save open editor tabs
func _on_save_open_editor_tabs_button_pressed() -> void:
	SingletonObject.SaveOpenEditorTabs.emit()

#endregion bottom of the pane buttons

#region Code Editor
#region code editor action commands

#this function catches input when the code editor is focused
func _on_code_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and event.keycode == KEY_CTRL:
			%FindStringLineEdit.set_process_input(false)
			%FindStringLineEdit.set_process_unhandled_key_input(false)
		else:
			%FindStringLineEdit.set_process_input(true)
			%FindStringLineEdit.set_process_unhandled_key_input(true)
	if event.is_action_pressed("jump_to_line"):
		jump_to_line()
	elif  event.is_action_pressed("find_string"):
		find_string_in_code_edit()
	


func toggle_autowrap() -> void:
	if code_edit == null:
		return
	if code_edit.wrap_mode != TextEdit.LINE_WRAPPING_BOUNDARY:
		code_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	if code_edit.autowrap_mode == TextServer.AutowrapMode.AUTOWRAP_OFF:
		code_edit.autowrap_mode = TextServer.AUTOWRAP_WORD
	else:
		code_edit.autowrap_mode = TextServer.AutowrapMode.AUTOWRAP_OFF


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
	else:
		await get_tree().create_timer(0.1).timeout
		find_string_line_edit.grab_focus()


func update_search(new_text: String) -> void:
	code_edit.set_search_text(new_text)
	text_to_search = new_text
	code_edit.highlight_all_occurrences = true
	count_text_occurrences()


func _on_find_string_line_edit_text_changed(new_text: String) -> void:
	update_search(new_text)
	
	var result: = code_edit.search(text_to_search, TextEdit.SearchFlags.SEARCH_WHOLE_WORDS, code_edit.get_caret_line(),code_edit.get_caret_column())
	if result.x != -1:
		code_edit.set_caret_column(result.x)
		code_edit.set_caret_line(result.y)
		code_edit.select(result.y,result.x, result.y, result.x + text_to_search.length())
	code_edit.add_selection_for_next_occurrence()


func count_text_occurrences() -> void:
	results_number = 0
	results_to_current = 0
	
	for line: String in code_edit.text.split("\n"):
		results_number += line.countn(text_to_search,0,0)
	
	var for_idx: = 0
	for i : String in code_edit.text.split("\n"):
		if code_edit.get_caret_line() == for_idx:
			results_to_current += i.countn(text_to_search, 0, code_edit.get_caret_column())
			break
		else:
			results_to_current += i.countn(text_to_search, 0, )
		
		for_idx += 1
	
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
	count_text_occurrences()


func _on_next_match_button_pressed() -> void:
	var result: = code_edit.search(text_to_search, 0, code_edit.get_caret_line(),code_edit.get_caret_column())
	if result.x != -1:
		print("result from next:" + str(result))
		code_edit.set_caret_column(result.x)
		code_edit.set_caret_line(result.y)
		code_edit.select(result.y,result.x , result.y, result.x + text_to_search.length())
		code_edit.adjust_viewport_to_caret()
	count_text_occurrences()

#close button for the find string UI controls
func _on_close_button_pressed() -> void:
	code_edit.highlight_all_occurrences = false
	code_edit.set_search_text('')
	find_string_container.hide()

#endregion find string buttons

#this function is called when the user presses 'Ctrl+G'
func jump_to_line() -> void:
	if !jump_to_line_panel.visible and type == Type.TEXT:
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
		# SingletonObject.UpdateUnsavedTabIcon.emit()
		# _file_saved = false
		# file_saved_in_disc = false

	if has_meta("memory_item"):
		var item: MemoryItem = get_meta("memory_item")
		_update_memory_item(item)

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
	text_is_smaller.visible = false
	text_is_incoplete.visible = false
	text_is_smaller_and_incoplete.visible = false

func clear_text():
	if Type.TEXT != type:
		return
	code_edit.clear()
	code_edit.grab_focus()


func _on_mic_button_pressed() -> void:
	SingletonObject.AtT.FieldForFilling = code_edit
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = mic_button
	mic_button.modulate = Color(Color.LIME_GREEN)

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

func _update_memory_item(memory_item: MemoryItem) -> void:
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

func _on_close_warrning(path):
	path.visible = false;


func _on_find_button_pressed() -> void:
	code_edit.highlight_all_occurrences = false
	code_edit.set_search_text('')
	find_string_container.visible = !find_string_container.visible
