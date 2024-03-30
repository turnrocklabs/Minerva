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
	self.Tabs.get_tab_bar().tab_close_pressed.connect(_on_close_tab)


func _on_close_tab(tab: int):
	var control = self.Tabs.get_tab_control(tab)
	self.Tabs.remove_child(control)


func add(item:Control, _name:String):
	#Add a scroll container to the tabs and put the item in there.

	var scrollable = ScrollContainer.new()
	scrollable.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrollable.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scrollable.name = _name
	
	scrollable.add_child(item)

	self.Tabs.add_child(scrollable)


# Create a new viewer/editor depending on type 
func new_tab(item:ChatHistoryItem):
	## define what we create by item type
	var new_item
	if item.Type == ChatHistoryItem.PartType.TEXT:
		new_item = CodeEdit.new()
	
	if item.Type == ChatHistoryItem.PartType.CODE:
		new_item = CodeEdit.new()
	
	if item.Type == ChatHistoryItem.PartType.JPEG:
		new_item = TextureRect.new()


	pass

func _copy_children_to(from: Node, to: Node):
	for child in from.get_children(true):
		to.add_child(child.duplicate(DUPLICATE_SCRIPTS))

func toggle_horizontal_split() -> void:
	BottomControl.visible = false

	_copy_children_to(LeftControl, RightControl)

	RightControl.visible = not RightControl.visible

func toggle_vertical_split() -> void:
	RightControl.visible = false

	_copy_children_to(LeftControl, BottomControl)

	BottomControl.visible = not BottomControl.visible
