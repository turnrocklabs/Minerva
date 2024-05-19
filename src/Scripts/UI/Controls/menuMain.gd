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
		2:
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
	if view.is_item_checkable(index):
		view.toggle_item_checked(index)
	
	SingletonObject.main_ui.set_chat_pane_visible(view.is_item_checked(0))
	SingletonObject.main_ui.set_editor_pane_visible(view.is_item_checked(1))
	SingletonObject.main_ui.set_notes_pane_visible(view.is_item_checked(2))

func _on_view_about_to_popup():
	view.set_item_checked(0, SingletonObject.main_ui.chat_pane.visible)
	view.set_item_checked(1, SingletonObject.main_ui.editor_pane.visible)
	view.set_item_checked(2, SingletonObject.main_ui.notes_pane.visible)
