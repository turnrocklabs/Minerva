extends MenuBar

@onready var view = $View as PopupMenu


# Called when the node enters the scene tree for the first time.
func _ready():
	%leGoogleVertexKey.text = SingletonObject.API_KEY.get(SingletonObject.API_PROVIDER.GOOGLE, "")
	%leAnthropicKey.text = SingletonObject.API_KEY.get(SingletonObject.API_PROVIDER.ANTHROPIC, "")
	%leOpenAIKey.text = SingletonObject.API_KEY.get(SingletonObject.API_PROVIDER.OPENAI, "")

	%leFirstName.text = SingletonObject.config_file.get_value("USER", "first_name", "")
	%leLastName.text = SingletonObject.config_file.get_value("USER", "last_name", "")

# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
#	pass

# handle file options
func _on_file_index_pressed(index):
	match index:
		0:
			%fdgOpenFile.popup_centered(Vector2i(800, 600))
			pass
		1:
			## Set a target size, have a border, and display the preferences popup.
			var target_size = %VBoxRoot.size / 2
			%PreferencesPopup.borderless = false
			%PreferencesPopup.size = target_size
			%PreferencesPopup.popup_centered()
	pass # Replace with function body.

# handle saving the file
func _on_save_keys_pressed():
	SingletonObject.config_file.set_value("USER", "first_name", %leFirstName.text)
	SingletonObject.config_file.set_value("USER", "last_name", %leLastName.text)

	## set the value of the singleton's API_KEY dictionary
	SingletonObject.API_KEY[SingletonObject.API_PROVIDER.GOOGLE] = %leGoogleVertexKey.text
	SingletonObject.API_KEY[SingletonObject.API_PROVIDER.ANTHROPIC] = %leAnthropicKey.text
	SingletonObject.API_KEY[SingletonObject.API_PROVIDER.OPENAI] = %leOpenAIKey.text
	SingletonObject.save_preferences() # will save just API KEYS

## Handler:
# _on_project_index_pressed handles the "Project" menu.
func _on_project_index_pressed(index):
	match index:
		0:
			## Create a new blank project
			SingletonObject.NewProject.emit()
			pass
		1:
			## Open a project
			SingletonObject.OpenProject.emit()
			pass
		2:
			## Save a project
			SingletonObject.SaveProject.emit()
			pass
		3:
			## Save as a project
			SingletonObject.SaveProjectAs.emit()
			pass
	pass # Replace with function body.


func _on_view_index_pressed(index: int):
	if view.is_item_checkable(index):
		view.toggle_item_checked(index)
	
	%LeftPane.visible = view.is_item_checked(0)
	%MiddlePane.visible = view.is_item_checked(1)
	%RightPane.visible = view.is_item_checked(2)

	%LeftPane.get_parent().visible = %LeftPane.visible or %MiddlePane.visible