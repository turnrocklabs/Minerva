extends Control


var is_dragging = false
var drag_start_position = Vector2()

@export  var terminal_container: TerminalTabContainer
#variables where writing out notes Head and description
@onready var project_name_label: RichTextLabel = %ProjectNameLabel

@onready var service_pane_control: Control = %ServicesPane
@onready var chats_control: Control = %Chats


func _ready() -> void:
	# _open_drawer_notes()

	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = %fdgOpenFile.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 14)
	
	_update_project_label()
	SingletonObject.updated_save_state.connect(_update_project_label)


	# Set the reference to the notes container here as the singleton object is loaded before this one
	SingletonObject.notes_container = %tcThreads
	SingletonObject.notes_container.create_note_callback = %CreateNewNote.popup_centered

	SingletonObject.drawer_notes_container = %tcThreadsDrawer
	SingletonObject.drawer_notes_container.supports_remote = false
	SingletonObject.drawer_notes_container.create_note_callback = (
		func():
			%CreateNewNote.popup_centered()
			%CreateNewNote.notes_container_override = SingletonObject.drawer_notes_container
	)

	SingletonObject.agent_notes_container = %tcThreadsAgent
	SingletonObject.agent_notes_container.supports_remote = false

	get_window().files_dropped.connect(_on_files_dropped)


# Text sizing note: the old whole-tree "text zoom" (recursive font-size
# overrides over every Control) is gone — stamping fonts into fixed layouts
# overflowed popups. Chat text size is now chat-scoped: SingletonObject owns
# the value (chat_font_size), MessageMarkdown applies it to its own labels.
func _gui_input(event):

	if event.is_action_released("zoom_in", true):
		SingletonObject.increment_chat_font_size()

		accept_event()
	elif event.is_action_released("zoom_out", true):
		SingletonObject.decrement_chat_font_size()

		accept_event()

#Show the window where we can add note
func _on_btn_create_note_pressed():
	%CreateNewNote.popup_centered()

# this method pops up the preferences window
func _on_button_pressed() -> void:
	%PreferencesPopup.popup_centered()

#btn attachment for notes
func _on_btn_add_attachment_pressed():
	# Not sure why its located in the chats
	SingletonObject.Chats._on_btn_attach_file_pressed()


func _on_btn_voice_pressed():
	var req := AudioToTexts.PTTRequest.new()
	req.target = %NoteDescription
	req.mic_button = %btnVoice
	req.stop_button = %StopButton4
	var err: int = SingletonObject.AtT.start_ptt(req)
	if err != OK:
		push_warning("MainScene: PTT failed for description: %s" % error_string(err))
		return
	%AddNotePopUp.disabled = false
	
func _on_btn_voice_for_header_pressed():
	var req := AudioToTexts.PTTRequest.new()
	req.target = %NoteHead
	req.mic_button = %btnVoiceForHeader
	req.stop_button = %StopButton3
	var err: int = SingletonObject.AtT.start_ptt(req)
	if err != OK:
		push_warning("MainScene: PTT failed for header: %s" % error_string(err))
		return
	%AddNotePopUp.disabled = false

func _on_btn_voice_for_note_tab_pressed():
	var req := AudioToTexts.PTTRequest.new()
	req.target = %txtNewTabName
	req.mic_button = %btnVoiceForNoteTab
	req.stop_button = %AudioStopButton2
	var err: int = SingletonObject.AtT.start_ptt(req)
	if err != OK:
		push_warning("MainScene: PTT failed for note tab: %s" % error_string(err))
		return
	%AudioStopButton2.visible = true

# this method calls the singleton object to toggle the enable/disable all notes in all tabs
var notes_enabled = true
func _on_disable_notes_button_pressed() -> void:
	if !notes_enabled:
		%DisableNotesButton.text = "Disable All"
		SingletonObject.toggle_all_notes(notes_enabled)
	if notes_enabled:
		%DisableNotesButton.text = "Enable All"
		SingletonObject.toggle_all_notes(notes_enabled)
	
	notes_enabled = !notes_enabled


#region help menu


func _on_help_id_pressed(id: int) -> void:
	match id:
		0:  # id for the About option
			var about_scene: PackedScene = load("res://Scenes/windows/about_popup.tscn")
			var about_scene_inst: AboutPopup = about_scene.instantiate()
			add_child(about_scene_inst)
			about_scene_inst.popup_centered()
		1:  # id for the License Agreement
			var license_scene: PackedScene = load("res://Scenes/windows/license_agreement_panel.tscn")
			var license_scene_inst: LicensePopup = license_scene.instantiate()
			add_child(license_scene_inst)
			license_scene_inst.popup_centered()
		2:  # id for MCP Server Setup
			_show_mcp_setup_dialog()

#endregion help menu


func _show_mcp_setup_dialog() -> void:
	var dialog := Window.new()
	dialog.title = "MCP Server Setup"
	dialog.size = Vector2i(600, 480)
	dialog.transient = true
	dialog.exclusive = true
	dialog.wrap_controls = true
	dialog.content_scale_factor = get_tree().root.content_scale_factor

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	dialog.add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 15)
	margin.add_child(vbox)

	var title_label := Label.new()
	title_label.text = "Using Minerva as an MCP Server"
	title_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title_label)

	var step1 := RichTextLabel.new()
	step1.bbcode_enabled = true
	step1.fit_content = true
	step1.scroll_active = false
	step1.text = """[b]1. Start the HTTP Server[/b]
Go to [b]Tools → Minerva (Self) → Start HTTP Server[/b]
The server runs on port 9315 by default."""
	vbox.add_child(step1)

	var step2_label := Label.new()
	step2_label.text = "2. Configure Claude Code"
	step2_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(step2_label)

	var config_hint := Label.new()
	config_hint.text = "Add to ~/.claude/claude_code_config.json:"
	vbox.add_child(config_hint)

	var config_text := TextEdit.new()
	config_text.custom_minimum_size = Vector2(0, 80)
	config_text.text = """{
  "mcpServers": {
	"minerva": {
	  "type": "http",
	  "url": "http://localhost:9315/mcp"
    }
  }
}"""
	config_text.editable = false
	vbox.add_child(config_text)

	var copy_btn := Button.new()
	copy_btn.text = "Copy Config"
	copy_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(config_text.text)
		copy_btn.text = "Copied!"
		get_tree().create_timer(1.5).timeout.connect(func(): copy_btn.text = "Copy Config")
	)
	vbox.add_child(copy_btn)

	var step3_4 := RichTextLabel.new()
	step3_4.bbcode_enabled = true
	step3_4.fit_content = true
	step3_4.scroll_active = false
	step3_4.text = """[b]3. Available Tools (37+)[/b]
• [b]Chat:[/b] Create chats, send messages, set system prompts
• [b]Notes:[/b] Create/manage notes for LLM context
• [b]Editors:[/b] Create text, graphics, and spreadsheet editors
• [b]Graphics AI:[/b] Generate images with AI models
• [b]Spreadsheets:[/b] Full spreadsheet with formulas and charts

[b]4. Example Usage[/b]
Claude Code can then use commands like:
"Create a spreadsheet in Minerva with my budget data"
"Start a chat with Gemini and ask about my notes\""""
	vbox.add_child(step3_4)

	var button_hbox := HBoxContainer.new()
	button_hbox.alignment = BoxContainer.ALIGNMENT_END
	vbox.add_child(button_hbox)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): dialog.queue_free())
	button_hbox.add_child(close_btn)

	dialog.close_requested.connect(func(): dialog.queue_free())

	add_child(dialog)
	dialog.popup_centered()


func _on_save_open_editor_tabs_button_pressed() -> void:
	SingletonObject.SaveOpenEditorTabs.emit()
	print("saved")

func _on_audio_stop_button_2_pressed() -> void:
	SingletonObject.AtT._StopConverting()


func _on_stop_button_3_pressed() -> void:
	SingletonObject.AtT._StopConverting()


func _on_stop_button_4_pressed() -> void:
	SingletonObject.AtT._StopConverting()


func _input(event) -> void:
	if event.is_action_pressed("ui_terminal", true):
		terminal_container.visible = not terminal_container.visible
		accept_event()
	elif event.is_action_pressed("new_editor_item", true):
		_show_new_editor_item_popup()
		accept_event()
	# Detect mouse button press to start drag
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			drag_start_position = event.position
			is_dragging = false
		else:
			is_dragging = false
			await get_tree().process_frame
			%DropForNode.visible = false

	# Detect mouse motion to confirm dragging
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if not is_dragging:
			if get_viewport().gui_get_drag_data() != null: # Minimum distance to count as a drag
				if typeof(get_viewport().gui_get_drag_data()) == TYPE_STRING:
					is_dragging = true
					%DropForNode.visible = true


var _ledger_popup: PopupMenu
var _showing_archived: bool = false

func _on_btn_ledger_pressed() -> void:
	if not _ledger_popup:
		_ledger_popup = PopupMenu.new()
		_ledger_popup.add_item("Browse Ledger", 0)
		_ledger_popup.add_separator()
		_ledger_popup.add_item("Archive Chat", 1)
		_ledger_popup.add_check_item("Show Archived", 2)
		_ledger_popup.id_pressed.connect(_on_ledger_menu_selected)
		add_child(_ledger_popup)
	# Update archive label based on current chat state
	if SingletonObject.Chats and not SingletonObject.ChatList.is_empty():
		var idx = SingletonObject.Chats.current_tab
		if idx >= 0 and idx < SingletonObject.ChatList.size():
			var history: ServiceHistory = SingletonObject.ChatList[idx]
			var archive_idx = _ledger_popup.get_item_index(1)
			_ledger_popup.set_item_text(archive_idx, "Restore Chat" if history.Archived else "Archive Chat")
	_ledger_popup.set_item_checked(_ledger_popup.get_item_index(2), _showing_archived)
	_ledger_popup.popup(Rect2i(get_viewport().get_mouse_position(), Vector2i.ZERO))


func _on_ledger_menu_selected(id: int) -> void:
	match id:
		0:  # Browse Ledger
			if SingletonObject.Chats:
				SingletonObject.Chats.open_ledger_browser()
		1:  # Archive / Restore Chat
			if SingletonObject.Chats:
				SingletonObject.Chats.archive_current_chat()
		2:  # Show Archived toggle
			_showing_archived = not _showing_archived
			if SingletonObject.Chats:
				SingletonObject.Chats.set_show_archived(_showing_archived)


@onready var bottom_drawer_control: DrawerNotesManager = %BottomDrawerControl
@onready var notes_drawer_split: VSplitContainer = %NotesDrawerSplit
@onready var agent_notes_container: NotesContainer = %tcThreadsAgent
@onready var drawer_notes_container: NotesContainer = %tcThreadsDrawer
@onready var bottom_notes_label: Label = %BottomNotesLabel
@onready var drawer_add_note_button: Button = %DrawerAddNote
@onready var drawer_add_shelf_button: Button = %DrawerAddShelf
var split_drawer_tween: Tween
@export var _drawer_anim_duration: = 0.5
var _bottom_notes_mode: String = ""

func _set_bottom_notes_mode(mode: String) -> void:
	_bottom_notes_mode = mode
	var show_drawer := mode != "agent"
	if bottom_notes_label:
		bottom_notes_label.text = "Drawer" if show_drawer else "Agent Notes"
	if drawer_add_note_button:
		drawer_add_note_button.visible = show_drawer
	if drawer_add_shelf_button:
		drawer_add_shelf_button.visible = show_drawer
	if drawer_notes_container:
		drawer_notes_container.visible = show_drawer
	if agent_notes_container:
		agent_notes_container.visible = not show_drawer

	if show_drawer:
		_open_drawer_notes()
		bottom_drawer_control.load_drawer_data()


func _toggle_bottom_notes_panel(mode: String) -> void:
	if split_drawer_tween and split_drawer_tween.is_running():
		return

	var was_visible := bottom_drawer_control.visible
	var switching_mode := was_visible and _bottom_notes_mode != mode
	if not was_visible or switching_mode:
		_set_bottom_notes_mode(mode)

	if not was_visible:
		notes_drawer_split.split_offset = 600
		split_drawer_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SPRING)
		bottom_drawer_control.visible = true
		split_drawer_tween.tween_property(notes_drawer_split, "split_offset", 0, _drawer_anim_duration)
		return

	if switching_mode:
		return
	else:
		
		split_drawer_tween = create_tween().set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_LINEAR)
		split_drawer_tween.tween_property(notes_drawer_split, "split_offset", 600, _drawer_anim_duration)
		
		await get_tree().create_timer(0.48).timeout
		bottom_drawer_control.visible = false

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)


func _on_btn_drawer_pressed() -> void:
	_toggle_bottom_notes_panel("drawer")


func _on_btn_agent_notes_pressed() -> void:
	_toggle_bottom_notes_panel("agent")


#reading file and create note in Drawer thread
func _open_drawer_notes() -> void:
	print("Drawer opened")
	SingletonObject.emit_signal("openDrawerNotes")

func _update_project_label(new_text: String = "", saved_state: bool = true) -> void:
	var base_text: String
	if new_text.is_empty() and saved_state:
		base_text = ""
	elif !new_text.is_empty() and saved_state:
		base_text = new_text
	elif new_text.is_empty() and !saved_state:
		base_text = project_name_label.text.replace("*", "") + "*"
	elif !new_text.is_empty() and !saved_state:
		base_text = new_text + "*"
	project_name_label.text = base_text



func _on_files_dropped(files: PackedStringArray) -> void:
	var editor_pane = SingletonObject.editor_pane
	if editor_pane:
		if !editor_pane.get_global_rect().has_point(get_global_mouse_position()):
			return
	if editor_pane.Tabs.get_tab_count() < 1:
		for file in files:
			if SingletonObject.supported_image_formats.has(file.get_extension()):
				editor_pane.add(Editor.Type.GRAPHICS, file, file.get_file())
			elif SingletonObject.supported_text_formats.has(file.get_extension()):
				editor_pane.add(Editor.Type.TEXT, file, file.get_file())
		return
	else:
		var editor: = editor_pane.Tabs.get_current_tab_control() as Editor
		if editor.type == Editor.Type.GRAPHICS:
			for file in files:
				var image: = Image.load_from_file(file)
				editor.graphics_editor.create_new_image_layer(file.get_file(), image)


## Show popup menu with all creatable editor items from registry
func _show_new_editor_item_popup() -> void:
	var registry = SingletonObject.creatable_item_registry
	var items = registry.get_all_items()

	if items.is_empty():
		return

	var popup = PopupMenu.new()
	popup.name = "NewEditorItemPopup"

	for item in items:
		popup.add_item(item.display_name)

	popup.id_pressed.connect(func(id: int):
		if id >= 0 and id < items.size():
			var selected_item = items[id]
			selected_item.create_callback.call()
	)

	add_child(popup)
	popup.popup_centered()
	popup.queue_free.call_deferred()
