extends SceneTree
## Verifies self-scripted scene getters preserve repeated instantiation behavior.
## The graphical shutdown probe measures resource ownership after these nodes free.

const CASES: Array[Dictionary] = [
	{"script": "res://Scripts/UI/Controls/Note.gd", "property": "_scene"},
	{"script": "res://Scripts/UI/Controls/MessageMarkdown.gd", "property": "message_scene"},
	{"script": "res://Scripts/UI/Controls/CodeMarkdownLabel.gd", "property": "code_markdown_label"},
	{"script": "res://Scripts/UI/Controls/PackageEditor/PackageEditor.gd", "property": "_scn"},
	{"script": "res://Scenes/note/NoteVBox.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/string/string.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/image/image.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/file/file.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/list/list.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/list/item_container/item_container.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/bool/bool.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/number/number.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/object/object_field.gd", "property": "_scene"},
	{"script": "res://Scripts/Services/Providers/Core/dynamic_ui/note/NoteField.gd", "property": "_scene"},
	{"script": "res://Scripts/UI/Controls/Editor.gd", "property": "editor_scene"},
	{"script": "res://Scripts/UI/Controls/Editor.gd", "property": "graphics_editor_scene"},
	{"script": "res://Scripts/UI/Controls/Editor.gd", "property": "spreadsheet_editor_scene"},
	{"script": "res://Scripts/UI/Controls/ReasoningBlock.gd", "property": "_reasoning_block_scene"},
	{"script": "res://Scripts/UI/Controls/RequestMetadataBlock.gd", "property": "_block_scene"},
	{"script": "res://Scripts/UI/Controls/ToolCallBlock.gd", "property": "_tool_call_block_scene"},
	{"script": "res://Scripts/UI/Controls/Autocoder/AutocoderLogsViewer.gd", "property": "autocoder_logs_scene"},
	{"script": "res://Scenes/toast/toast_notification.gd", "property": "_scnene"},
	{"script": "res://Scripts/UI/Controls/Layer.gd", "property": "_scene"},
	{"script": "res://Scripts/UI/Controls/LayerV2.gd", "property": "_scene"},
	{"script": "res://Scripts/UI/Controls/CloudControl.gd", "property": "_scene"},
	{"script": "res://Scripts/UI/Controls/ChatImage.gd", "property": "_scene"},
	{"script": "res://Scripts/UI/Controls/GraphicsEditor/LayerCard.gd", "property": "_scene"},
]

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	for case: Dictionary in CASES:
		var script_path: String = case.script
		var script: GDScript = load(script_path)
		var property_name: StringName = case.property
		var instances_valid := true
		for _attempt: int in range(2):
			var packed: PackedScene = script.get(property_name)
			var instance: Node = packed.instantiate() if packed != null else null
			instances_valid = instances_valid and instance != null
			if instance != null:
				instance.free()
			packed = null
		await process_frame
		check("getter repeatedly instantiates %s" % script_path, instances_valid)

	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)
