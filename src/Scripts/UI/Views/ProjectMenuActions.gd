class_name ProjectMenu
extends Control

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


func save_project_as(file=""):
	if file == "":
		%fdgSaveAs.popup_centered(Vector2i(800, 600))
	else:
		save_path=file
		save_project()
	pass

func save_project():
	if save_path == null or save_path == "":
		return(save_project_as())
	# ask the singleton to serialize all state vars.
	
	var serialized: String = serialize_project()
	var save_file = FileAccess.open(save_path, FileAccess.WRITE)
	save_file.store_line(serialized)
	pass

## Function:
# serialize_project iterates through the notes and chats and creates an array
# each line in the array is the contents of either the notes or the chats.
func serialize_project() -> String:
	var notes: Array[Dictionary] = []
	var chats: Array[Dictionary] = []
	var active_notes_index: int = 0 ## which of the notes tabs is selected and active
	var active_chat_index: int = 0 ## which chat tab is active
	var last_tab_index: int = 0 ##

	# Serialize the notes first.
	for note_tab: MemoryThread in SingletonObject.ThreadList:
		var serialized_note_tab = note_tab.Serialize()
		notes.append(serialized_note_tab)
	
	# # Now serialize the chats.
	# for chat_thread: ChatHistory in SingletonObject.ChatList:
	# 	var serialized_chat_tab = chat_thread.Serialize()
	# 	chats.append(serialized_chat_tab)

	var save_dict: Dictionary = {
		"ThreadList" : notes,
		# "ChatList" : chats,
		"last_tab_index": SingletonObject.last_tab_index,
		"active_chatindex": SingletonObject.active_chatindex,
		"active_notes_index": SingletonObject.NotesTab.ActiveThreadIndex
	}
	var stringified_save: String = JSON.stringify(save_dict, "\t")
	return stringified_save


func deserialize_project(data: Dictionary):
	SingletonObject.last_tab_index = data.get("last_tab_index", 0)
	SingletonObject.active_chatindex = data.get("active_chatindex", 0)
	SingletonObject.NotesTab.ActiveThreadIndex = data.get("active_notes_index", 0)

	var threads: Array[MemoryThread] = []
	for thread_data in data.get("ThreadList", []):
		threads.append(MemoryThread.Deserialize(thread_data))
	SingletonObject.initialize_notes(threads)

	# for chat_data in data.get("ChatList", []):
	# 	chats.append(ChatHistory.Deserialize(chat_data))
	
	


func close_project():
	save_project()
	_new_project()
	pass

# Called when the node enters the scene tree for the first time.
func _ready():
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
