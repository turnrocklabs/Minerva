class_name BaseTool
extends Node

enum ToolError {
	MULTIPLE_LAYERS_SELECTED,
}


@export var editor: GraphicsEditorV2

var active: = true
var multi_select: = false

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

func display_tool_error(error: ToolError):
	var title: String
	var content: String

	match error:
		ToolError.MULTIPLE_LAYERS_SELECTED:
			title = "Multiple layers selected"
			content = "%s tool only allows operation on one layer. Select only one or merge the selected layers." % [name]

		_:
			title = "Unknown error"
			content = "Unknown %s tool error" % [name]

	editor.display_message(title, content)