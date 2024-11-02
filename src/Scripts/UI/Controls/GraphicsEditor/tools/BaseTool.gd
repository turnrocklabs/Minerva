class_name BaseTool
extends Node

@export var editor: GraphicsEditorV2

var active: = true

func _ready() -> void:
	
	# each time the tool is changed to this one, update the custom cursor
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self: _tool_selected()
	)

func handle_input_event(_event: InputEvent) -> void:
	pass


func _tool_selected():
	pass
