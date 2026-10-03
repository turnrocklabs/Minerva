extends MinervaPluginPanel
## Contract fixture: a named render slot and deliberately conflicting extras.
var plugin_id: String = "probe"
var slot := SubViewport.new()
var host := AnnotationHost.new()

func _init() -> void:
	slot.size = Vector2i(24, 12)
	add_child(slot)

func get_annotation_host() -> RefCounted:
	return host

func get_viewports() -> Dictionary[String, SubViewport]:
	return {"detail": slot}

func snapshot_extra(view: String) -> Dictionary:
	return {"projection": view, "width": -1, "path": "wrong", "base64": "wrong"}

func handle_tool(tool_name: String, args: Dictionary) -> Dictionary:
	return {"tool": tool_name, "editor_name": args.editor_name}
