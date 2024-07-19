## This is for a tabbed editor in the middle pane of the main work chat view.
class_name EditorPane
extends Control

enum LAYOUT {HORIZONTAL, VERTICAL}

var current_layout: LAYOUT

@onready var Tabs: TabContainer = $"./VBoxContainer/HBoxContainer/LeftControl/TabContainer"

@onready var LeftControl: Control = $"./VBoxContainer/HBoxContainer/LeftControl"
@onready var RightControl: Control = $"VBoxContainer/HBoxContainer/RightControl"
@onready var BottomControl: Control = $"VBoxContainer/BottomControl"


func _ready():
	self.Tabs.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	self.Tabs.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(self.Tabs))


func _on_close_tab(tab: int, container: TabContainer):
	var control = container.get_tab_control(tab)
	if control is Editor:
		if not control.is_content_saved():
			var should_close = await control.prompt_close()
			
			if should_close:
				container.remove_child(control)
				SingletonObject.undo.store_deleted_tab_mid(tab,control,"middle")
		else:
			container.remove_child(control)
			SingletonObject.undo.store_deleted_tab_mid(tab,control,"middle")
	else:
		container.remove_child(control)
		SingletonObject.undo.store_deleted_tab_mid(tab,control,"middle")

func restore_deleted_tab(tab_name: String):
	if tab_name in SingletonObject.undo.deleted_tabs:
		var data = SingletonObject.undo.deleted_tabs[tab_name]
		var tab = data["tab"]
		var control = data["control"]
		data["timer"].stop()
		# Add the control back to the TabContainer
		self.Tabs.add_child(control)
		self.Tabs.current_tab = tab

		# Remove the data from the deleted_tabs dictionary
		SingletonObject.undo.deleted_tabs.erase(tab_name)

func _process(delta):
	if Tabs.get_tab_count() > 0:
		pass
	if Input.is_action_just_pressed("ui_undo"):
		if not SingletonObject.undo.deleted_tabs.is_empty():
			# Get the name of the last deleted tab
			var last_deleted_tab = SingletonObject.undo.deleted_tabs.keys().back()
			if last_deleted_tab and SingletonObject.undo.deleted_tabs[last_deleted_tab]["WhichWindow"] == "middle":
				restore_deleted_tab(last_deleted_tab)
			elif last_deleted_tab and SingletonObject.undo.deleted_tabs[last_deleted_tab]["WhichWindow"] == "left":
				SingletonObject.Chats.restore_deleted_tab(last_deleted_tab)
			elif last_deleted_tab and SingletonObject.undo.deleted_tabs[last_deleted_tab]["WhichWindow"] == "right":
				SingletonObject.NotesTab.restore_deleted_tab(last_deleted_tab)
			
func add_control(item: Node, name_: String) -> Node:
	var scrollable = ScrollContainer.new()
	scrollable.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrollable.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scrollable.name = name_
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.size_flags_vertical = Control.SIZE_EXPAND_FILL

	scrollable.add_child(item)

	self.Tabs.add_child(scrollable)
	self.Tabs.current_tab = self.Tabs.get_tab_count()-1

	return scrollable



func add(type: Editor.TYPE, file = null, name_ = null) -> Editor:
	#Add a scroll container to the tabs and put the item in there.

	var editor_node = Editor.create(type, file)
	
	if name_: 
		editor_node.name = name_
	elif file:
		editor_node.name = get_file_name(file)
	else:
		match type:
			Editor.TYPE.Text:
				editor_node.name = "tab " + str(Tabs.get_tab_count() + 1)
			Editor.TYPE.Graphics:
				editor_node.name = "Graphics " + str(Tabs.get_tab_count() + 1)
			Editor.TYPE.WhiteBoard:
				editor_node.name = "drawing " + str(Tabs.get_tab_count() + 1)
	
	self.Tabs.add_child(editor_node)
	self.Tabs.current_tab = self.Tabs.get_tab_count()-1
	
	return editor_node


func get_file_name(path: String) -> String:
	if path.length() <= 1:
		return path
	var split_path = path.split("/")
	return split_path[split_path.size() -1].split(".")[0]


func unsaved_editors() -> Array[Editor]:
	var editors: Array[Editor] = []
	for child in self.Tabs.get_children():
		if not child is Editor: continue
		
		if not child.is_content_saved():
			editors.append(child)
	
	return editors


func _copy_children_to(from: Node, to: Node):
	for child in from.get_children(true):
		var dup = child.duplicate(DUPLICATE_USE_INSTANTIATION)
		
		if dup is TabContainer:
			if not dup.get_child_count(): dup.current_tab = -1
			dup.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
			dup.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(dup))
		
		to.add_child(dup)

func toggle_horizontal_split() -> void:
	BottomControl.visible = false

	for c in RightControl.get_children(): RightControl.remove_child(c)
	_copy_children_to(LeftControl, RightControl)

	RightControl.visible = not RightControl.visible

func toggle_vertical_split() -> void:
	RightControl.visible = false

	for c in BottomControl.get_children(): BottomControl.remove_child(c)
	_copy_children_to(LeftControl, BottomControl)

	BottomControl.visible = not BottomControl.visible




#region  Enable Editor Buttons
signal enable_editor_action_buttons(enable)

func _on_tab_container_tab_selected(tab: int) -> void:
	var current_tab = Tabs.get_current_tab_control()
	if current_tab == null:
		return
	if current_tab.get_class() == "ScrollContainer":
		enable_editor_action_buttons.emit(true)
		return
	elif current_tab.type == Editor.TYPE.Text:
		enable_editor_action_buttons.emit(true)
	else: 
		enable_editor_action_buttons.emit(false)

#endregion  Enable Editor Buttons

func _on_tab_container_child_exiting_tree(node: Node) -> void:
	var current_tab = Tabs.get_current_tab_control()
	if current_tab == null:
		return
	if Tabs.get_tab_count() < 1:
		enable_editor_action_buttons.emit(false)
		return
	if current_tab.get_class() == "ScrollContainer":
		enable_editor_action_buttons.emit(true)
		return
	elif current_tab.type == Editor.TYPE.Text:
		enable_editor_action_buttons.emit(true)
	else: 
		enable_editor_action_buttons.emit(false)


func _on_tab_container_tree_exited() -> void:
	enable_editor_action_buttons.emit(false)


func _on_tab_container_tab_changed(tab: int) -> void:
	var current_tab = Tabs.get_current_tab_control()
	if Tabs == null:
		return
	if Tabs.get_tab_count() < 1:
		enable_editor_action_buttons.emit(false)
	if current_tab.get_class() == "ScrollContainer":
		enable_editor_action_buttons.emit(true)
		return
	elif current_tab.type == Editor.TYPE.Text:
		enable_editor_action_buttons.emit(true)
	else: 
		enable_editor_action_buttons.emit(false)

