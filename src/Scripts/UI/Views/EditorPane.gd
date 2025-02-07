### Reference Information ###
### Title: EditorPane
## This is for a tabbed editor in the middle pane of the main work chat view.
class_name EditorPane
extends Control



enum LAYOUT {HORIZONTAL, VERTICAL}

static var _unsaved_changes_icon: = preload("res://assets/icons/slider_grabber.svg")
static var _unsaved_changes_file_icon: = preload("res://assets/icons/half_circle_left.svg")
static var _unsaved_changes_associated_icon: = preload("res://assets/icons/half_circle_right.svg")
static var _incoplete_snippet_icon: = preload("res://assets/icons/warning_circle.svg")
var _is_Completed = true
var current_layout: LAYOUT

@onready var Tabs: TabContainer = $"./VBoxContainer/HBoxContainer/LeftControl/TabContainer"

@onready var LeftControl: Control = $"./VBoxContainer/HBoxContainer/LeftControl"
@onready var RightControl: Control = $"VBoxContainer/HBoxContainer/RightControl"
@onready var BottomControl: Control = $"VBoxContainer/BottomControl"

@onready var _toggle_all_button: Button = %ToggleAllButton

var counter_for_remove

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
	for editor: Editor in Tabs.get_children():
		if not editor is Editor: 
			continue
		if editor.file == file or (associated_object != null and editor.associated_object == associated_object):
			Tabs.current_tab = Tabs.get_tab_idx_from_control(editor)
			return editor
	
	var editor_node = Editor.create(type, file, name_, associated_object)
	
	editor_node.content_changed.connect(_on_editor_content_changed.bind(editor_node))
	
	Tabs.add_child(editor_node)
	Tabs.current_tab = Tabs.get_tab_count()-1
	
	if name_: 
		var tab_name = editor_name_to_use(name_)
		Tabs.set_tab_title(Tabs.current_tab, tab_name)
		editor_node.tab_title = tab_name
	elif file:
		var tab_name: String
		if !is_named_being_used(file.get_file()):
			tab_name = editor_name_to_use(file.get_file())
		else:
			var dir: String = file.get_base_dir().split("/")[file.get_base_dir().split("/").size() -1]
			tab_name = dir + "/" + file.get_file()

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


func is_named_being_used(proposed_name: String) -> bool:
	for i in range(Tabs.get_tab_count()):
		if Tabs.get_tab_title(i) == proposed_name:
			print("tab name baing used already")
			return true
	return false

func editor_name_to_use(proposed_name: String) -> String:
	var collisions = 0
	for i in range(Tabs.get_tab_count()):
		if Tabs.get_tab_title(i).split(" (")[0] == proposed_name:
			collisions+=1
	if collisions == 0:
		return proposed_name
	else:
		return proposed_name + " (" + str(collisions) + ")"


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
	counter_for_remove = counter
	while counter < tab_count:
		var editor = Tabs.get_tab_control(counter)
		_on_editor_content_changed(editor) # call the below implementation to update the icon

		# if not editor.is_content_saved():
		# 	Tabs.set_tab_icon(counter, _unsaved_changes_icon)
		# else:
		# 	Tabs.set_tab_icon(counter, null)
		
		counter += 1

func check_incomplete_snippet(editor: Editor, old_text: String, new_text: String):

	if editor.type != Editor.Type.TEXT:
		return

	var tab_idx = Tabs.get_tab_idx_from_control(editor)
	if tab_idx == -1: # Handle case where editor isn't in the tab container
		return

	# Nodes for visual feedback (make sure these exist in your scene)

	var smaller_and_incomplete_node = Tabs.get_child(tab_idx).find_child("TextIsSmalleAndIncoplete")
	var text_is_smaller_node = Tabs.get_child(tab_idx).find_child("TextIsSmaller")
	var text_is_incomplete_node = Tabs.get_child(tab_idx).find_child("TextIsIncoplete")

	var old_size := old_text.length()
	var new_size := new_text.length()

	var isSmaller: bool = new_size < old_size
	var isIncoplete: bool = false

	if !SingletonObject.Is_code_completed:
		isIncoplete = true

	# Mutually exclusive visibility logic:
	if isSmaller and isIncoplete:
		smaller_and_incomplete_node.visible = isIncoplete
		text_is_smaller_node.visible = false
		text_is_incomplete_node.visible = false
	else:
		smaller_and_incomplete_node.visible = false
		text_is_smaller_node.visible = isSmaller
		text_is_incomplete_node.visible = isIncoplete

	# Update the old_text meta for future comparisons
	editor.code_edit.set_meta("old_text", new_text)
	SingletonObject.Is_code_completed = true
	
func _on_editor_content_changed(editor: Editor):

	var state: = editor.get_saved_state()
	var icon: Texture2D
	var tooltip: String = ""

	var associated_object_name: String

	if editor.associated_object:
		associated_object_name = str(editor.associated_object)

	match state & (Editor.FILE_SAVED | Editor.ASSOCIATED_OBJECT_SAVED):
		Editor.FILE_SAVED:
			# the file is saved, check if we have an associated object that's not marked as saved
			if editor.associated_object:
				icon = _unsaved_changes_associated_icon
				tooltip = "File saved, \"%s\" unsaved" % associated_object_name
			# else we just have a file that's saved
			else:
				icon = null
				tooltip = "File saved"

		Editor.ASSOCIATED_OBJECT_SAVED:
			# the associated_object is saved, but not the file
			
			icon = _unsaved_changes_file_icon
			if editor.file:
				tooltip = "File unsaved, \"%s\" saved" % associated_object_name
			# else we just have an associated object that's saved
			else:
				tooltip = "No File, Note saved"

		# both are saved
		Editor.FILE_SAVED | Editor.ASSOCIATED_OBJECT_SAVED:
			icon = null
			tooltip = "File and \"%s\" saved" % associated_object_name

		0: # nothing is saved in this case
			icon = _unsaved_changes_icon
			if editor.file and editor.associated_object:
				tooltip = "File and \"%s\" unsaved" % associated_object_name
			else:
				if editor.file:
					tooltip = "File unsaved"
				elif editor.associated_object:
					tooltip = "\"%s\" unsaved" % associated_object_name
				else:
					tooltip = "Content unsaved"
	

	var tab_idx: = Tabs.get_tab_idx_from_control(editor)
	Tabs.set_tab_icon(tab_idx, icon)
	Tabs.set_tab_tooltip(tab_idx, tooltip)
	

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

#endregion  Enable Editor Buttons
###
### End Reference Information ###


var _last_state: = false

func _on_toggle_all_button_pressed() -> void:
	_last_state = not _last_state
	
	for editor in open_editors():
		editor.toggle(_last_state)
	
	if _last_state:
		_toggle_all_button.text = "Disable All"
	else:
		_toggle_all_button.text = "Enable All"

func _close_error():
	var tab_idx = Tabs.get_tab_idx_from_control(Tabs.get_tab_control(counter_for_remove))
