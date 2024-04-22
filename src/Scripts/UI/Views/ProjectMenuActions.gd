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
	
	var serialized: Array[String] = serialize_project()
	print(serialized)
	# var save_file = FileAccess.open(save_path, FileAccess.WRITE)
	# for line: String in serialized:
	# 	save_file.store_line(line)
	pass

## Function:
# serialize_project iterates through the notes and chats and creates an array
# each line in the array is the contents of either the notes or the chats.
func serialize_project() -> Array[String]:
	var output: Array[String] = [] ## a set of lines, each serialized objects
	var notes: Array[String] = []  ## the serialized working memory (aka notes) 
	var chats: Array[String] = []  ## the chats seriazlized
	var chat_provider: String = "" ## Which chat provider is active
	var active_notes_index: int = 0 ## which of the notes tabs is selected and active
	var active_chat_index: int = 0 ## which chat tab is active

	# Serialize the notes first.
	for note_tab: MemoryThread in SingletonObject.ThreadList:
		var serialized_note_tab:String = note_tab.Serialize()
		notes.append(serialized_note_tab)
	
	# Now serialize the chats.
	for chat_thread: ChatHistory in SingletonObject.ChatList:
		var serialized_chat_tab: String = chat_thread.Serialize()
		chats.append(serialized_chat_tab)
	

	return chats

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
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass


func _on_fdg_save_as_file_selected(path):
	self.save_path = path
	self.save_project()
	pass # Replace with function body.
