### Reference Information ###
### Title: menuMain
extends MenuBar

@onready var view = $View as PopupMenu
@onready var project: PopupMenu = $Project
@onready var edit: PopupMenu = %File

var popUpRecent
var recentList
var ButtonCloseForPopUp

# Add a new submenu for 'File'
@onready var file_submenu: PopupMenu = PopupMenu.new()

func _on_file_index_pressed(index):
	match index:
		1:
			%fdgOpenFile.popup_centered()
		2: # this match is for the save button
				# get current editor tab
			var tabs = SingletonObject.editor_container.editor_pane.Tabs
			var current_editor_tab = tabs.get_current_tab_control()
			
			#check is tab exists and a file for the tab doesn't exist (the file is being saved for the first time)
			if current_editor_tab and !current_editor_tab.file_saved_in_disc :
				current_editor_tab.prompt_close(true)# shows file save pop up
				
			else: # this runs if the file has been saved already so the pop up for saving does not appear
				current_editor_tab.save_file_to_disc(current_editor_tab.file) #calls save to disc func
				
		3: #this match if for the save as... button
			var tabs = SingletonObject.editor_container.editor_pane.Tabs
			var current_editor_tab = tabs.get_current_tab_control()
			#current_editor_tab.save_file_to_disc(current_editor_tab.file, true)
			if current_editor_tab:
				current_editor_tab.prompt_close(true, true)
		4:
			## Set a target size, have a border, and display the preferences popup.
			#var target_size = %VBoxRoot.size / 2
			#%PreferencesPopup.borderless = false
			#%PreferencesPopup.size = target_size
			%PreferencesPopup.popup_centered()

# Handle new file creation
func handle_new_file():
	SingletonObject.editor_container.editor_pane.add(Editor.Type.TEXT)

# Handle new graphics creation
func handle_new_graphics():
	SingletonObject.is_graph = true
	SingletonObject.editor_container.editor_pane.add(Editor.Type.GRAPHICS)

func _on_file_submenu_index_pressed(index):
	match index:
		0:
			handle_new_file()
		1:
			SingletonObject.is_picture = false
			handle_new_graphics()
			


func _on_package_submenu_id_pressed(id: int):
	match id:
		0: SingletonObject.PackageProject.emit()
		1: SingletonObject.UnpackageProject.emit()


@onready var project_recent: Window = %ProjectRecent

func _ready():
	
	popUpRecent = project_recent
	popUpRecent.visible = false
	#set op position for pop up by a center of the root node
	popUpRecent.position.x = $"../../..".size.x/2
	popUpRecent.position.y = $"../../..".size.y/2

	
	recentList = popUpRecent.find_child("RecentList")
	popUpRecent.close_requested.connect(popUpClose)
	
	#_rebuild_recent_projects_ui()
	# Create the new submenu
	file_submenu.name = "file_submenu"
	file_submenu.add_item("New File")
	file_submenu.add_item("New Graphics")
	file_submenu.index_pressed.connect(_on_file_submenu_index_pressed)

	# Create package project submenu
	var package_submenu: = PopupMenu.new()
	package_submenu.name = "Package Project"
	package_submenu.add_item("Create", 0)
	package_submenu.add_item("Unpack", 1)
	package_submenu.id_pressed.connect(_on_package_submenu_id_pressed)
	
	%Project.add_child(package_submenu)
	%Project.add_submenu_item("Package Project", package_submenu.name, 0)


	# Add the "New" submenu to the top of the "File" menu
	%File.add_child(file_submenu)
	%File.add_submenu_item("New", "file_submenu", 0)  # Note the index 0 here

	# Add the rest of the "File" menu items
	%File.add_item("Open", 1)
	%File.add_item("Save", 2)
	%File.add_item("Save As", 3)
	%File.add_item("Preferences", 4)


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
		5:
			popUpRecent.visible = true
			load_recent_projects()
			#pass

func _on_view_id_pressed(id: int):
	# if zoom items are selected
	match id:
		4: SingletonObject.main_scene.zoom_ui(2); return
		5: SingletonObject.main_scene.zoom_ui(-2); return
		6: SingletonObject.main_scene.reset_zoom(); return
		8: _show_notes()
		9: _show_messages()
		11: SingletonObject.set_icon_size_24.emit(); return
		12: SingletonObject.set_icon_size_48.emit(); return
		13: SingletonObject.set_icon_size_68.emit(); return
		16: SingletonObject.increment_scale_ui()
		17: SingletonObject.decrement_ui_scale()
		18: SingletonObject.reset_ui_scale()
	var index = view.get_item_index(id)
	
	if view.is_item_checkable(index):
		view.toggle_item_checked(index)
	
	SingletonObject.main_ui.set_chat_pane_visible(view.is_item_checked(view.get_item_index(0)))
	SingletonObject.main_ui.set_editor_pane_visible(view.is_item_checked(view.get_item_index(1)))
	SingletonObject.main_ui.set_notes_pane_visible(view.is_item_checked(view.get_item_index(2)))
	SingletonObject.main_ui.set_terminal_pane_visible(view.is_item_checked(view.get_item_index(10)))

func _show_notes():
	for ch in SingletonObject.ChatList:
		for chi in ch.HistoryItemList:
			if not chi.Visible:
				chi.Visible = true
				chi.rendered_node.render()

func _show_messages():
	for thread in SingletonObject.ThreadList:
		for item in thread.MemoryItemList:
			if not item.Visible:
				item.Visible = true
	SingletonObject.NotesTab.render_threads()

func _on_view_about_to_popup():
	view.set_item_checked(0, SingletonObject.main_ui.chat_pane.visible)
	view.set_item_checked(1, SingletonObject.main_ui.editor_pane.visible)
	view.set_item_checked(2, SingletonObject.main_ui.notes_pane.visible)
	view.set_item_checked(view.get_item_index(10), SingletonObject.main_ui.terminal_pane.visible)

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
	#and enables saving features for their project if so
	if SingletonObject.any_project_features_open():
		%Project.set_item_disabled(2, false)
		%Project.set_item_disabled(3, false)
	else:
		%Project.set_item_disabled(2, true)
		%Project.set_item_disabled(3, true)

#this function gets call when the mouse ers over the MenuBar
#it has a timer so it doesn't execute all the time
var timer
var active: bool = true
func _on_mouse_entered() -> void:
	if active:
		active = false
		call_deferred("load_recent_projects_sub")
		_rebuild_recent_projects_ui()
		#add submenu fro button new edit
		
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
var projects_size: int
func load_recent_projects():
	# Clear existing recent project entries in the UI more robustly
	for child in recentList.get_children():
		if child is HBoxContainer:
			child.queue_free()

	if SingletonObject.has_recent_projects():
		var recent_projects = SingletonObject.get_recent_projects()
		projects_size = recent_projects.size()

		if recent_projects:
			for i in range(projects_size):
				var item = recent_projects[i]
				_add_recent_project_ui(i, item)

func _add_recent_project_ui(index: int, item: String):

	var newRecentButtons = preload("res://Scenes/RecentPopUpButtons.tscn").instantiate() # Instantiate a NEW one each time
	
	newRecentButtons.set_meta("project_path", item)
	var RecentBtn = newRecentButtons.find_child("RecentBtn")
	var exitBtn = newRecentButtons.find_child("exitBtn")
	var _dragBtn = newRecentButtons.find_child("DragButton")
	# Limit the text length and add ellipsis if necessary
	newRecentButtons.name = item
	newRecentButtons.index = index
	var displayed_text = item
	#if displayed_text.length() > 16:
		#displayed_text = displayed_text.substr(0, 13) + "..."
	RecentBtn.text = displayed_text
	
	# Set a fixed size for the buttons (optional, but good practice)
	var button_size = Vector2(100, 25) 
	RecentBtn.size = button_size
	exitBtn.size = Vector2(25,25)


	RecentBtn.pressed.connect(_on_open_recent_project.bind(index, item))
	exitBtn.pressed.connect(_on_remove_recent_single.bind(newRecentButtons.get_meta("project_path")))

	recentList.add_child(newRecentButtons) # Add the *new instance* to the VboxContainer
	
	
func _on_open_recent_project(index: int, itemText:String):
	# The "Clear Recent Projects" button should be handled separately, not within this function.  Add this logic to the PopupMenu where that button resides. 
	SingletonObject.OpenRecentProject.emit(itemText)
	popUpRecent.visible = false


func _on_remove_recent_single(index: String):
	SingletonObject.remove_recent_project(index) # Remove the project data
	_rebuild_recent_projects_ui()  # Update the UI
	load_recent_projects_sub()
	projects_size -= 1

func _rebuild_recent_projects_ui():
	var recent_projects = SingletonObject.get_recent_projects()
	var children = recentList.get_children()

	# 1. Remove buttons for projects no longer in the recent list
	for child in children:
		if child.has_meta("project_path") and child.get_meta("project_path") not in recent_projects:
			child.queue_free()

	children = recentList.get_children() # Update children after removal

	# 2. Add buttons for new projects
	for i in range(recent_projects.size()):
		var project_path = recent_projects[i]
		var existing_button = _find_existing_button(project_path, children)
		if !existing_button:
			_add_recent_project_ui(i, project_path)

	children = recentList.get_children() # Update children after adding

	# 3. Reorder existing buttons to match the recent_projects order
	for i in range(recent_projects.size()):
		var project_path = recent_projects[i]
		var button = _find_existing_button(project_path, children)
		if button:
			recentList.move_child(button, i)  # Move to the correct index


func _find_existing_button(project_path: String, children: Array) -> Node:
	for child in children:
		if child.has_meta("project_path") and child.get_meta("project_path") == project_path:
			return child
	return null
	
var submenu: PopupMenu
func load_recent_projects_sub():
	#if submenu: submenu.queue_free()
	if SingletonObject.has_recent_projects():
		# this if statement removes the open recent item if there was one already
		if project.get_tree().has_group("open_recent"):
			project.remove_item(project.item_count - 1)
		if project.get_tree().has_group("open_recent"):
			# Remove the old submenu entirely instead of individual items
			for n in project.get_children():
				if n is PopupMenu and n.is_in_group("open_recent"):
					n.free()  # or n.queue_free() if needed
					break  # Assume only one submenu in the group
					
		
		# create submenu item, fill it with recent projects and add to menu
		submenu = PopupMenu.new()
		submenu.name = "OpenRecentSubmenu"
		submenu.add_to_group("open_recent")
		submenu.index_pressed.connect(_on_open_recent_project_sub)
		var recent_projects = SingletonObject.get_recent_projects()
		projects_size = recent_projects.size()
		
		if recent_projects:
			submenu.get_children().clear()
			for item in recent_projects:
				submenu.add_item(item)
		
		submenu.add_separator()
		var clear_recent_item = "Clear recent Projects"
		submenu.add_item(clear_recent_item)
		
		var manager = "Manage..."
		submenu.add_item(manager)
		
		project.add_child(submenu)# adds submenu to scene tree
		#add submenu as a submenu of indicated item
		project.add_submenu_item("Open Recent", "OpenRecentSubmenu")
		
		

func _on_open_recent_project_sub(index: int):
	if projects_size + 1 == index: # check if the index is for the clear recent projects button
		SingletonObject.clear_recent_projects()
		project.remove_item(project.item_count - 1)
	elif projects_size + 2 == index:
		_rebuild_recent_projects_ui()
		popUpRecent.visible = true
	else:
		var selected_project_name = submenu.get_item_text(index)
		SingletonObject.OpenRecentProject.emit(selected_project_name)

func popUpClose():
	popUpRecent.visible = false

func _on_close_button_pressed() -> void:
	popUpRecent.visible = false

###
### End Reference Information ###
