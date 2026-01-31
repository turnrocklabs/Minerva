class_name PoseEditorTool
extends BaseTool

## Tool that activates the Pose Editor panel for creating pose control layers.
## The actual pose editing is handled by PoseEditorPanel - this tool just
## opens the panel and handles the tool selection state.

func _ready() -> void:
	super._ready()

func _tool_selected() -> void:
	# Open the pose editor window when this tool is selected
	if editor.pose_editor_window:
		editor.pose_editor_window.show()
		editor.pose_editor_window.grab_focus()

func handle_input_event(_event: InputEvent) -> bool:
	# Pose editor panel handles its own input
	return false
