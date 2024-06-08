extends HBoxContainer


@onready var chat_pane = %LeftPane
@onready var editor_pane = %MiddlePane
@onready var notes_pane = %RightPane

# Called when the node enters the scene tree for the first time.
func _ready():
	# Configure the error window size and give the panel to a singleton to use
	var target_size = self.size / 2
	%ErrorDisplayPopup.borderless = false
	%ErrorDisplayPopup.size = target_size
	SingletonObject.errorPopup = %ErrorDisplayPopup
	SingletonObject.errorTitle = %lblErrorHeader
	SingletonObject.errorText = %lblErrorMessage
	
	pass # Replace with function body.


func set_chat_pane_visible(visible_: bool = true):
	chat_pane.visible = visible_

	chat_pane.get_parent().visible = chat_pane.visible or editor_pane.visible

func set_editor_pane_visible(visible_: bool = true):
	editor_pane.visible = visible_

	editor_pane.get_parent().visible = chat_pane.visible or editor_pane.visible

func set_notes_pane_visible(visible_: bool = true):
	notes_pane.visible = visible_
