class_name ProjectMenu
extends Control

# Whether the user selected the file or closed the dialog this signal is emitted
signal save_as_dialog_exited()

var save_path: String

var last_save_path: String

func update_last_save_path(new_path: String) -> void:
	SingletonObject.last_saved_path = new_path + "/"

## Function:
# _new_project empties all the tabs and lists currently stored as notes or chats.
# it also blanks out the save file variable to force a save_as
func _new_project():
	SingletonObject.initialize_notes()
	SingletonObject.initialize_chats(SingletonObject.Chats)
	SingletonObject.editor_container.clear_editor_tabs() # deserialize empty files list, so it clears everything
	save_path = ""
	pass


func open_project(path: = ""):
	if path.is_empty():
		%fdgOpenProject.popup_centered(Vector2i(800, 600))
		return
	
	open_project_given_path(path)

# This function can be awaited, which will resolve when the dialog is exited on 'file_selected' or 'canceled'
func save_project_as(file=""):
	if file == "":
		if SingletonObject.last_saved_path != "":
			%fdgSaveAs.current_path = SingletonObject.last_saved_path
		%fdgSaveAs.popup_centered(Vector2i(800, 600))

		(%fdgSaveAs as FileDialog).file_selected.connect(func(_p): save_as_dialog_exited.emit())
		(%fdgSaveAs as FileDialog).canceled.connect(func(): save_as_dialog_exited.emit())
		
		await save_as_dialog_exited
	else:
		save_path=file
		save_project()


func package_project():
	var item_list: ItemList = %ExitConfirmationDialog.get_node("v/ItemList")
	for item_idx in item_list.get_selected_items():
		var editor = item_list.get_item_metadata(item_idx)
		await editor.prompt_close(true)
		editor.queue_free()

	var ppw: PackageProjectWindow = %PackageProjectWindow

	ppw.data = serialize_project()
	
	ppw.popup_centered()


func unpackage_project():
	var upw: UnpackageProjectWindow = %UnpackageProjectWindow

	upw.popup_centered()


func save_unsaved_editors() -> void:
	var unsaved_editors = SingletonObject.editor_container.editor_pane.unsaved_editors()
	var item_list: ItemList = %ExitConfirmationDialog.get_node("v/ItemList")
	for item_idx in item_list.get_selected_items():
		var editor: Editor = item_list.get_item_metadata(item_idx)
		if editor.file:
			await editor.prompt_close(true, false, SingletonObject.last_saved_path)
		else:
			await editor.prompt_close(true, true, SingletonObject.last_saved_path)
	
	SingletonObject.UpdateUnsavedTabIcon.emit()


func save_project():
	
	save_unsaved_editors()

	if save_path == null or save_path == "":
		await save_project_as()
		return
	
	# ask the singleton to serialize all state vars.
	var proj_data: = serialize_project()

	var save_file = FileAccess.open(save_path, FileAccess.WRITE)
	save_file.store_line(JSON.stringify(proj_data, "\t"))
	
	# get the file path and add it to config file
	SingletonObject.save_recent_project(save_path)
	
	SingletonObject.save_state(true)


# this function checks if there are unsaved editor panes and saves them
func save_editorpanes(skip_selecting_items: bool = false):
	var unsaved_editors = SingletonObject.editor_container.editor_pane.unsaved_editors()
		# if the state is unsaved or we have unsaved editors open
	if not SingletonObject.saved_state or unsaved_editors:
		# user want to quit
		# ask the user which unsaved editors he wants saved
		var item_list: ItemList = %ExitConfirmationDialog.get_node("v/ItemList")
		item_list.clear()
		for editor in unsaved_editors:
			var indx = SingletonObject.editor_pane.Tabs.get_tab_idx_from_control(editor)
			var tab_title = SingletonObject.editor_pane.Tabs.get_tab_title(indx)
			var item_idx = item_list.add_item(tab_title)
			item_list.set_item_metadata(item_idx, editor)
		
		if skip_selecting_items:
			var items: = item_list.item_count
			var counter: = 0
			while counter < items:
				item_list.select(counter, false)
				counter += 1
			%ExitConfirmationDialog.get_node("v").visible = item_list.item_count > 0
			save_unsaved_editors()
			
		else:
			%ExitConfirmationDialog.get_node("v").visible = item_list.item_count > 0
			%ExitConfirmationDialog.popup_centered(Vector2i(400, 150))
	else:
		get_tree().quit()


#region Serialize/Deserialize Project
## Function:
# serialize_project iterates through the notes and chats and creates an array
# each line in the array is the contents of either the notes or the chats.
func serialize_project() -> Dictionary:
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

	return {
		"ThreadList" : notes,
		"ChatList" : chats,
		"Editors": editors,
		"last_tab_index": SingletonObject.last_tab_index,
		"active_chatindex": SingletonObject.Chats.current_tab,
		"active_notes_index": SingletonObject.NotesTab.current_tab,
		"active_editor_index": SingletonObject.editor_pane.Tabs.current_tab,
		"default_provider": SingletonObject.get_active_provider(),
	}

func deserialize_project(data: Dictionary):
	var threads: Array[MemoryThread] = []
	for thread_data in data.get("ThreadList", []):
		threads.append(MemoryThread.Deserialize(thread_data))
	SingletonObject.initialize_notes(threads)

	# will be float if loaded from json, cast it to int
	var provider_enum_index = int(data.get("default_provider", 0))
	SingletonObject.Chats.default_provider_script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[provider_enum_index]

	var chats: Array[ChatHistory] = []
	for chat_data in data.get("ChatList", []):
		chats.append(ChatHistory.Deserialize(chat_data))
	SingletonObject.initialize_chats(SingletonObject.Chats, chats)

	# We need to cast Array to Array[String] because deserialize expects that type
	#var editor_files: Array[String] = []
	
	#editor_files.assign(data.get("Editors", []))
	#SingletonObject.editor_container.deserialize(editor_files)
	SingletonObject.editor_container.clear_editor_tabs()
	var editor_nodes: Array = []
	if data.get("Editors"):
		editor_nodes = EditorContainer.deserialize(data.get("Editors", []))
	for editor in editor_nodes:
		SingletonObject.editor_pane.Tabs.add_child(editor)
		var tab_idx = SingletonObject.editor_pane.Tabs.get_tab_idx_from_control(editor)
		SingletonObject.editor_pane.Tabs.set_tab_title(tab_idx, editor.tab_title)
	
	SingletonObject.last_tab_index = data.get("last_tab_index", 0)

	var current_notes_tab = data.get("active_notes_index", 0)
	if SingletonObject.NotesTab.get_tab_count()-1 >= current_notes_tab:
		SingletonObject.NotesTab.current_tab = current_notes_tab
	
	# Set the current tab only if it's within the present tabs
	var current_chat_tab = data.get("active_chatindex", 0)
	if SingletonObject.Chats.get_tab_count()-1 >= current_chat_tab:
		SingletonObject.Chats.current_tab = data.get("active_chatindex", 0)

#endregion Serialize/Deserialize Project

func close_project():
	save_project()
	_new_project()
	pass

# Called when the node enters the scene tree for the first time.
func _ready():
	get_tree().set_auto_accept_quit(false)
	# We want additional exit button, so we have 'Save', 'Cancel' and 'Exit'
	(%ExitConfirmationDialog as ConfirmationDialog).add_button("Exit", true, "exit")
	
	var hbox_save_as: HBoxContainer = %fdgSaveAs.get_vbox().get_child(0)
	hbox_save_as.set("theme_override_constants/separation", 14)
	
	var hbox_open_proj: HBoxContainer = %fdgOpenProject.get_vbox().get_child(0)
	hbox_open_proj.set("theme_override_constants/separation", 14)
	
	SingletonObject.NewProject.connect(self._new_project)
	SingletonObject.SaveProject.connect(self.save_project)
	SingletonObject.SaveProjectAs.connect(self.save_project_as)
	SingletonObject.PackageProject.connect(self.package_project)
	SingletonObject.UnpackageProject.connect(self.unpackage_project)
	SingletonObject.CloseProject.connect(self.close_project)
	SingletonObject.OpenProject.connect(self.open_project)
	SingletonObject.OpenRecentProject.connect(self._on_open_recent_project_selected)
	SingletonObject.SaveOpenEditorTabs.connect( save_editorpanes.bind(true))
	SingletonObject.UpdateLastSavePath.connect(update_last_save_path)

#region FDG Dialog

func _on_fdg_save_as_file_selected(path):
	self.save_path = path
	self.save_project()


func _on_fdg_open_project_file_selected(path):
	open_project_given_path(path)

func _on_fdg_open_file_tree_entered():
	var openProjectHbox: HBoxContainer = %fdgOpenProject.get_vbox().get_child(0)
	openProjectHbox.set("theme_override_constants/separation", 12)

#endregion FDG Dialog

func _on_open_recent_project_selected(project_name: String):
	var project_path = SingletonObject.get_project_path(project_name)
	var status = open_project_given_path(project_path)
	if status != OK:
		SingletonObject.ErrorDisplay("Project file no found", "the project was not found at the path it was saved. \n Maybe it was moved or deleted")


func open_project_given_path(project_path: String) -> int:
	#SingletonObject.show_loading_screen("loading project...")
	var proj_file = FileAccess.open(project_path, FileAccess.READ)
	
	if proj_file == null:
		push_error("Couldn't parse the proj	ect file at %s. Error code: %s" % [project_path, FileAccess.get_open_error()])
		return ERR_FILE_NOT_FOUND
	
	var json = JSON.parse_string(proj_file.get_as_text())
	
	if json == null:
		push_error("Couldn't parse the project file at %s" % project_path)
		return ERR_FILE_CORRUPT
	
	deserialize_project(json)
	
	# Since we just opened the project, the save state is true
	# Why deferred?
	# If not some of the deserialized object alter the state after this function ends
	# even tho we called deserialize above. Probably because the nodes are not added
	# to the hierarchy untill the idle time, when they call set_state(false).
	# So we just delay this call to that idle time also.
	SingletonObject.call_deferred("save_state", true)
	
	self.save_path = project_path
	return OK
	#SingletonObject.hide_loading_screen()
# end of open_project_given_path function


func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_editorpanes()


func _on_exit_confirmation_dialog_canceled():
	%ExitConfirmationDialog.hide()


func _on_exit_confirmation_dialog_confirmed():
	await self.save_project()
	get_tree().quit()


func _on_exit_confirmation_dialog_custom_action(action: StringName):
	if action == "exit":
		get_tree().quit()
