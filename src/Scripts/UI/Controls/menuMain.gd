extends MenuBar

# Called when the node enters the scene tree for the first time.
func _ready():
	%leGoogleVertexKey.text = SingletonObject.API_KEY.get(SingletonObject.API_PROVIDER.GOOGLE, "")
	%leAnthropicKey.text = SingletonObject.API_KEY.get(SingletonObject.API_PROVIDER.ANTHROPIC, "")
	%leOpenAIKey.text = SingletonObject.API_KEY.get(SingletonObject.API_PROVIDER.OPENAI, "")
	pass # Replace with function body.

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
	## set the value of the singleton's API_KEY dictionary
	SingletonObject.API_KEY[SingletonObject.API_PROVIDER.GOOGLE] = %leGoogleVertexKey.text
	SingletonObject.API_KEY[SingletonObject.API_PROVIDER.ANTHROPIC] = %leAnthropicKey.text
	SingletonObject.API_KEY[SingletonObject.API_PROVIDER.OPENAI] = %leOpenAIKey.text
	SingletonObject.save_api_keys()
	pass


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
