## ThreadView.gd
# This script manages a tab container that groups memory objects.
class_name MemoryTabs
extends TabContainer

# just use current_tab
# var ActiveThreadIndex: int:

var _drag_active := false

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


func open_threads_popup(name: String = "", tab = null):
	var target_size = %VBoxRoot.size - Vector2(100, 100)
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

	

	if %NewThreadPopup.has_meta("associated_tab"):
		var at = %NewThreadPopup.get_meta("associated_tab")
		at.get_meta("thread").ThreadName = tab_name
		render_threads()
	else:
		var thread = MemoryThread.new()
		thread.ThreadName = tab_name
		var thread_memories: Array[MemoryItem] = []
		thread.MemoryItemList = thread_memories
		SingletonObject.ThreadList.append(thread)
		render_thread(thread)
	
	%NewThreadPopup.hide()

func clear_all_tabs():
	var children = %tcThreads.get_children()
	for child in children:
		%tcThreads.remove_child(child)
	pass
	

func render_threads():
	# save the last active thread.
	var last_thread = self.current_tab

	# Clear all children of tcThreads
	self.clear_all_tabs()

	# render each thread
	for this_thread in SingletonObject.ThreadList:
		render_thread(this_thread)

	if self.get_child_count():
		self.current_tab = clampi(last_thread, 0, self.get_child_count()-1)
	


func add_note(user_title:String, user_content: String, _source: String = ""):
	# get the active thread.
	if (SingletonObject.ThreadList == null) or (len(SingletonObject.ThreadList) - 1) <  self.current_tab:
		SingletonObject.ErrorDisplay("Missing Thread", "Please create a new notes tab first, then try again.")
		return
	var active_thread : MemoryThread = SingletonObject.ThreadList[self.current_tab]

	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.Enabled = true
	new_memory.Title = user_title
	new_memory.Content = user_content
	new_memory.Visible = true

	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	render_threads()
	pass

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
	
	# this is the thread index in the list, not it's id
	var thread_idx = SingletonObject.ThreadList.find(control.get_meta("thread"))
	if thread_idx != -1:
		SingletonObject.ThreadList.remove_at(thread_idx)
		render_threads()
	
	# container.remove_child(control)

	


# Called when the node enters the scene tree for the first time.
func _ready():
	%tcThreads.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	%tcThreads.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(%tcThreads))

	SingletonObject.ThreadList = []
	SingletonObject.NotesTab = self
	render_threads()


func _notification(what):
	match what:
		NOTIFICATION_DRAG_BEGIN: _drag_active = true
		NOTIFICATION_DRAG_END: _drag_active = false


var clicked:= false
func _on_tab_clicked(tab: int):
	
	if clicked:
		var tab_title = get_tab_bar().get_tab_title(tab)
		open_threads_popup(tab_title, tab)

	clicked = true
	get_tree().create_timer(0.4).timeout.connect(func(): clicked = false)


func _on_tab_hovered(tab: int):
	if _drag_active:
		current_tab = tab
