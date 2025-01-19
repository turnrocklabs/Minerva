class_name MemoryTabs
extends TabContainer


@onready var tcThreads = %tcThreads
# just use current_tab
# var ActiveThreadIndex: int:

var _drag_active := false
# var _hovered_tab := -1
# var _hover_timer

# This flag will be set to true when we need to update the UI
var _needs_update := false
#var _can_drop:bool = false
## return a single large string of all active memories
func To_Prompt(provider: BaseProvider) -> Array[Variant]:
	var output: Array[Variant] = []
	
	for this_thread:MemoryThread in SingletonObject.ThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				output.append(provider.wrap_memory(item))
	
	# loop through detached notes also
	for item in SingletonObject.DetachedNotes:
		if item.Enabled:
			output.append(provider.wrap_memory(item))
	
	return output

#region Methods for toggling notes

func Disable_All():
	for this_thread:MemoryThread in SingletonObject.ThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				item.Enabled = false
	
	for item:MemoryItem in SingletonObject.DetachedNotes:
		item.Enabled = false

	self.render_threads()


func enable_all():
	for this_thread:MemoryThread in SingletonObject.ThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if !item.Enabled:
				item.Enabled = true
	
	for item:MemoryItem in SingletonObject.DetachedNotes:
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

#endregion Methods for toggling notes

func open_threads_popup(tab_name: String = "", tab = null):
	
	var update = tab != null
	
	# set metadata so we can determine should we create new or update existing and which tab, when we click the button in the popup
	if update:
		SingletonObject.associated_notes_tab.emit(tab_name, get_child(tab))
	else: 
		SingletonObject.pop_up_new_tab.emit()


func _on_new_pressed():
	open_threads_popup()


func _on_btn_create_thread_pressed(tab_name: String, tab_ref: Control = null):
	#added a check for the tab name, if no name gives a default name
	
	if tab_name == "":
		tab_name = "notes " + str(%tcThreads.get_tab_count() + 1)
	
	if tab_ref:
		tab_ref.get_meta("thread").ThreadName = tab_name
		render_threads()
	else:
		create_new_notes_tab(tab_name)

## add indexing system here
var new_tab: bool = false
func create_new_notes_tab(tab_name: String = "notes 1"):
	var thread = MemoryThread.new()
	thread.ThreadName = tab_name_to_use(tab_name)
	var thread_memories: Array[MemoryItem] = []
	thread.MemoryItemList = thread_memories
	new_tab = true
	SingletonObject.ThreadList.append(thread)
	render_thread(thread)


func tab_name_to_use(proposed_name: String) -> String:
	var collisions = 0
	for i in range(tcThreads.get_tab_count()):
		if tcThreads.get_tab_title(i).split(" ")[0] == proposed_name:
			collisions+=1
	if collisions == 0:
		return proposed_name
	else:
		return proposed_name + "(" + str(tcThreads.get_tab_count() + 1) + ")"


func clear_all_tabs():
	var children = %tcThreads.get_children()
	for child in children:
		%tcThreads.remove_child(child)
	pass
	


#region Add notes methods

func add_note(user_title:String, user_content: String, _source: String = "") -> MemoryItem:
	# get the active thread.
	if (SingletonObject.ThreadList == null) or current_tab < 0:
		#SingletonObject.ErrorDisplay("Missing Thread", "Please create a new notes tab first, then try again.")
		#return
		create_new_notes_tab()
	
	var active_thread : MemoryThread = SingletonObject.ThreadList[current_tab]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.TEXT
	new_memory.ContentType = "text"
	new_memory.Title = user_title
	new_memory.Content = user_content
	new_memory.Visible = true
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)

	render_threads()

	return new_memory


func add_audio_note(note_title: String, note_audio: AudioStreamWAV) -> MemoryItem:
	if (SingletonObject.ThreadList == null) or current_tab < 1:
		#SingletonObject.ErrorDisplay("Missing Thread", "Please create a new notes tab first, then try again.")
		#return
		await create_new_notes_tab()
	
	var active_thread : MemoryThread = SingletonObject.ThreadList[self.current_tab]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.AUDIO
	new_memory.ContentType = "audio"
	new_memory.Title = note_title
	new_memory.Audio = note_audio
	new_memory.Visible = true
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()
	return new_memory


func add_image_note(note_title: String, note_image: Image, imageCaption: String = "") -> MemoryItem:
	if SingletonObject.ThreadList.is_empty():
		create_new_notes_tab()
	
	var active_thread : MemoryThread = SingletonObject.ThreadList[self.current_tab]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.IMAGE
	new_memory.ContentType = "image"
	new_memory.Title = note_title
	new_memory.MemoryImage = note_image
	new_memory.ImageCaption = imageCaption
	new_memory.Visible = true
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()
	return new_memory


## Creates a note without adding it to any thread.
func create_note(title: String, type: SingletonObject.note_type = SingletonObject.note_type.TEXT) -> MemoryItem:
	var new_memory: MemoryItem = MemoryItem.new()
	new_memory.Enabled = false
	new_memory.Type = type
	new_memory.Title = title
	new_memory.Visible = true

	return new_memory

#endregion Add notes methods

## Will delete the memory_item from the memory list
func delete_note(memory_item: MemoryItem):
	var active_thread : MemoryThread = SingletonObject.ThreadList[self.current_tab]

	var idx = active_thread.MemoryItemList.find(memory_item)
	if idx == -1: return
	
	active_thread.MemoryItemList.remove_at(idx)


func render_threads():
	# Save the last active thread.
	var last_thread = self.current_tab

	# we must delete existing noted so creating new project works
	for c in %tcThreads.get_children():
		c.queue_free()
	
	for thread in SingletonObject.ThreadList:
		render_thread(thread)

	# Restore the last active thread:
	await get_tree().process_frame # process frame is needed for wating untill all tabs are created
	if not new_tab:
		self.current_tab = clampi( last_thread, 0, self.get_child_count()-1)
	else:
		self.current_tab = get_tab_count() - 1
	new_tab = false

static var vboxMemoryList_scene: = preload("res://Scripts/UI/Controls/vboxMemoryList.gd")
func render_thread(thread_item: MemoryThread):
	# Create the ScrollContainer
	var scroll_container = ScrollContainer.new()
	scroll_container.scroll_vertical = 4060
	scroll_container.follow_focus = true
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Create a custom VBoxContainer derived class
	var vboxMemoryList = vboxMemoryList_scene.new(self, thread_item.ThreadId, thread_item.MemoryItemList)

	# Add VBoxContainer as a child of the ScrollContainer
	scroll_container.add_child(vboxMemoryList)
	#scroll_container.follow_focus = true
	
	# Get %tcThreads by its unique name and add the ScrollContainer as its new child (tab)
	#scroll_container.name = thread_item.ThreadName
	scroll_container.set_meta("thread", thread_item) # when the tab is deleted we need to know which thread item to delete
	%tcThreads.add_child(scroll_container)
	var tab_idx = %tcThreads.get_tab_idx_from_control(scroll_container)
	%tcThreads.set_tab_title(tab_idx, thread_item.ThreadName)
	if new_tab:
		self.current_tab = tab_idx




func _on_close_tab(tab: int, container: TabContainer):
	var control = container.get_tab_control(tab)
	
	# This is the thread index in the list, not it's id
	var thread_idx = SingletonObject.ThreadList.find(control.get_meta("thread"))
	if thread_idx != -1:
		# Remove the thread from the list
		SingletonObject.ThreadList.remove_at(thread_idx)

		# this will crash the program by freeing the `control` object
		# Update the UI with the remaining threads
		#render_threads()

		# Store deleted tab for potential undo
		SingletonObject.undo.store_deleted_tab_right(tab, control, "right")
	
	# Remove the tab control from the TabContainer
	container.remove_child(control) 
	
func restore_deleted_tab(tab_name: String):
	if tab_name in SingletonObject.undo.deleted_tabs:
		var data = SingletonObject.undo.deleted_tabs[tab_name]
		
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
# attach_file creates a memory item/note from a file.  It can detect file type
func attach_file(the_file: String):
	# Check if the file exists
	var file = FileAccess.open(the_file, FileAccess.READ)
	if file == null:
		SingletonObject.ErrorDisplay("File Error", "The file could not be opened.")
		return

	# Determine the file type
	var file_ext = the_file.get_extension().to_lower()
	@warning_ignore("unused_variable")
	var file_type = ""
	var content = ""
	var content_type = ""
	var type
	var title = the_file.get_file()
	
	# Get the active thread
	if (SingletonObject.ThreadList == null) or current_tab < 0:
		#SingletonObject.ErrorDisplay("Missing Thread", "Please create a new notes tab first, then try again.")
		#return
		create_new_notes_tab()
	var active_thread: MemoryThread = SingletonObject.ThreadList[self.current_tab]
	
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.File = the_file # associate the file with the new memory item
	
	if file_ext in SingletonObject.supported_text_formats:
		file_type = "text"
		content = file.get_as_text()
		content_type = "text/plain"
		type = SingletonObject.note_type.TEXT
	elif file_ext in SingletonObject.supported_image_formats:
		file_type = "image"
		type= SingletonObject.note_type.IMAGE
		var file_data = file.get_buffer(file.get_length())
		content = Marshalls.raw_to_base64(file_data)
		new_memory.MemoryImage = Image.load_from_file(the_file)
		content_type = "image/%s" % file_ext
	elif file_ext in SingletonObject.supported_video_formats:
		file_type = "video"
		type= SingletonObject.note_type.VIDEO
		#var file_data = file.get_buffer(file.get_length())
		#content = Marshalls.raw_to_base64(file_data)
		content = the_file
		content_type = "video/%s" % file_ext
	elif file_ext in SingletonObject.supported_audio_formats:
		file_type = "audio"
		type= SingletonObject.note_type.AUDIO
		var buffer = file.get_buffer(file.get_length())
		if file_ext == "mp3":
			var mp3AudioStream = AudioStreamMP3.new()
			mp3AudioStream.data = buffer
			new_memory.Audio = mp3AudioStream
		if file_ext == "wav":
			var wavAudioStream = AudioStreamWAV.new()
			wavAudioStream.data = buffer
			wavAudioStream.format = AudioStreamWAV.FORMAT_8_BITS
			new_memory.Audio = wavAudioStream
		if file_ext == "ogg":
			var oggAudioStream = AudioStreamOggVorbis.load_from_file(the_file)
			new_memory.Audio = oggAudioStream
		content = Marshalls.raw_to_base64(buffer)
		file_type = "audio"
		type= SingletonObject.note_type.AUDIO
		content_type = "audio/%s" % file_ext
	else:
		SingletonObject.ErrorDisplay("Unsupported File Type", "The file type is not supported.")
		return
	
	# Create a new memory item
	new_memory.Enabled = true
	new_memory.Title = title
	new_memory.Content = content
	new_memory.ContentType = content_type
	new_memory.Type = type
	new_memory.Visible = true
	new_memory.FilePath = the_file

	# Append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()

	file.close()
	pass


# Called when the node enters the scene tree for the first time.
func _ready():
	%tcThreads.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	%tcThreads.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(%tcThreads))

	# tab bar need mouse_filter set to pass to allow the tab container to catch drag event and call _can_drop_data
	get_tab_bar().mouse_filter = MOUSE_FILTER_PASS

	# Connect signals for changes in your data
	# SingletonObject.connect("ThreadListChanged", self._on_thread_list_changed) 

	SingletonObject.ThreadList = []
	SingletonObject.NotesTab = self
	SingletonObject.AttachNoteFile.connect(self.attach_file)
	SingletonObject.create_notes_tab.connect(_on_btn_create_thread_pressed)
	render_threads()


# if we are dragging a note above a tab, we can drop it there
func _can_drop_data(at_position: Vector2, data):
	var tab_idx = get_tab_idx_at_point(at_position)

	return tab_idx != -1 and data is Note

# find out which tab we are above
# and get it's vboxMemoryList control (which is the only child of the scroll container)
# then call it's _drop_data so it handles the Note by just appending it and removing it from the old thread
func _drop_data(at_position: Vector2, data):
	if not data is Note: return

	var tab_idx = get_tab_idx_at_point(at_position)

	var control = get_tab_control(tab_idx)

	var vbox_memory_list = control.get_child(0)

	vbox_memory_list._drop_data(at_position, data)
	current_tab = tab_idx
	
func _notification(what):
	match what:
		NOTIFICATION_DRAG_BEGIN: _drag_active = true
		NOTIFICATION_DRAG_END: _drag_active = false

#region Tab signal methods

var clicked: = -1 # this is used to tack double click to change the tab nama
var temp_current_tab: = -1 # this is used to track the clicked tab when rearranged
func _on_tab_clicked(tab: int):
	if clicked > -1:
		var tab_title = get_tab_bar().get_tab_title(tab)
		open_threads_popup(tab_title, tab)
		return
	clicked = tab
	temp_current_tab = tab
	get_tree().create_timer(0.4).timeout.connect(func(): clicked = -1)


func _on_active_tab_rearranged(idx_to: int) -> void:
	var temp_threadList = SingletonObject.ThreadList
	var chat_history_to_move: MemoryThread = SingletonObject.ThreadList[temp_current_tab]
	temp_threadList.pop_at(temp_current_tab)
	SingletonObject.ThreadList.insert(idx_to, chat_history_to_move)
	temp_current_tab = current_tab

#endregion Tab signal methods


# This function is called when the ThreadList is modified
func _on_thread_list_changed():
	_needs_update = true

# This function is called every frame
func _process(_delta):
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
