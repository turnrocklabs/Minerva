extends ToolCallBlock
## Completed plugin activity; the scene owns layout, the reply owns its data.

func _update_display() -> void:
	status_label.text = "Activity"
	tool_name_label.hide()
	arguments_section.hide()
	result_section.hide()


func set_activity(entries: Array, reply_id: String) -> void:
	set_meta("reply_id", reply_id)
	var rows: VBoxContainer = %Rows
	var template: VBoxContainer = %EntryTemplate
	for value: Variant in entries:
		if not value is Dictionary:
			continue
		var entry: Dictionary = value
		var row: VBoxContainer = template.duplicate() as VBoxContainer
		row.unique_name_in_owner = false
		var kind: Label = row.get_node("Summary/Kind") as Label
		var label: Label = row.get_node("Summary/Label") as Label
		var status: Label = row.get_node("Summary/Status") as Label
		var detail: Label = row.get_node("Detail") as Label
		var path: Label = row.get_node("Path") as Label
		kind.text = str(entry.get("kind", "")).replace("_", " ").capitalize()
		label.text = str(entry.get("label", ""))
		status.text = str(entry.get("status", "")).replace("_", " ").capitalize()
		detail.text = str(entry.get("detail", ""))
		detail.visible = not detail.text.is_empty()
		path.text = str(entry.get("path", ""))
		path.visible = not path.text.is_empty()
		rows.add_child(row)
		row.show()
