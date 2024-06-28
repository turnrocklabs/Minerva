extends MenuBar

@onready var view = $View as PopupMenu
@onready var project: PopupMenu = $Project


func _ready() -> void:
	pass


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
	#checks if current tabs exists and enables saving features if so
	if SingletonObject.is_editor_file_open():
		%File.set_item_disabled(2, false)
		%File.set_item_disabled(3, false)
	else: 
		%File.set_item_disabled(2, true)
		%File.set_item_disabled(3, true)


func _on_project_about_to_popup() -> void:
	#checks if current editor tabs, chat tabs or notes exists 
	#and enables saving features for ther project if so
	if SingletonObject.any_project_features_open():
		%Project.set_item_disabled(2, false)
		%Project.set_item_disabled(3, false)
	else:
		%Project.set_item_disabled(2, true)
		%Project.set_item_disabled(3, true)

#this function gets call when the mouse ehovers over the MenuBar
#it has a timer so it doesn't execute all the time
var timer
var active: bool =true
func _on_mouse_entered() -> void:
	if active:
		load_recent_projects()
		active = false
		
		timer = Timer.new()
		timer.wait_time = 5.0
		timer.timeout.connect(set_active)
		add_child(timer)
		timer.start()


func set_active():
	active = true
	timer.queue_free() 


#load recent projects if they exist on the config file
#this function gets called on ready and when you hover over menuMain
var submenu
func load_recent_projects():
	
	if SingletonObject.has_recent_projects():# check if user has recent projects
		
		# this if statement removes the open recent item if there was one already
		if project.get_tree().has_group("open_recent"):
			project.remove_item(project.item_count - 1)
		
		# create submenu item, fill it with recent projectd and add to menu
		submenu = PopupMenu.new()
		submenu.name = "OpenRecentSubmenu"
		submenu.add_to_group("open_recent")
		submenu.index_pressed.connect(_on_open_recent_project)
		var recent_projects = SingletonObject.get_recent_projects()
		if recent_projects:
			for item in recent_projects:
				print(item)
				submenu.add_item(item)
		
		
		project.add_child(submenu)# adds submenu to scene tree
		#add submenu as a submenu of indicated item
		project.add_submenu_item("Open Recent", "OpenRecentSubmenu")


func _on_open_recent_project(index: int):
	var selected_project_name = submenu.get_item_text(index)
	SingletonObject.OpenRecentProject.emit(selected_project_name)





