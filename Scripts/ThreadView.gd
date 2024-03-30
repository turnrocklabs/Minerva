## ThreadView.gd
# This script manages a tab container that groups memory objects.

extends TabContainer

var ThreadList: Array[MemoryThread]
var ActiveThreadIndex: int

## return a single large string of all active memories
func To_Prompt() -> String:
	var have_information: bool = false
	var output: String = ""
	for this_thread:MemoryThread in ThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				have_information = true
				output += "### {%s}" % item.Title + '\n'
				output += item.Content + '\n'
				output += "###" + '\n'
	if have_information:
		output = "Information in Memory\n" + output
	return output

func Disable_All():
	for this_thread:MemoryThread in ThreadList:
		for item:MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				item.Enabled = false
	self.render_threads()
	pass

## during development, we'll add a dummy thread and working memory list.
func create_dummy_thread():
	## da thread.
	var thread = MemoryThread.new()
	thread.ThreadName = "Hello"

	# a single memory
	var memory: MemoryItem = MemoryItem.new(thread.ThreadId)
	memory.Title = "Hello world"
	memory.Content = "I like cats"
	memory.Enabled = true


	# da dummy working memories
	var thread_memories: Array[MemoryItem] = []
	thread_memories.append(memory)
	thread.MemoryItemList = thread_memories

	self.ThreadList.append(thread)
	self.ActiveThreadIndex = 0
	pass

func _on_new_pressed():
	var target_size = %VBoxRoot.size - Vector2(100, 100)
	%NewThreadPopup.borderless = false
	%NewThreadPopup.size = target_size
	%NewThreadPopup.popup_centered()
	pass

func _on_btn_create_thread_pressed():
	var tab_name:String = %txtNewTabName.text
	var thread = MemoryThread.new()
	thread.ThreadName = tab_name
	var thread_memories: Array[MemoryItem] = []
	thread.MemoryItemList = thread_memories
	self.ThreadList.append(thread)
	render_thread(thread)
	%NewThreadPopup.hide()
	pass # Replace with function body.

func _on_tab_changed(tab_index):
	self.ActiveThreadIndex = tab_index

func clear_all_tabs():
	var children = %tcThreads.get_children()
	for child in children:
		%tcThreads.remove_child(child)
	pass
	

func render_threads():
	# save the last active thread.
	var last_thread = self.ActiveThreadIndex

	# Clear all children of tcThreads
	self.clear_all_tabs()

	# render each thread
	for this_thread in ThreadList:
		render_thread(this_thread)

	# set the active thread in UI
	self.current_tab = last_thread
	self.ActiveThreadIndex = last_thread
	pass

func _on_memorize_pressed():
	# get the title and content from the user
	var user_title:String = %txtMemoryTitle.text
	var user_content:String = %txtMainUserInput.text

	# get the active thread.
	var active_thread : MemoryThread = self.ThreadList[ActiveThreadIndex]

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

func render_thread(thread_item: MemoryThread):
	# Create the ScrollContainer
	var scroll_container = ScrollContainer.new()
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Create a custom VBoxContainer derived class
	var vboxMemoryList = preload("res://Scripts/Views/vboxMemoryList.gd").new(self, thread_item.ThreadId, thread_item.MemoryItemList)

	# Add VBoxContainer as a child of the ScrollContainer
	scroll_container.add_child(vboxMemoryList)

	# Get %tcThreads by its unique name and add the ScrollContainer as its new child (tab)
	var foo: String = thread_item.ThreadName
	scroll_container.name = foo  # Set the tab title
	%tcThreads.add_child(scroll_container)
	pass

# Called when the node enters the scene tree for the first time.
func _ready():
	self.ThreadList = []
	create_dummy_thread()
	render_threads()
	self.connect("tab_changed", self._on_tab_changed)
	pass


