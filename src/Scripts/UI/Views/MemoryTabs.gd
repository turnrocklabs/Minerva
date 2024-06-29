class_name MemoryTabs
extends TabContainer



# just use current_tab
# var ActiveThreadIndex: int:

var _drag_active := false
var _hovered_tab := -1
var _hover_timer

# This flag will be set to true when we need to update the UI
var _needs_update := false

## return a single large string of all active memories
func To_Prompt(Provider) -> String:
	var have_information: bool = false
	var output: String = ""
	for this_thread:MemoryThread in SingletonObject.ThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				have_information = true
				output += "### Title: %s" % item.Title + '\n'
				output += item.Content + '\n'
				output += "###" + '\n'
	if have_information:
		output = Provider.wrap_memory(output)
	return output

func Disable_All():
	for this_thread:MemoryThread in SingletonObject.ThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				item.Enabled = false
	self.render_threads()
	pass

func enable_all():
	for this_thread:MemoryThread in SingletonObject.ThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if !item.Enabled:
				item.Enabled = true
	self.render_threads()


func enable_notes_in_tab():
	var currentNotesTab = SingletonObject.ThreadList[current_tab]
	for item:MemoryItem in currentNotesTab:
		if !item.Enabled:
			item.Enabled = true


func disable_notes_in_tab():
	var currentNotesTab = SingletonObject.ThreadList[current_tab]
	for item:MemoryItem in currentNotesTab:
		if item.Enabled:
			item.Enabled = false


func open_threads_popup(name: String = "", tab = null):
	var target_size = %VBoxRoot.size / 5 #- Vector2(100, 100)
	%NewThreadPopup.borderless = false
	%NewThreadPopup.size = target_size
	
	# %NewThreadPopup/VBoxContainer/HBoxTopRow/txtNewTabName
	%txtNewTabName.text = name

	var update = tab != null

	# set metadata so we can determine should we create new or update existing and which tab, when we click the button in the popup
	if update: %NewThreadPopup.set_meta("associated_tab", %tcThreads.get_child(tab))
	else: %NewThreadPopup.remove_meta("associated_tab")
	
	var btn_text = "Update" if update else "Create"
	%NewThreadPopup/VBoxContainer/HBoxContainer2/btnCreateThread.text = btn_text
	
	%NewThreadPopup.popup_centered()


func _on_new_pressed():
	open_threads_popup()


func _on_btn_create_thread_pressed():
	var tab_name:String = %txtNewTabName.text
	#added a check for the tab name, if no name gives a default name
	if !tab_name:
		tab_name = "notes " + str(len(SingletonObject.ThreadList) + 1)
	
	if %NewThreadPopup.has_meta("associated_tab"):
		var at = %NewThreadPopup.get_meta("associated_tab")
		at.get_meta("thread").ThreadName = tab_name
		render_threads()
	else:
		create_new_notes_tab(tab_name)
	
	%NewThreadPopup.hide()

## add indexxing system here
func create_new_notes_tab(tab_name: String = "notes 1"):
	var thread = MemoryThread.new()
	thread.ThreadName = tab_name
	var thread_memories: Array[MemoryItem] = []
	thread.MemoryItemList = thread_memories

	SingletonObject.ThreadList.append(thread)
	render_thread(thread)


func clear_all_tabs():
	var children = %tcThreads.get_children()
	for child in children:
		%tcThreads.remove_child(child)
	pass
	


func render_threads():
	# Save the last active thread.
	var last_thread = self.current_tab

	# Iterate through the SingletonObject.ThreadList and its corresponding tabs:
	for i in range(SingletonObject.ThreadList.size()):
		var thread = SingletonObject.ThreadList[i]
		var tab = %tcThreads.get_child(i)

		# If the tab exists, update its content:
		if tab:
			var vboxMemoryList = preload("res://Scripts/UI/Controls/vboxMemoryList.gd").new(self, thread.ThreadId, thread.MemoryItemList)
			tab.remove_child(tab.get_child(0))
			tab.add_child(vboxMemoryList)
			tab.name = thread.ThreadName
			tab.set_meta("thread", thread)

		# If the tab doesn't exist, create a new one:
		else:
			render_thread(thread)

	# Restore the last active thread:
	if self.get_child_count():
		self.current_tab = clampi(last_thread, 0, self.get_child_count()-1)
	

#region Add notes methods
func add_note(user_title:String, user_content: String, _source: String = ""):
	# get the active thread.
	if (SingletonObject.ThreadList == null) or (len(SingletonObject.ThreadList) - 1) <  self.current_tab:
		#SingletonObject.ErrorDisplay("Missing Thread", "Please create a new notes tab first, then try again.")
		#return
		await create_new_notes_tab()
	
	var active_thread : MemoryThread = SingletonObject.ThreadList[self.current_tab]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.TEXT
	new_memory.Title = user_title
	new_memory.Content = user_content
	new_memory.Visible = true
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)

	render_threads()


func add_audio_note(note_title: String, note_audio: AudioStreamWAV):
	if (SingletonObject.ThreadList == null) or (len(SingletonObject.ThreadList) - 1) <  self.current_tab:
		#SingletonObject.ErrorDisplay("Missing Thread", "Please create a new notes tab first, then try again.")
		#return
		await create_new_notes_tab()
	
	var active_thread : MemoryThread = SingletonObject.ThreadList[self.current_tab]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.AUDIO
	new_memory.Title = note_title
	new_memory.audio = note_audio
	new_memory.Visible = true
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()


func add_image_note(note_title: String, note_image: Image):
	if (SingletonObject.ThreadList == null) or (len(SingletonObject.ThreadList) - 1) <  self.current_tab:
		#SingletonObject.ErrorDisplay("Missing Thread", "Please create a new notes tab first, then try again.")
		#return
		await create_new_notes_tab()
	
	var active_thread : MemoryThread = SingletonObject.ThreadList[self.current_tab]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.IMAGE
	new_memory.Title = note_title
	new_memory.image = note_image
	new_memory.Visible = true
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()




#endregion Add notes methods

## Will delete the memory_item from the memory list
func delete_note(memory_item: MemoryItem):
	var active_thread : MemoryThread = SingletonObject.ThreadList[self.current_tab]

	var idx = active_thread.MemoryItemList.find(memory_item)
	if idx == -1: return
	
	active_thread.MemoryItemList.remove_at(idx)

func render_thread(thread_item: MemoryThread):
	# Create the ScrollContainer
	var scroll_container = ScrollContainer.new()
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Create a custom VBoxContainer derived class
	var vboxMemoryList = preload("res://Scripts/UI/Controls/vboxMemoryList.gd").new(self, thread_item.ThreadId, thread_item.MemoryItemList)

	# Add VBoxContainer as a child of the ScrollContainer
	scroll_container.add_child(vboxMemoryList)

	# Get %tcThreads by its unique name and add the ScrollContainer as its new child (tab)
	var foo: String = thread_item.ThreadName
	scroll_container.name = foo  # Set the tab title
	scroll_container.set_meta("thread", thread_item) # when the tab is deleted we need to know which thread item to delete
	%tcThreads.add_child(scroll_container)
	pass


func _on_close_tab(tab: int, container: TabContainer):
	var control = container.get_tab_control(tab)
	
	# This is the thread index in the list, not it's id
	var thread_idx = SingletonObject.ThreadList.find(control.get_meta("thread"))
	if thread_idx != -1:
		# Remove the thread from the list
		SingletonObject.ThreadList.remove_at(thread_idx)

		# Update the UI with the remaining threads
		render_threads()

		# Store deleted tab for potential undo
		SingletonObject.undo.store_deleted_tab_right(tab, control, "right")
	
	# Remove the tab control from the TabContainer
	container.remove_child(control) 
	
func restore_deleted_tab(tab_name: String):
	if tab_name in SingletonObject.undo.deleted_tabs:
		var data = SingletonObject.undo.deleted_tabs[tab_name]
		var tab = data["tab"]
		var control = data["control"]
		data["timer"].stop()
		# Get the MemoryThread associated with the tab.
		var thread: MemoryThread = control.get_meta("thread")

		# Re-add the MemoryThread to the ThreadList if it's not already present.
		if SingletonObject.ThreadList.find(thread) == -1:
			SingletonObject.ThreadList.append(thread)

		# Call render_thread to re-create the tab UI.
		render_thread(thread)

		# Remove the data from the deleted_tabs dictionary.
		SingletonObject.undo.deleted_tabs.erase(tab_name)
	
func _memory_thread_find(thread_id: String) -> MemoryThread:
	return SingletonObject.ThreadList.filter(
		func(t: MemoryThread):
			return t.ThreadId == thread_id
	).pop_front()



## Function:
# attach_file creates a memoryitem/note from a file.  It can detect file type
func attach_file(the_file: String):
	# Check if the file exists
	var file = FileAccess.open(the_file, FileAccess.READ)
	if file == null:
		SingletonObject.ErrorDisplay("File Error", "The file could not be opened.")
		return

	# Determine the file type
	var file_ext = the_file.get_extension().to_lower()
	var file_type = ""
	var content = ""
	var content_type = ""
	var title = the_file.get_file().get_basename()

	if file_ext in ["txt", "md", "json", "xml", "csv", "log", "py", "cs", "minproj", "gd", "go"]:
		file_type = "text"
		content = file.get_as_text()
		content_type = "text/plain"
	elif file_ext in SingletonObject.supported_image_formats:
		file_type = "image"
		var file_data = file.get_buffer(file.get_length())
		content = Marshalls.raw_to_base64(file_data)
		content_type = "image/%s" % file_ext
	elif file_ext in ["mp4", "mov", "avi", "mkv", "webm"]:
		file_type = "video"
		var file_data = file.get_buffer(file.get_length())
		content = Marshalls.raw_to_base64(file_data)
		content_type = "video/%s" % file_ext
	elif file_ext in ["mp3", "wav", "ogg", "flac"]:
		file_type = "audio"
		var file_data = file.get_buffer(file.get_length())
		content = Marshalls.raw_to_base64(file_data)
		content_type = "audio/%s" % file_ext
	else:
		SingletonObject.ErrorDisplay("Unsupported File Type", "The file type is not supported.")
		return

	# Get the active thread
	if (SingletonObject.ThreadList == null) or (len(SingletonObject.ThreadList) - 1) < self.current_tab:
		SingletonObject.ErrorDisplay("Missing Thread", "Please create a new notes tab first, then try again.")
		return
	var active_thread: MemoryThread = SingletonObject.ThreadList[self.current_tab]

	# Create a new memory item
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.Enabled = true
	new_memory.Title = title
	new_memory.Content = content
	new_memory.ContentType = content_type
	new_memory.Visible = true

	# Append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()

	file.close()
	pass



# Called when the node enters the scene tree for the first time.
func _ready():
	%tcThreads.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	%tcThreads.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(%tcThreads))

	# tab bar need mouse_filter set to pass to allow the tabcontainer to catch drag event and call _can_drop_data
	get_tab_bar().mouse_filter = MOUSE_FILTER_PASS

	# Connect signals for changes in your data
	# SingletonObject.connect("ThreadListChanged", self._on_thread_list_changed) 

	SingletonObject.ThreadList = []
	SingletonObject.NotesTab = self
	SingletonObject.AttachNoteFile.connect(self.attach_file)
	render_threads()


# if we are dragging a note above a tab, we can drop it there
func _can_drop_data(at_position: Vector2, data):
	var tab_idx = get_tab_idx_at_point(at_position)

	return tab_idx != -1 and data is Note

# find out which tab we are above
# and get it's vboxMemoryList control (which is the only child of the scroll container)
# then call it's _drop_data so it handles the Note by just appendg it and removing it from the old thread
func _drop_data(at_position: Vector2, data):
	if not data is Note: return

	var tab_idx = get_tab_idx_at_point(at_position)

	var control = get_tab_control(tab_idx)

	var vbox_memory_list = control.get_child(0)

	vbox_memory_list._drop_data(at_position, data)


func _notification(what):
	match what:
		NOTIFICATION_DRAG_BEGIN: _drag_active = true
		NOTIFICATION_DRAG_END: _drag_active = false


var clicked:= false
func _on_tab_clicked(tab: int):
	print(current_tab)
	
	if clicked:
		var tab_title = get_tab_bar().get_tab_title(tab)
		open_threads_popup(tab_title, tab)

	clicked = true
	get_tree().create_timer(0.4).timeout.connect(func(): clicked = false)


func _on_tab_hovered(tab: int):
	if _drag_active:
		current_tab = tab

# This function is called when the ThreadList is modified
func _on_thread_list_changed():
	_needs_update = true

# This function is called every frame
func _process(delta):
	if _needs_update:
		render_threads()
		_needs_update = false


# FIXME: This will interfere with render threads on project load
# one note tab is loaded and then since child is added this function is called
# and it changes the SingletonObject.ThreadList which causes the loop in render threads
# to fail since array that it's looping through is altered
# func _on_child_order_changed():
# 	# Update SingletonObject.ThreadList after tab reordering
# 	var new_thread_list: Array[MemoryThread] = []
# 	if %tcThreads == null:
# 		pass
# 	else:
# 		for child in %tcThreads.get_children():
# 			new_thread_list.append(child.get_meta("thread"))
		
# 		SingletonObject.ThreadList = new_thread_list
# 		print(SingletonObject.ThreadList)
