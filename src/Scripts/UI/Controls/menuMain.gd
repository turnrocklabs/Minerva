extends MenuBar

@onready var view = $View as PopupMenu

# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
#	pass

# handle file options
func _on_file_index_pressed(index):
	match index:
		0:
			SingletonObject.editor_container.editor_pane.add(Editor.TYPE.Text)
		1:
			%fdgOpenFile.popup_centered(Vector2i(800, 600))
		2: # this match is for the save button
				# get current editor tab
			var tabs = SingletonObject.editor_container.editor_pane.Tabs
			var current_editor_tab = tabs.get_current_tab_control()
			
			#check is tab exists and a file for the tab doesnot exist (the file is being saved for the first time)
			if current_editor_tab and !current_editor_tab.file_saved_in_disc :
				current_editor_tab.prompt_close(true)# shows file save pop up
				
			else: # this runs if the file has been saved already so the pop up for saving does not apear
				current_editor_tab.save_file_to_disc(current_editor_tab.file) #calls save to disc fun
				
		3: #this match if for the save as... button
			var tabs = SingletonObject.editor_container.editor_pane.Tabs
			var current_editor_tab = tabs.get_current_tab_control()
			if current_editor_tab:
				current_editor_tab.prompt_close(true)
		4:
			## Set a target size, have a border, and display the preferences popup.
			var target_size = %VBoxRoot.size / 2
			%PreferencesPopup.borderless = false
			%PreferencesPopup.size = target_size
			%PreferencesPopup.popup_centered()


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
	# if zoom items are selected
	match index:
		4: SingletonObject.main_scene.zoom_ui(5); return
		5: SingletonObject.main_scene.zoom_ui(-5); return
		6: SingletonObject.main_scene.reset_zoom(); return

	if view.is_item_checkable(index):
		view.toggle_item_checked(index)
	
	SingletonObject.main_ui.set_chat_pane_visible(view.is_item_checked(0))
	SingletonObject.main_ui.set_editor_pane_visible(view.is_item_checked(1))
	SingletonObject.main_ui.set_notes_pane_visible(view.is_item_checked(2))


func _on_view_about_to_popup():
	view.set_item_checked(0, SingletonObject.main_ui.chat_pane.visible)
	view.set_item_checked(1, SingletonObject.main_ui.editor_pane.visible)
	view.set_item_checked(2, SingletonObject.main_ui.notes_pane.visible)


func _on_file_about_to_popup():
	var tabs = SingletonObject.editor_container.editor_pane.Tabs
	var control = tabs.get_current_tab_control()
	#checks if current tabs exists and enables saving features if so
	if control:
		%File.set_item_disabled(2, false)
		%File.set_item_disabled(3, false)
	else: 
		%File.set_item_disabled(2, true)
		%File.set_item_disabled(3, true)
