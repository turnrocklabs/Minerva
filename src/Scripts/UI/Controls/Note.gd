class_name Note
extends PanelContainer

@onready var checkbutton_node: CheckButton = $v/h/CheckButton
@onready var label_node: LineEdit = $v/h/Title
@onready var description_node: RichTextLabel = $v/Description


# this will react each time memory item is changed
var memory_item: MemoryItem:
	set(value):
		memory_item = value

		if not value: return

		label_node.text = value.Title
		description_node.text = value.Content
		checkbutton_node.button_pressed = value.Enabled


func _ready():
	label_node.text_changed.connect(
		func(text):
			if memory_item: memory_item.Title = text
	)


# show the dragged node when the drag ends
func _notification(notification_type):
	match notification_type:
		NOTIFICATION_DRAG_END:
			modulate.a = 1

## Replaces the children nodes of same parent by changing their index
func _replace_nodes(node1: Node, node2: Node) -> void:
	var dragged_node_index = node1.get_index()

	get_parent().move_child(node1, get_index())
	get_parent().move_child(node2, dragged_node_index)

# create a preview which is just duplicated Note node
# and make the original node transparent
func _get_drag_data(at_position: Vector2) -> Note:

	var preview = Container.new()
	var preview_note: Note = self.duplicate()

	preview.add_child(preview_note)
	preview.size = size
	preview_note.global_position = -at_position

	set_drag_preview(preview)

	modulate.a = 0

	return self

func _can_drop_data(_at_position: Vector2, data):
	if not data is Note: return false
	
	for node in get_parent().get_children():
		if node is Note and node.get_rect().has_point(_at_position):
			_replace_nodes(data, self)

	return true

func _drop_data(at_position: Vector2, data):
	data = data as Note

	_replace_nodes(data, self)
	


func _on_check_button_toggled(toggled_on: bool) -> void:
	if memory_item:
		memory_item.Enabled = toggled_on


func _on_remove_button_pressed():
	pivot_offset = size / 2

	var tween = get_tree().create_tween()
	tween.tween_property(self, "scale", Vector2.ZERO, 0.3)
	tween.tween_callback(queue_free)



func _on_edit_button_pressed():
	var ep: EditorPane = $"/root/RootControl/VBoxRoot/MainUI/HSplitContainer/HSplitContainer2/MiddlePane/VBoxContainer/vboxEditorMain/EditorPane"

	for i in range(ep.Tabs.get_tab_count()):
		var tab_control = ep.Tabs.get_tab_control(i)

		if tab_control.get_meta("associated_object") == memory_item:
			ep.Tabs.current_tab = i
			return

	var note_editor = NoteEditor.create(memory_item)

	note_editor.on_memory_item_changed.connect(func(): memory_item = note_editor.memory_item)

	var container = ep.add(note_editor, memory_item.Title)

	container.set_meta("associated_object", memory_item)

	# also change tab title if title has changed
	label_node.text_changed.connect(
		func(text):
			container.name = text
	)
