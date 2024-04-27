extends VBoxContainer

var Memories: Array[MemoryItem] = []
var MainTabContainer
var MainThreadId

## initilize the box
func _init(_parent, _threadId, _mem = null):
	self.MainTabContainer = _parent
	self.MainThreadId = _threadId
	self.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	self.size_flags_vertical = Control.SIZE_EXPAND_FILL

	if _mem != null:
		self.Memories = _mem
		render_items()
	pass


func _notification(notification_type):
	match notification_type:
		# Change MemoryItem Order when notes order changes
		NOTIFICATION_CHILD_ORDER_CHANGED:
			for note in get_children():
				note = note as Note
				note.memory_item.Order = note.get_index()

func render_items():
	for item in Memories:
		var note_control: Note = load("res://Scenes/Note.tscn").instantiate()
		
		self.add_child.call_deferred(note_control)
		await note_control.ready

		note_control.memory_item = item

		# when the note control is deleted, delete the memory item, so it doesnt get rerendered next time
		note_control.note_deleted.connect(self.MainTabContainer.delete_note.bind(item))

		# print("ALO")
		# print(note_control.label_node)


	# for item in Memories:
	# 	item.Order = order
	# 	var hbox = HBoxContainer.new()  # Create a new HBoxContainer
	# 	var checkbox = CheckBox.new()  # Create a CheckBox
	# 	checkbox.pressed.connect(item._enable_toggle)
	# 	#checkbox.pressed.connect(self.emitter.bind(1)) ## syntax example of how to pass params.

	# 	# check the box if the memory is enabled.
	# 	if item.Enabled:
	# 		checkbox.button_pressed = true

	# 	# Create a Button to look like a Label
	# 	var label_button = Button.new()
	# 	label_button.text = item.Title
	# 	label_button.flat = true  # Makes the button have no raised look, more label-like

	# 	# You can set more properties to ensure the button looks exactly like a label, such as removing the hover and click effects
	# 	label_button.set("custom_styles/normal", StyleBoxEmpty.new())
	# 	label_button.set("custom_styles/hover", StyleBoxEmpty.new())
	# 	label_button.set("custom_styles/pressed", StyleBoxEmpty.new())
	# 	label_button.set("custom_styles/focus", StyleBoxEmpty.new())
	# 	# Connect the button's pressed signal if needed
	# 	# label_button.connect("pressed", self, "_on_label_button_pressed", [item])

	# 	# Create rest of buttons (Delete, Up, Down, Open, Edit) as previously

	# 	var delete_button = Button.new()
	# 	delete_button.text = "Delete"
	# 	# Connect delete button's signal here if needed

	# 	var up_button = Button.new()
	# 	up_button.text = "Up"
	# 	# Connect up button's signal here if needed

	# 	var down_button = Button.new()
	# 	down_button.text = "Down"
	# 	# Connect down button's signal here if needed

	# 	var open_button = Button.new()
	# 	open_button.text = "Open"
	# 	# Connect open button's signal here if needed

	# 	var edit_button = Button.new()
	# 	edit_button.text = "Edit"
	# 	# Connect edit button's signal here if needed

	# 	# Add the Button (which looks like a Label) and other Buttons to the HBoxContainer
	# 	hbox.add_child(checkbox)
	# 	hbox.add_child(label_button)
	# 	hbox.add_child(delete_button)
	# 	hbox.add_child(up_button)
	# 	hbox.add_child(down_button)
	# 	hbox.add_child(open_button)
	# 	hbox.add_child(edit_button)

	# 	# Add the HBoxContainer to the VBoxContainer
	# 	self.add_child(hbox)

	# 	# Increment the order value
	# 	order += 1
	# pass
