class_name DrawerTabs
extends BaseTabContainer

@onready var tcThreadsDrawer = %tcThreadsDrawer
static var vboxDrawerList_scene: = preload("res://Scripts/Drawer/VBoxDrawerList.gd")

## add indexing system here
var new_tab: bool = false

# Override abstract methods
func get_thread_list() -> Array[MemoryThread]:
	return SingletonObject.DrawerThreadList

func get_tab_container() -> TabContainer:
	return tcThreadsDrawer

func get_vbox_scene():
	return vboxDrawerList_scene

func save_data_if_needed():
	print("save_data_if_needed")
	SingletonObject.drawer_save_data.emit()

func create_vbox_memory_list(thread: MemoryThread):
	return vboxDrawerList_scene.new(self, thread, true)

func add_note(user_title: String, user_content: String, is_completed: bool = true, _source: String = "") -> MemoryItem:
	var new_memory = super(user_title, user_content, is_completed, _source)
	new_memory.isDrawer = true
	return new_memory

func delete_drawer_note(memory_item_UUID: String) -> void:	
	var active_thread: MemoryThread = get_thread_list()[self.current_tab]
	
	for i in active_thread.MemoryItemList:
		if i.UUID == memory_item_UUID:
			print("Found item to delete: ", i.Title)
			active_thread.MemoryItemList.erase(i)
			break
	
	print("Items after delete: ", active_thread.MemoryItemList.size())

func _ready():
	super()
	get_tab_bar().mouse_filter = MOUSE_FILTER_PASS
	get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	get_tab_bar().tab_clicked.connect(_on_drawer_tab_clicked)
	get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(self))
	# tcThreadsDrawer.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(tcThreadsDrawer))
	
	SingletonObject.DrawerTab = self
	print("evo ga")
	prints(SingletonObject.DrawerTab, self)
	
	SingletonObject.create_drawer_tab.connect(_on_btn_create_thread_pressed)
	SingletonObject.deleted_drawer_note.connect(delete_drawer_note)
	# Don't call render_threads() - tabs will be created as needed

#region Tab signal methods

var _clicked_tab: int = -1
var _click_counter: int = 0

func _on_drawer_tab_clicked(tab: int): 
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

func _on_active_tab_rearranged(idx_to: int) -> void:
	var chat_history_to_move: MemoryThread = get_thread_list()[_clicked_tab]
	get_thread_list().pop_at(_clicked_tab)
	get_thread_list().insert(idx_to, chat_history_to_move)
	_clicked_tab = current_tab
	save_data_if_needed()
	# Don't call render_threads() - not needed with new approach

#endregion Tab signal methods
