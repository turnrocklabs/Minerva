class_name DrawerTabs
extends TabContainer

@onready var tcThreadsDrawer = %tcThreadsDrawer
# just use current_tab
# var ActiveThreadIndex: int:
@onready var buffer_control_notes: Control = %BufferControlNotes
var _drag_active := true
# var _hovered_tab := -1
# var _hover_timer

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
	
	# Get %tcThreadsDrawer by its unique name and add the ScrollContainer as its new child (tab)
	#scroll_container.name = thread_item.ThreadName
	scroll_container.set_meta("thread", thread_item) # when the tab is deleted we need to know which thread item to delete
	%tcThreadsDrawer.add_child(scroll_container)
	var tab_idx = %tcThreadsDrawer.get_tab_idx_from_control(scroll_container)
	%tcThreadsDrawer.set_tab_title(tab_idx, thread_item.ThreadName)
	if new_tab:
		self.current_tab = tab_idx



func _ready():
	get_tab_bar().mouse_filter = MOUSE_FILTER_PASS


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
