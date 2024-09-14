### Reference Information ###
### Title: EditorPane
## This is for a tabbed editor in the middle pane of the main work chat view.
class_name EditorPane
extends Control



enum LAYOUT {HORIZONTAL, VERTICAL}

static var _unsaved_changes_icon: = preload("res://assets/icons/slider_grabber.svg")

var current_layout: LAYOUT

@onready var Tabs: TabContainer = $"./VBoxContainer/HBoxContainer/LeftControl/TabContainer"

@onready var LeftControl: Control = $"./VBoxContainer/HBoxContainer/LeftControl"
@onready var RightControl: Control = $"VBoxContainer/HBoxContainer/RightControl"
@onready var BottomControl: Control = $"VBoxContainer/BottomControl"



func _ready():
	self.Tabs.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	self.Tabs.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(self.Tabs))
	SingletonObject.UpdateUnsavedTabIcon.connect(update_tabs_icon)
	

func _save_current_tab():
	if Tabs.get_tab_count() == 0: return

	var editor: Editor = Tabs.get_tab_control(Tabs.current_tab)

	editor.save()

func _close_current_tab():
	if Tabs.get_tab_count() == 0: return

	Tabs.get_tab_bar().tab_close_pressed.emit(Tabs.current_tab)

func _shortcut_input(event: InputEvent):
	
	if event.is_action_pressed("save"):
		_save_current_tab()
		get_viewport().set_input_as_handled()
	
	elif event.is_action_pressed("close"):
		_close_current_tab()
		get_viewport().set_input_as_handled()

	
func _on_close_tab(tab: int, container: TabContainer):
	if Editor.Type.WhiteBoard:
		GraphicsEditor.layer_Number = 0
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

func _input(_event):
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

	# scrollable.add_child(item)
	#item.name = name_
	self.Tabs.call_deferred("add_child")#add_child(item)
	self.Tabs.current_tab = self.Tabs.get_tab_count()-1
	enable_editor_action_buttons.emit(true)
	return item



func add(type: Editor.Type, file = null, name_ = null, associated_object = null) -> Editor:
	#Add a scroll container to the tabs and put the item in there.

	# check if we're opening a file that's already open or for the same associated_object (except null)
	# if so just switch to that editor
	for editor: Editor in self.Tabs.get_children():
		if not editor is Editor: 
			continue
		if editor.file == file or (associated_object != null and editor.associated_object == associated_object):
			Tabs.current_tab = Tabs.get_tab_idx_from_control(editor)
			return editor
	
	var editor_node = Editor.create(type, file, name_, associated_object)
	
	editor_node.content_changed.connect(_on_editor_content_changed.bind(editor_node))
	
	self.Tabs.add_child(editor_node)
	self.Tabs.current_tab = self.Tabs.get_tab_count()-1
	
	if name_: 
		var tab_name = editor_name_to_use(name_)
		Tabs.set_tab_title(Tabs.current_tab, tab_name)
		editor_node.tab_title = tab_name
	elif file:
		var tab_name = editor_name_to_use(file.get_file())
		Tabs.set_tab_title(Tabs.current_tab, tab_name)
		editor_node.tab_title = tab_name
	else:
		match type:
			Editor.Type.TEXT:
				var tab_name = "tab " + str(Tabs.get_tab_count() )
				Tabs.set_tab_title(Tabs.current_tab, tab_name)
				editor_node.tab_title = tab_name
				
			Editor.Type.GRAPHICS:
				var tab_name = "graphics " + str(Tabs.get_tab_count() )
				Tabs.set_tab_title(Tabs.current_tab, tab_name)
				editor_node.tab_title = tab_name
	
	return editor_node

func open_editors() -> Array[Editor]:
	var editors: Array[Editor] = []
	for child in self.Tabs.get_children():
		if not child is Editor: continue
		editors.append(child)
	
	return editors


func editor_name_to_use(proposed_name: String) -> String:
	var collisions = 0
	for i in range(Tabs.get_tab_count()):
		if Tabs.get_tab_title(i).split(" ")[0] == proposed_name:
			collisions+=1
	if collisions == 0:
		return proposed_name
	else:
		return proposed_name + "(" + str(Tabs.get_tab_count() + 1) + ")"


func unsaved_editors() -> Array[Editor]:
	var editors: Array[Editor] = []
	for child in self.Tabs.get_children():
		if not child is Editor: continue
		
		if not child.is_content_saved():
			editors.append(child)
	
	return editors


func _copy_children_to(from: Node, to: Node):
	for child in from.get_children():
		var dup = child.duplicate(DUPLICATE_USE_INSTANTIATION)
		
		if dup is TabContainer:
			if not dup.get_child_count(): dup.current_tab = -1
			dup.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
			dup.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(dup))
		
		to.call_deferred("add_child", dup)#.add_child(dup)

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


func update_tabs_icon() -> void:
	var tab_count: = Tabs.get_tab_count()
	var counter:= 0
	while counter < tab_count:
		var editor = Tabs.get_tab_control(counter)
		if not editor.is_content_saved():
			Tabs.set_tab_icon(counter, _unsaved_changes_icon)
		else:
			Tabs.set_tab_icon(counter, null)
		
		counter += 1


func _on_editor_content_changed(editor: Editor):
	var tab_idx: = Tabs.get_tab_idx_from_control(editor)
	if not editor.is_content_saved():
		Tabs.set_tab_icon(tab_idx, _unsaved_changes_icon)
	else:
		Tabs.set_tab_icon(tab_idx, null)

#region  Enable Editor Buttons
signal enable_editor_action_buttons(enable)

func _on_tab_container_tab_selected(_tab: int) -> void:
	var current_control = Tabs.get_current_tab_control()
	if not current_control:
		return
	if current_control is Editor and current_control.type == Editor.Type.TEXT:
		enable_editor_action_buttons.emit(true)
		current_control.code_edit.grab_focus()
	else: 
		enable_editor_action_buttons.emit(false)


func _on_tab_container_child_exiting_tree(_node: Node) -> void:
	var current_tab = Tabs.get_current_tab_control()
	if current_tab == null:
		return
	if Tabs.get_tab_count() < 1:
		enable_editor_action_buttons.emit(false)
		return
	if current_tab.get_class() == "ScrollContainer":
		enable_editor_action_buttons.emit(true)
		return
	elif current_tab.type == Editor.Type.TEXT:
		enable_editor_action_buttons.emit(true)
	else: 
		enable_editor_action_buttons.emit(false)


func _on_tab_container_tree_exited() -> void:
	enable_editor_action_buttons.emit(false)


func _on_tab_container_tab_changed(_tab: int) -> void:
	var current_tab = Tabs.get_current_tab_control()
	if Tabs == null or current_tab == null:
		return
	if Tabs.get_tab_count() < 1:
		enable_editor_action_buttons.emit(false)
	if current_tab.get_class() == "ScrollContainer":
		enable_editor_action_buttons.emit(true)
		return
	elif current_tab.type == Editor.Type.TEXT:
		enable_editor_action_buttons.emit(true)
	else: 
		enable_editor_action_buttons.emit(false)

###
### End Reference Information ###
