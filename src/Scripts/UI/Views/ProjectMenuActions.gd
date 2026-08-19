class_name ProjectMenu
extends Control

# Whether the user selected the file or closed the dialog this signal is emitted
signal save_as_dialog_exited()

var save_path: String
var last_save_path: String

func _clear_notes_container(container: NotesContainer) -> void:
	if not container:
		return
	for i in range(container.get_tab_count() - 1, -1, -1):
		var control := container.get_tab_control(i)
		if control:
			control.queue_free()

func update_last_save_path(new_path: String) -> void:
	SingletonObject.last_saved_path = new_path + "/"

## Function:
# _new_project empties all the tabs and lists currently stored as notes or chats.
# it also blanks out the save file variable to force a save_as
func _new_project():
	# Clear all service histories
	SingletonObject.ChatList.clear()
	SingletonObject.chat_groups.clear()
	if SingletonObject.Chats:
		SingletonObject.Chats.reset_group_state()
	SingletonObject.NotesList.clear()
	
	# Initialize chat pane
	if SingletonObject.Chats:
		SingletonObject.Chats.clear_all_chats()
	
	# Clear notes pane if it exists
	if SingletonObject.Notes:
		SingletonObject.Notes.clear_all_notes()
	if SingletonObject.agent_notes_container:
		_clear_notes_container(SingletonObject.agent_notes_container)
	
	SingletonObject.editor_container.clear_editor_tabs()
	SingletonObject.clear_registered_objects()
	if SingletonObject.trigger_manager:
		SingletonObject.trigger_manager.clear_all()
	if SingletonObject.ledger_manager:
		SingletonObject.ledger_manager.clear()
	save_path = ""
	SingletonObject.current_project_path = ""

	# Fresh implicit project -> fresh identity + zeroed ref counter (DCR
	# 019e9f602391 P1), persisted to the scratch so refs survive a restart.
	if SingletonObject.project_identity:
		SingletonObject.project_identity.start_new_implicit()

	await get_tree().process_frame
	SingletonObject.updated_save_state.emit("", true)

func open_project(path: = ""):
	if path.is_empty():
		%fdgOpenProject.title = "Open a Project File"
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
	ppw.data = await serialize_project()
	ppw.popup_centered()

func unpackage_project():
	var upw: UnpackageProjectWindow = %UnpackageProjectWindow
	upw.popup_centered()

func save_unsaved_editors() -> void:
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
	
	var proj_data: = await serialize_project()

	var save_file = FileAccess.open(save_path, FileAccess.WRITE)
	save_file.store_line(JSON.stringify(proj_data, "\t"))
	
	SingletonObject.save_recent_project(save_path)
	SingletonObject.current_project_path = save_path

	# Project is now explicit — its identity lives in the .minproj, so drop the
	# implicit user:// scratch and stop treating it as implicit (DCR 019e9f602391).
	if SingletonObject.project_identity:
		SingletonObject.project_identity.mark_explicit()

	SingletonObject.save_state(true)
	SingletonObject.updated_save_state.emit(save_path.get_file(), true)
	SingletonObject.UpdateUnsavedTabIcon.emit()

func save_editor_panes(skip_selecting_items: bool = false) -> bool:
	var unsaved_editors = SingletonObject.editor_container.editor_pane.unsaved_editors()
	
	if not SingletonObject.saved_state or unsaved_editors:
		var item_list: ItemList = %ExitConfirmationDialog.get_node("v/ItemList")
		item_list.clear()
		for editor in unsaved_editors:
			var idx = SingletonObject.editor_pane.Tabs.get_tab_idx_from_control(editor)
			var tab_title = SingletonObject.editor_pane.Tabs.get_tab_title(idx)
			var item_idx = item_list.add_item(tab_title)
			item_list.set_item_metadata(item_idx, editor)
			
		if skip_selecting_items:
			var items: = item_list.item_count
			var counter: = 0
			while counter < items:
				item_list.select(counter, false)
				counter += 1
			%ExitConfirmationDialog.get_node("v").visible = item_list.item_count > 0
			await save_unsaved_editors()
		else:
			%ExitConfirmationDialog.get_node("v").visible = item_list.item_count > 0
			%ExitConfirmationDialog.popup_centered(Vector2i(400, 150))
	else:
		return true

	return false

#region Serialize/Deserialize Project

## Serialize project with multiple service types
func serialize_project() -> Dictionary:
	var notes: = SingletonObject.notes_container.serialize()
	var agent_notes: Array[Dictionary] = []
	if SingletonObject.agent_notes_container:
		agent_notes = SingletonObject.agent_notes_container.serialize()
	var chats: Array[Dictionary] = []
	var notes_histories: Array[Dictionary] = []
	
	# Serialize chat histories
	for chat_thread: ChatHistory in SingletonObject.ChatList:
		var serialized_chat = chat_thread.Serialize()
		chats.append(serialized_chat)

	# Serialize notes histories
	for notes_thread: NotesServiceHistory in SingletonObject.NotesList:
		var serialized_notes = notes_thread.Serialize()
		notes_histories.append(serialized_notes)

	var editors = await SingletonObject.editor_container.serialize()

	# Get current tab indices with fallbacks
	var active_chat_index = 0
	var active_notes_index = 0
	
	if SingletonObject.Chats and SingletonObject.Chats.get_tab_count() > 0:
		active_chat_index = SingletonObject.Chats.current_tab
	
	if SingletonObject.Notes and SingletonObject.Notes.get_tab_count() > 0:
		active_notes_index = SingletonObject.Notes.current_tab

	var project_data: Dictionary = {
		"ThreadList": notes,
		"AgentThreadList": agent_notes,
		"ChatList": chats,
		"ChatGroups": SingletonObject.chat_groups.serialize(),
		"NotesHistories": notes_histories,
		"Editors": editors,
		"Triggers": SingletonObject.trigger_manager.serialize() if SingletonObject.trigger_manager else [],
		"Ledger": SingletonObject.ledger_manager.serialize() if SingletonObject.ledger_manager else [],
		"last_tab_index": SingletonObject.last_tab_index,
		"active_chatindex": active_chat_index,
		"active_notes_index": SingletonObject.notes_container.current_tab,
		"active_notes_history_index": active_notes_index,
		"active_editor_index": SingletonObject.editor_pane.Tabs.current_tab,
		"version": "2.0"  # Version for future migration handling
	}

	# Stamp the stable project identity (project_id + annotation_ref_seq) into the
	# project_data so it persists into the .minproj (DCR 019e9f602391 P1). Flows
	# through both the plain-JSON and ProjectPackage zip writers unchanged.
	if SingletonObject.project_identity:
		SingletonObject.project_identity.ensure()
		SingletonObject.project_identity.write_to_project_data(project_data)

	return project_data

func deserialize_project(data: Dictionary) -> int:
	# Handle legacy and new formats gracefully
	#var version = data.get("version", "1.0")

	# Adopt the loaded project's stable identity before restoring content (DCR
	# 019e9f602391 P1). Legacy projects with no project_id get one minted; the
	# implicit scratch is cleared since this loaded project is now the context.
	if SingletonObject.project_identity:
		SingletonObject.project_identity.adopt_from_project_data(data)

	# Deserialize notes container (legacy notes system)
	SingletonObject.notes_container.deserialize(data.get("ThreadList", []))
	if SingletonObject.agent_notes_container:
		_clear_notes_container(SingletonObject.agent_notes_container)
		SingletonObject.agent_notes_container.deserialize(data.get("AgentThreadList", []))

	# Clear rendered_node references from currently displayed chats BEFORE clearing ChatList
	if SingletonObject.Chats:
		for chat_history in SingletonObject.ChatList:
			chat_history.VBox = null
			for item in chat_history.HistoryItemList:
				item.rendered_node = null

		# Clear the UI
		SingletonObject.Chats.clear_all_chats()

	# Clear existing histories
	SingletonObject.ChatList.clear()
	SingletonObject.NotesList.clear()

	# Chat groups must land BEFORE the chats: ChatPane's filter resolves each
	# chat's ChatGroupId against the registry and treats an unknown id as
	# ungrouped, so an empty registry here would silently orphan every chat.
	# Group VIEW state is per-project but does not live in the registry, so it has
	# to be dropped explicitly — a `grp_N` id from the previous project either
	# hides every chat here or collides with an unrelated group of the same
	# ordinal.
	if SingletonObject.Chats:
		SingletonObject.Chats.reset_group_state()
	SingletonObject.chat_groups.deserialize(data.get("ChatGroups", {}))

	# Deserialize chat histories
	var chat_data = data.get("ChatList", [])
	for chat_item in chat_data:
		var chat_history = ServiceHistory.Deserialize(chat_item)
		if chat_history is ChatHistory:
			SingletonObject.ChatList.append(chat_history)
		else:
			# Fallback: create ChatHistory if deserialization returns wrong type
			var fallback_provider = _get_fallback_provider()
			var fallback_chat = ChatHistory.new(fallback_provider)
			fallback_chat.HistoryName = chat_item.get("HistoryName", "Chat")
			SingletonObject.ChatList.append(fallback_chat)

	var notes_data = data.get("NotesHistories", [])
	print("Loading ", notes_data.size(), " notes histories")
	for notes_item in notes_data:
		print("Notes history: ", notes_item.get("HistoryName"), " with ", notes_item.get("HistoryItemList", []).size(), " items")
		var notes_history = ServiceHistory.Deserialize(notes_item)
		if notes_history is NotesServiceHistory:
			print("Successfully created NotesServiceHistory with ", notes_history.HistoryItemList.size(), " items")
			SingletonObject.NotesList.append(notes_history)
		else:
			# Fallback: create NotesServiceHistory if deserialization fails
			var fallback_provider = _get_fallback_provider()
			var fallback_notes = NotesServiceHistory.new(fallback_provider)
			fallback_notes.HistoryName = notes_item.get("HistoryName", "Notes")
			SingletonObject.NotesList.append(fallback_notes)

	# Deserialize editors
	SingletonObject.editor_container.clear_editor_tabs()
	var editor_nodes: Array = []
	if data.get("Editors"):
		editor_nodes = await EditorContainer.deserialize(data.get("Editors", []))
	
	for editor in editor_nodes:
		SingletonObject.editor_pane.Tabs.add_child(editor)
		var tab_idx = SingletonObject.editor_pane.Tabs.get_tab_idx_from_control(editor)
		SingletonObject.editor_pane.Tabs.set_tab_title(tab_idx, editor.tab_title)
		if editor.file:
			SingletonObject.editor_pane.Tabs.set_tab_tooltip(tab_idx, editor.file)

	# Restore triggers (per-project)
	if SingletonObject.trigger_manager:
		SingletonObject.trigger_manager.deserialize(data.get("Triggers", []))

	# Restore ledger (per-project)
	if SingletonObject.ledger_manager:
		SingletonObject.ledger_manager.deserialize(data.get("Ledger", []))

	# Initialize chat pane with histories
	if SingletonObject.Chats:
		_initialize_chat_pane()

	# Initialize notes pane with histories
	# if SingletonObject.Notes:
		# _initialize_notes_pane()

	# Restore tab indices with bounds checking
	SingletonObject.last_tab_index = data.get("last_tab_index", 0)

	# Restore notes container tab
	var current_notes_tab = data.get("active_notes_index", 0)
	if SingletonObject.notes_container.get_tab_count() > current_notes_tab:
		SingletonObject.notes_container.current_tab = current_notes_tab

	# Restore chat pane tab
	var current_chat_tab = data.get("active_chatindex", 0)
	if SingletonObject.Chats and SingletonObject.Chats.get_tab_count() > current_chat_tab:
		SingletonObject.Chats.current_tab = current_chat_tab

	# Restore notes pane tab
	var current_notes_history_tab = data.get("active_notes_history_index", 0)
	if SingletonObject.Notes and SingletonObject.Notes.get_tab_count() > current_notes_history_tab:
		SingletonObject.Notes.current_tab = current_notes_history_tab

	update_buffer_controls()
	
	return OK

func _get_fallback_provider() -> BaseProvider:
	"""Get a fallback provider when deserialization fails"""
	if SingletonObject.API_MODEL_PROVIDER_SCRIPTS.size() > 1:
		# Skip human provider (index 0), use second provider
		var provider_enum = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys()[1]
		return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[provider_enum].new()
	elif SingletonObject.API_MODEL_PROVIDER_SCRIPTS.size() > 0:
		# Fallback to first available provider
		var provider_enum = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys()[0]
		return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[provider_enum].new()
	else:
		push_error("No providers available for fallback")
		return null

func _initialize_chat_pane():
	"""Initialize chat pane with existing chat histories"""
	if not SingletonObject.Chats:
		return

	SingletonObject.Chats._initializing_pane = true

	for i in SingletonObject.ChatList.size():
		var chat_history: = SingletonObject.ChatList[i]
		print(chat_history)

		if not is_instance_valid(chat_history.provider):
			chat_history.provider = _get_fallback_provider()

		SingletonObject.Chats.render_history(chat_history)

	SingletonObject.Chats._initializing_pane = false

	# Loaded chats carry their own group/archived/deleted state, so the strip
	# must be re-filtered and the dock re-rendered — _ready's deferred pass only
	# covers the boot project.
	SingletonObject.Chats.prune_empty_groups()
	SingletonObject.Chats._apply_tab_filters()
	SingletonObject.Chats._refresh_group_dock()

func _initialize_notes_pane():
	"""Initialize notes pane with existing notes histories"""
	if not SingletonObject.Notes:
		return
		
	SingletonObject.Notes.clear_all_notes()
	
	print("NOTES")
	for notes_history in SingletonObject.NotesList:
		print(notes_history)
		# Ensure provider is valid before rendering
		if not is_instance_valid(notes_history.provider):
			notes_history.provider = _get_fallback_provider()
		
		SingletonObject.Notes.render_history(notes_history)

#endregion Serialize/Deserialize Project

func close_project():
	save_project()
	_new_project()

# Called when the node enters the scene tree for the first time.
func _ready():
	get_tree().set_auto_accept_quit(false)
	(%ExitConfirmationDialog as ConfirmationDialog).add_button("Exit", true, "exit")
	
	var hbox_save_as: HBoxContainer = %fdgSaveAs.get_vbox().get_child(0)
	hbox_save_as.set("theme_override_constants/separation", 14)
	
	var hbox_open_proj: HBoxContainer = %fdgOpenProject.get_vbox().get_child(0)
	hbox_open_proj.set("theme_override_constants/separation", 14)
	
	# Connect signals
	SingletonObject.NewProject.connect(self._new_project)
	SingletonObject.SaveProject.connect(self.save_project)
	SingletonObject.SaveProjectAs.connect(self.save_project_as)
	SingletonObject.PackageProject.connect(self.package_project)
	SingletonObject.UnpackageProject.connect(self.unpackage_project)
	SingletonObject.CloseProject.connect(self.close_project)
	SingletonObject.OpenProject.connect(self.open_project)
	SingletonObject.OpenRecentProject.connect(self._on_open_recent_project_selected)
	SingletonObject.SaveOpenEditorTabs.connect(save_editor_panes.bind(true))
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
	var status = await open_project_given_path(project_path)
	if status != OK:
		SingletonObject.ErrorDisplay("Project file not found", "The project was not found at the saved path.\nMaybe it was moved or deleted")

func open_project_given_path(project_path: String) -> int:
	var proj_file = FileAccess.open(project_path, FileAccess.READ)
	
	if proj_file == null:
		push_error("Couldn't open the project file at %s. Error code: %s" % [project_path, FileAccess.get_open_error()])
		return ERR_FILE_NOT_FOUND
	
	var json = JSON.parse_string(proj_file.get_as_text())
	
	if json == null:
		push_error("Couldn't parse the project file at %s" % project_path)
		return ERR_FILE_CORRUPT
	
	# Clear existing content
	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.remove_tab(i, false)

	await get_tree().process_frame

	# don't clear registered object, at least not all of them
	# if project is opened and there are remote notes, this will get messed up
	# because them we cant see if some note if already present.
	# instead, when get_registered_object, it checks if the object is valid or not
	# and returns null of it's deleted, so it's safe to leave them not deleted
	# SingletonObject.clear_registered_objects()

	# Deserialize with error handling
	var deserialize_result = await deserialize_project(json)
	if deserialize_result != OK:
		push_error("Error during project deserialization")
		return deserialize_result
	
	# Mark as saved
	SingletonObject.save_state(true)
	SingletonObject.updated_save_state.emit(project_path.get_file(), true)
	self.save_path = project_path
	SingletonObject.current_project_path = project_path
	return OK

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if await save_editor_panes():
			get_tree().quit()

func _on_exit_confirmation_dialog_canceled():
	%ExitConfirmationDialog.hide()

func _on_exit_confirmation_dialog_confirmed():
	await self.save_project()
	get_tree().quit()

func _on_exit_confirmation_dialog_custom_action(action: StringName):
	if action == "exit":
		get_tree().quit()

func update_buffer_controls() -> void:
	# Update chat pane buffer
	if SingletonObject.Chats:
		if SingletonObject.Chats.get_tab_count() > 0:
			SingletonObject.Chats.buffer_control_chats.hide()
		else:
			SingletonObject.Chats.buffer_control_chats.show()
	
	# Update notes pane buffer
	# if SingletonObject.Notes:
	# 	if SingletonObject.Notes.get_tab_count() > 0:
	# 		SingletonObject.Notes.buffer_control_notes.hide()
	# 	else:
	# 		SingletonObject.Notes.buffer_control_notes.show()
	
	# Update editor buffer
	if SingletonObject.editor_pane.Tabs.get_tab_count() > 0:
		SingletonObject.editor_pane.buffer_control_editor.hide()
	else:
		SingletonObject.editor_pane.buffer_control_editor.show()
