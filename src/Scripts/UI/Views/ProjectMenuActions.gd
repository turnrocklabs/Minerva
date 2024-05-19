class_name ProjectMenu
extends Control

# Whether the user selected the file or closed the dialog this signal is emitted
signal save_as_dialog_exited()

var save_path: String

## Function:
# _new_project empties all the tabs and lists currently stored as notes or chats.
# it also blanks out the save file variable to force a save_as
func _new_project():
	SingletonObject.initialize_notes()
	SingletonObject.initialize_chats(SingletonObject.Provider, SingletonObject.Chats)
	save_path = ""
	pass


func open_project():
	%fdgOpenProject.popup_centered(Vector2i(800, 600))

# This function can be awaited, which will resolve when the dialog is exited on 'file_selected' or 'canceled'
func save_project_as(file=""):
	if file == "":
		%fdgSaveAs.popup_centered(Vector2i(800, 600))

		(%fdgSaveAs as FileDialog).file_selected.connect(func(_p): save_as_dialog_exited.emit())
		(%fdgSaveAs as FileDialog).canceled.connect(func(): save_as_dialog_exited.emit())
		
		await save_as_dialog_exited
	else:
		save_path=file
		save_project()


func save_project():
	var item_list: ItemList = %ExitConfirmationDialog.get_node("v/ItemList")
	for item_idx in item_list.get_selected_items():
		var editor = item_list.get_item_metadata(item_idx)
		await editor.prompt_close(true) # FIXME: somehow not prompt the first prompt from here
		editor.queue_free()

	if save_path == null or save_path == "":
		await save_project_as()
		return
	
	# ask the singleton to serialize all state vars.
	
	var serialized: String = serialize_project()
	var save_file = FileAccess.open(save_path, FileAccess.WRITE)
	save_file.store_line(serialized)
	SingletonObject.save_state(true)


## Function:
# serialize_project iterates through the notes and chats and creates an array
# each line in the array is the contents of either the notes or the chats.
func serialize_project() -> String:
	var notes: Array[Dictionary] = []
	var chats: Array[Dictionary] = []
	# var active_notes_index: int = 0 ## which of the notes tabs is selected and active
	# var active_chat_index: int = 0 ## which chat tab is active
	var last_tab_index: int = 0 ##

	# Serialize the notes first.
	for note_tab: MemoryThread in SingletonObject.ThreadList:
		var serialized_note_tab = note_tab.Serialize()
		notes.append(serialized_note_tab)
	
	# # Now serialize the chats.
	for chat_thread: ChatHistory in SingletonObject.ChatList:
		var serialized_chat_tab = chat_thread.Serialize()
		chats.append(serialized_chat_tab)

	var editors = SingletonObject.editor_container.serialize()

	var save_dict: Dictionary = {
		"ThreadList" : notes,
		"ChatList" : chats,
		"Editors": editors,
		"last_tab_index": SingletonObject.last_tab_index,
		"active_chatindex": SingletonObject.Chats.current_tab,
		"active_notes_index": SingletonObject.NotesTab.current_tab
	}
	var stringified_save: String = JSON.stringify(save_dict, "\t")
	return stringified_save


func deserialize_project(data: Dictionary):
	var threads: Array[MemoryThread] = []
	for thread_data in data.get("ThreadList", []):
		threads.append(MemoryThread.Deserialize(thread_data))
	SingletonObject.initialize_notes(threads)

	var chats: Array[ChatHistory] = []
	for chat_data in data.get("ChatList", []):
		chats.append(ChatHistory.Deserialize(chat_data))
	SingletonObject.initialize_chats(SingletonObject.Provider, SingletonObject.Chats, chats)

	# We need to cast Array to Array[String] because deserialize expects that type
	var editor_files: Array[String] = []
	editor_files.assign(data.get("Editors", []))
	SingletonObject.editor_container.deserialize(editor_files)
	
	SingletonObject.last_tab_index = data.get("last_tab_index", 0)
	SingletonObject.Chats.current_tab = data.get("active_chatindex", 0)
	SingletonObject.NotesTab.current_tab = data.get("active_notes_index", 0)


func close_project():
	save_project()
	_new_project()
	pass

# Called when the node enters the scene tree for the first time.
func _ready():
	get_tree().set_auto_accept_quit(false)
	# We want additional exit button, so we have 'Save', 'Cancel' and 'Exit'
	(%ExitConfirmationDialog as ConfirmationDialog).add_button("Exit", true, "exit")

	SingletonObject.NewProject.connect(self._new_project)
	SingletonObject.SaveProject.connect(self.save_project)
	SingletonObject.SaveProjectAs.connect(self.save_project_as)
	SingletonObject.CloseProject.connect(self.close_project)
	SingletonObject.OpenProject.connect(self.open_project)


func _on_fdg_save_as_file_selected(path):
	self.save_path = path
	self.save_project()
	pass # Replace with function body.


func _on_fdg_open_project_file_selected(path):
	var proj_file = FileAccess.open(path, FileAccess.READ)

	if proj_file == null:
		push_error("Couldn't parse the project file at %s. Error code: %s" % [path, FileAccess.get_open_error()])
		return

	var json = JSON.parse_string(proj_file.get_as_text())

	if json == null:
		push_error("Couldn't parse the project file at %s" % path)
		return

	deserialize_project(json)

	# Since we just opened the project, the save state is true
	# Why deferred?
	# If not some of the deserialized object alter the state after this function ends
	# even tho we called deserialize above. Probably because the nodes are not added
	# to the hierarchy untill the idle time, when they call set_state(false).
	# So we just delay this call to that idle time also.
	SingletonObject.call_deferred("save_state", true)

	self.save_path = path

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		
		var unsaved_editors = SingletonObject.editor_container.editor_pane.unsaved_editors()

		# if the state is unsaved or we have unsaved editors open
		if not SingletonObject.saved_state or unsaved_editors:
			# user want to quit
			# ask the user which unsaved editors he wants saved
			var item_list: ItemList = %ExitConfirmationDialog.get_node("v/ItemList")
			item_list.clear()
			for editor in unsaved_editors:
				var item_idx = item_list.add_item(editor.name)
				item_list.set_item_metadata(item_idx, editor)
			
			%ExitConfirmationDialog.get_node("v").visible = item_list.item_count > 0

			%ExitConfirmationDialog.popup_centered(Vector2i(400, 150))
		else:
			get_tree().quit()

func _on_exit_confirmation_dialog_canceled():
	%ExitConfirmationDialog.hide()

func _on_exit_confirmation_dialog_confirmed():
	await self.save_project()
	get_tree().quit()


func _on_exit_confirmation_dialog_custom_action(action: StringName):
	if action == "exit":
		get_tree().quit()
