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
	container.remove_child(control)


func add(item:Control, _name:String) -> Node:
	#Add a scroll container to the tabs and put the item in there.

	var scrollable = ScrollContainer.new()
	scrollable.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrollable.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scrollable.name = _name
	
	scrollable.add_child(item)

	self.Tabs.add_child(scrollable)
	self.Tabs.current_tab = self.Tabs.get_tab_count()-1

	return scrollable


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
