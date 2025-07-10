class_name DrawerTabs
extends TabContainer

@onready var tcThreadsDrawer = %tcThreadsDrawer
@onready var buffer_control_notes: Control = %BufferControlNotes


func To_Prompt(provider: BaseProvider) -> Array[Variant]:
	var output: Array[Variant] = []
	
	for this_thread:MemoryThread in SingletonObject.DrawerThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				output.append(provider.wrap_memory(item))
	
	# loop through detached notes also
	for item in SingletonObject.DetachedNotes:
		if item.Enabled:
			output.append(provider.wrap_memory(item))
	
	return output


func _ready():
	get_tab_bar().mouse_filter = MOUSE_FILTER_PASS
	get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	get_tab_bar().tab_clicked.connect(_on_drawer_tab_clicked)
	
	SingletonObject.DrawerTab = self
	
	SingletonObject.create_drawer_tab.connect(create_new_tab_helper)
	SingletonObject.deleted_drawer_note.connect(delete_drawer_note)
	render_threads()

#region Methods for toggling notes

func Disable_All():
	for this_thread:MemoryThread in SingletonObject.DrawerThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				item.Enabled = false
	
	for item:MemoryItem in SingletonObject.DetachedNotes:
		item.Enabled = false

	self.render_threads()


func enable_all():
	for this_thread:MemoryThread in SingletonObject.DrawerThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if !item.Enabled:
				item.Enabled = true
	
	for item:MemoryItem in SingletonObject.DetachedNotes:
		item.Enabled = true

	self.render_threads()


func enable_notes_in_tab():
	var currentNotesTab = SingletonObject.DrawerThreadList[current_tab]
	for item:MemoryItem in currentNotesTab:
		if !item.Enabled:
			item.Enabled = true


func disable_notes_in_tab():
	var currentNotesTab = SingletonObject.DrawerThreadList[current_tab]
	for item:MemoryItem in currentNotesTab:
		if item.Enabled:
			item.Enabled = false

## add indexing system here
var new_tab: bool = false


func clear_all_tabs():
	var children = %tcThreadsDrawer.get_children()
	for child in children:
		%tcThreadsDrawer.remove_child(child)
		child.queue_free()
	pass
	

func update_note_handler(item: MemoryItem, new_data: Variant) -> MemoryItem:
	if item.Type == SingletonObject.note_type.TEXT:
		item.Content = new_data as String
	elif item.Type == SingletonObject.note_type.IMAGE:
		item.MemoryImage = new_data as Image
	elif item.Type == SingletonObject.note_type.AUDIO:
		item.Audio = new_data as AudioStreamWAV
	render_threads()
	return item


func render_threads():
	# Save the last active thread.
	var last_thread = self.current_tab

	# we must delete existing noted so creating new project works
	for c in %tcThreadsDrawer.get_children():
		c.queue_free()
	
	for thread in SingletonObject.DrawerThreadList:
		render_thread(thread)

	# Restore the last active thread:
	await get_tree().process_frame # process frame is needed for wating untill all tabs are created
	if not new_tab:
		if get_tab_count() > 0:
			self.current_tab = clampi( last_thread, 0, self.get_child_count()-1)
	else:
		if get_tab_count() + 1 > 0:
			self.current_tab = get_tab_count() - 1
	new_tab = false

	SingletonObject.notes_draw_state_changed.emit(SingletonObject.NotesDrawState.UNSET)


static var vboxDrawerList_scene: = preload("res://Scripts/Drawer/VBoxDrawerList.gd")
func render_thread(thread_item: MemoryThread):
	# Create the ScrollContainer
	var scroll_container = ScrollContainer.new()
	scroll_container.scroll_vertical = 4060
	scroll_container.follow_focus = true
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Create a custom VBoxContainer derived class
	var vboxMemoryList = vboxDrawerList_scene.new(self, thread_item.ThreadId, thread_item.MemoryItemList, true)
	
	# Add VBoxContainer as a child of the ScrollContainer
	scroll_container.add_child(vboxMemoryList)
	#scroll_container.follow_focus = true
	
	# Get %tcThreadsDrawer by its unique name and add the ScrollContainer as its new child (tab)
	#scroll_container.name = thread_item.ThreadName
	scroll_container.set_meta("thread", thread_item) # when the tab is deleted we need to know which thread item to delete
	%tcThreadsDrawer.add_child(scroll_container)
	var tab_idx = %tcThreadsDrawer.get_tab_idx_from_control(scroll_container)
	%tcThreadsDrawer.set_tab_title(tab_idx, thread_item.ThreadName)
	if new_tab:
		self.current_tab = tab_idx


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


func tab_name_to_use(proposed_name: String) -> String:
	var collisions = 0
	var thread_to_use
	
	for i in range(get_tab_count()):
		if get_tab_title(i).split(" ")[0] == proposed_name:
			collisions+=1
	if collisions == 0:
		return proposed_name
	else:
		return proposed_name + "(" + str(get_tab_count() + 1) + ")"


func create_new_tab_helper(tab_name: String, tab_ref: Control = null) -> void:
	if tab_name == "":
		tab_name = "notes " + str(get_tab_count() + 1)
	
	if tab_ref:
		tab_ref.get_meta("thread").ThreadName = tab_name
		render_threads()
	else:
		create_new_tab(tab_name)


func create_new_tab(tab_name: String = "notes 1") -> void:
	var thread = MemoryThread.new()
	thread.ThreadName = tab_name_to_use(tab_name)
	var thread_memories: Array[MemoryItem] = []
	thread.MemoryItemList = thread_memories
	new_tab = true
	SingletonObject.DrawerThreadList.append(thread)
	SingletonObject.drawer_save_data.emit()
	render_threads()


func add_note(user_title:String, user_content: String) -> MemoryItem:
	var active_thread : MemoryThread 
	var current_tab_idx: int
	if SingletonObject.DrawerThreadList.is_empty():
		create_new_tab("Notes 1")
			
		current_tab_idx = current_tab
		if current_tab_idx < 0:  # If no tab is selected, use the first one
			current_tab_idx = 0
			
	active_thread = SingletonObject.DrawerThreadList[ current_tab]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.UUID = SingletonObject.generate_UUID()
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.TEXT
	new_memory.ContentType = "text"
	new_memory.Title = user_title
	new_memory.Content = user_content           
	new_memory.Visible = true
	new_memory.isCompleted = true
	new_memory.isDrawer = false
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()
	return new_memory


func add_audio_note(note_title: String, note_audio: AudioStreamWAV) -> MemoryItem:
	# get the active thread.
	var active_thread : MemoryThread 
	var current_tab_idx: int
	

	if SingletonObject.DrawerThreadList.is_empty():
		create_new_tab("Notes 1")
		
	current_tab_idx = current_tab
	if current_tab_idx < 0:  # If no tab is selected, use the first one
		current_tab_idx = 0
		
	active_thread = SingletonObject.DrawerThreadList[current_tab_idx]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.UUID = SingletonObject.generate_UUID()
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.AUDIO
	new_memory.ContentType = "audio"
	new_memory.Title = note_title
	new_memory.Audio = note_audio
	new_memory.Visible = true
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()
	current_tab = current_tab_idx
	%ProjectManagement.drawer_save_data.emit()
	
	return new_memory


func add_image_note(note_title: String, note_image: Image, imageCaption: String = "", isDrawer:bool = false) -> MemoryItem:
	# get the active thread.
	var active_thread : MemoryThread 
	var current_tab_idx: int
	
	if SingletonObject.DrawerThreadList.is_empty():
		create_new_tab("Notes 1")
		
	current_tab_idx = tcThreadsDrawer.current_tab
	if current_tab_idx < 0:  # If no tab is selected, use the first one
		current_tab_idx = 0
		
	active_thread = SingletonObject.DrawerThreadList[current_tab_idx]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.UUID = SingletonObject.generate_UUID()
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
	# Explicitly set the current tab after rendering
	tcThreadsDrawer.current_tab = current_tab_idx
	%ProjectManagement.drawer_save_data.emit()
	return new_memory

func delete_drawer_note(memory_item_UUID: String) -> void:
	var active_thread : MemoryThread = SingletonObject.DrawerThreadList[self.current_tab]
	
	for i in active_thread.MemoryItemList:
		if i.UUID == memory_item_UUID:
			active_thread.MemoryItemList.erase(i)
			break
	
	SingletonObject.drawer_save_data.emit()


#region Tab signal methods

var _clicked_tab: int = -1
var _click_counter: int = 0
func _on_tab_clicked(tab: int):
	
	if _clicked_tab > -1 and _click_counter >= 1:
		var tab_title = get_tab_bar().get_tab_title(tab)
		open_threads_popup(tab_title, tab)
		_click_counter = -1
		return
	_clicked_tab = tab
	_click_counter += 1
	get_tree().create_timer(0.2).timeout.connect(reset_tab_values)


func reset_tab_values() -> void:
	_clicked_tab = -1
	_click_counter = 0


func _on_drawer_tab_clicked(tab: int): 
	_on_tab_clicked(tab)

func _on_active_tab_rearranged(idx_to: int) -> void:
	var chat_history_to_move: MemoryThread = SingletonObject.DrawerThreadList[_clicked_tab]
	SingletonObject.DrawerThreadList.pop_at(_clicked_tab)
	SingletonObject.DrawerThreadList.insert(idx_to, chat_history_to_move)
	_clicked_tab = current_tab
	SingletonObject.drawer_save_data.emit()
	render_threads()


func open_threads_popup(tab_name: String = "", tab = null):
	var update = tab != null
	# set metadata so we can determine should we create new or update existing and which tab, when we click the button in the popup
	if update:
		SingletonObject.associated_notes_tab.emit(tab_name, get_child(tab))
	else: 
		SingletonObject.pop_up_new_tab.emit()
