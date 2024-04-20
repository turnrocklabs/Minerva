class_name ProjectMenu
extends Control

var save_path: String

## Function:
# _new_project empties all the tabs and lists currently stored as notes or chats.
func _new_project():
	SingletonObject.initialize_notes()
	SingletonObject.initialize_chats(SingletonObject.Provider, SingletonObject.Chats)
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
	
	var serialized: String = SingletonObject.SerializeProject()
	var save_file = FileAccess.open(save_path, FileAccess.WRITE)
	save_file.store_line(serialized)
	print(serialized)
	pass
	
	

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
