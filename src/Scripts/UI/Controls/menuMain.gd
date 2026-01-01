### Reference Information ###
### Title: menuMain
extends MenuBar

const NudgeMCPClientScript := preload("res://Scripts/Services/MCP/Servers/NudgeMCPClient.gd")

@onready var view = $View as PopupMenu
@onready var project: PopupMenu = $Project
@onready var edit: PopupMenu = %File

var popUpRecent
var recentList
var ButtonCloseForPopUp

# Add a new submenu for 'File'
@onready var file_submenu: PopupMenu = PopupMenu.new()

# MCP menu
var mcp_menu: PopupMenu
var servers_submenu: PopupMenu

func _on_file_index_pressed(index):
	match index:
		1:
			%fdgOpenFile.popup_centered()
		2: # this match is for the save button
				# get current editor tab
			var tabs = SingletonObject.editor_container.editor_pane.Tabs
			var current_editor_tab = tabs.get_current_tab_control()
			
			#check is tab exists and a file for the tab doesn't exist (the file is being saved for the first time)
			if current_editor_tab and !current_editor_tab.file_saved_in_disc :
				current_editor_tab.prompt_close(true)# shows file save pop up
				
			else: # this runs if the file has been saved already so the pop up for saving does not appear
				current_editor_tab.save_file_to_disc(current_editor_tab.file) #calls save to disc func
				
		3: #this match if for the save as... button
			var tabs = SingletonObject.editor_container.editor_pane.Tabs
			var current_editor_tab = tabs.get_current_tab_control()
			#current_editor_tab.save_file_to_disc(current_editor_tab.file, true)
			if current_editor_tab:
				current_editor_tab.prompt_close(true, true)
		4:
			var preferences_popup: PreferencesPopup = %PreferencesPopup

			if not preferences_popup.visible:
				preferences_popup.popup_centered()
			else:
				preferences_popup.grab_focus()

# Handle new file creation
func handle_new_file():
	SingletonObject.editor_container.editor_pane.add(Editor.Type.TEXT)

# Handle new graphics creation
func handle_new_graphics():
	SingletonObject.is_graph = true
	SingletonObject.editor_container.editor_pane.add(Editor.Type.GRAPHICS)

func _on_file_submenu_index_pressed(index):
	match index:
		0:
			handle_new_file()
		1:
			SingletonObject.is_picture = false
			handle_new_graphics()
			


func _on_package_submenu_id_pressed(id: int):
	match id:
		0: SingletonObject.PackageProject.emit()
		1: SingletonObject.UnpackageProject.emit()


@onready var project_recent: Window = %ProjectRecent

func _ready():
	
	popUpRecent = project_recent
	popUpRecent.visible = false
	#set op position for pop up by a center of the root node
	popUpRecent.position.x = $"../../..".size.x/2
	popUpRecent.position.y = $"../../..".size.y/2

	
	recentList = popUpRecent.find_child("RecentList")
	popUpRecent.close_requested.connect(popUpClose)
	
	
	# Create package project submenu
	var package_submenu: = PopupMenu.new()
	package_submenu.name = "Package Project"
	package_submenu.add_item("Create", 0)
	package_submenu.add_item("Unpack", 1)
	package_submenu.id_pressed.connect(_on_package_submenu_id_pressed)
	
	%Project.add_child(package_submenu)
	%Project.add_submenu_item("Package Project", package_submenu.name, 0)
	# Add the shortcut for the new project button
	var new_project_shortcut = Shortcut.new()
	var new_project_input_event = InputEventAction.new()
	new_project_input_event.action = "new_project"
	new_project_shortcut.events.append(new_project_input_event)
	%Project.set_item_shortcut(0, new_project_shortcut, true)
	# Add the shortcut for the Open project button
	var open_project_shortcut = Shortcut.new()
	var open_project_input_event = InputEventAction.new()
	open_project_input_event.action = "open_project"
	open_project_shortcut.events.append(open_project_input_event)
	%Project.set_item_shortcut(1, open_project_shortcut, true)
	# Add the shortcut for the Save project button
	var save_project_shortcut = Shortcut.new()
	var save_project_input_event = InputEventAction.new()
	save_project_input_event.action = "save_project"
	save_project_shortcut.events.append(save_project_input_event)
	%Project.set_item_shortcut(2, save_project_shortcut, true)
	
	# Create the new submenu
	file_submenu.name = "file_submenu"
	file_submenu.add_item("New File")
	file_submenu.add_item("New Graphics")
	file_submenu.index_pressed.connect(_on_file_submenu_index_pressed)
	# Add the "New" submenu to the top of the "File" menu
	%File.add_child(file_submenu)
	%File.add_submenu_item("New", "file_submenu", 0)  # Note the index 0 here

	# Add the rest of the "File" menu items
	%File.add_item("Open", 1)
	var open_file_shortcut = Shortcut.new()
	var input_event = InputEventAction.new()
	input_event.action = "open_file"
	open_file_shortcut.events.append(input_event)
	%File.set_item_shortcut(1,open_file_shortcut, true)
	%File.add_item("Save", 2)
	%File.add_item("Save As", 3)
	%File.add_item("Preferences", 4)
	# Add the shortcut for the preferences popup
	var preferences_shortcut = Shortcut.new()
	var preferences_input_event = InputEventAction.new()
	preferences_input_event.action = "preferences"
	preferences_shortcut.events.append(preferences_input_event)
	%File.set_item_shortcut(4, preferences_shortcut, true)
	
	var terminal_shortcut = Shortcut.new()
	var terminal_input_event = InputEventAction.new()
	terminal_input_event.action = "ui_terminal"
	terminal_shortcut.events.append(terminal_input_event)
	%View.set_item_shortcut(3, terminal_shortcut, true)

	# Create MCP menu (before Help)
	_setup_mcp_menu()

	# Connect to MCP signals for live status updates
	_connect_mcp_signals()


func _setup_mcp_menu() -> void:
	mcp_menu = PopupMenu.new()
	mcp_menu.name = "MCP"
	mcp_menu.title = "MCP"

	# Agent Mode toggle (ID 10)
	mcp_menu.add_check_item("Agent Mode", 10)
	mcp_menu.set_item_tooltip(mcp_menu.get_item_index(10), "Enable Agent Mode: Allow the LLM to use MCP tools")
	mcp_menu.add_separator()

	# Create servers submenu for connection status/reconnect
	servers_submenu = PopupMenu.new()
	servers_submenu.name = "MCPServers"
	servers_submenu.id_pressed.connect(_on_mcp_servers_submenu_pressed)
	mcp_menu.add_child(servers_submenu)
	mcp_menu.add_submenu_item("Servers", servers_submenu.name)
	mcp_menu.add_separator()

	# Nudge section - Pull operations
	mcp_menu.add_item("Pull All from Nudge", 0)
	mcp_menu.add_separator()

	# Push operations
	mcp_menu.add_item("Push Current Tab to Nudge", 1)
	mcp_menu.add_item("Push All Tabs to Nudge", 3)
	mcp_menu.add_separator()

	# Delete operations
	mcp_menu.add_item("Delete Current Tab from Nudge", 4)

	mcp_menu.id_pressed.connect(_on_mcp_menu_id_pressed)

	# Refresh servers submenu when menu is about to show
	mcp_menu.about_to_popup.connect(_on_mcp_menu_about_to_popup)

	# Insert before Help menu
	var help_idx := -1
	for i in get_child_count():
		if get_child(i).name == "Help":
			help_idx = i
			break

	if help_idx >= 0:
		add_child(mcp_menu)
		move_child(mcp_menu, help_idx)
	else:
		add_child(mcp_menu)


func _on_mcp_menu_id_pressed(id: int) -> void:
	match id:
		0:  # Pull All from Nudge
			_nudge_pull_all()
		1:  # Push Current Tab to Nudge
			_nudge_push_current_tab()
		3:  # Push All Tabs to Nudge
			_nudge_push_all_tabs()
		4:  # Delete Current Tab from Nudge
			_nudge_delete_current_tab()
		10:  # Agent Mode toggle
			_toggle_agent_mode()


func _nudge_pull_all() -> void:
	var nudge_client := NudgeMCPClientScript.new()

	var result: Dictionary = await nudge_client.pull_all_hints()
	if result.get("error"):
		SingletonObject.create_toast_notification(
			"Failed to pull from Nudge: %s" % result.get("error"),
			ToastNotification.Type.ERROR
		)
		return

	var hints: Array = result.get("hints", [])
	if hints.is_empty():
		SingletonObject.create_toast_notification("No hints found in Nudge", ToastNotification.Type.WARNING)
		return

	# Group hints by component
	var hints_by_component: Dictionary = {}
	for hint_data in hints:
		var component: String = hint_data.get("component", "default")
		if component.is_empty():
			component = "default"
		if not hints_by_component.has(component):
			hints_by_component[component] = []
		hints_by_component[component].append(hint_data)

	var created_count := 0
	var updated_count := 0
	var tabs_created := 0

	var notes_container: NotesContainer = SingletonObject.notes_container

	for component in hints_by_component:
		var component_hints: Array = hints_by_component[component]
		var target_vbox: NoteVBox = notes_container.find_or_create_tab(component)
		if target_vbox.get_notes().is_empty():
			tabs_created += 1

		for hint_data in component_hints:
			var key: String = hint_data.get("key", "")
			var hint_obj: Dictionary = hint_data.get("hint", {})
			var meta: Dictionary = hint_obj.get("meta", {})
			var value = hint_obj.get("value", "")

			# Detect note type from meta or from value.content_type
			var note_type: String = meta.get("note_type", "")
			if note_type.is_empty() and value is Dictionary:
				var content_type: String = value.get("content_type", "")
				if content_type.begins_with("image/"):
					note_type = "image"
				elif content_type.begins_with("audio/"):
					note_type = "audio"
				else:
					note_type = "text"
			elif note_type.is_empty():
				note_type = "text"

			var note_title: String = key
			var existing_note := target_vbox._find_note_by_title(note_title)

			# Handle different note types
			match note_type:
				"image":
					if existing_note:
						# Update existing image note
						var updated := await _update_image_note_from_blob(existing_note, value, nudge_client)
						if updated:
							existing_note.set_meta("nudge_hint", hint_data)
							updated_count += 1
					else:
						# Create new image note
						var note := await _create_image_note_from_blob(note_title, value, nudge_client)
						if note:
							note.set_meta("nudge_hint", hint_data)
							target_vbox.add_note(note)
							created_count += 1

				"audio":
					if existing_note:
						# Can't easily update audio notes, skip
						existing_note.set_meta("nudge_hint", hint_data)
						updated_count += 1
					else:
						# Create new audio note
						var note := await _create_audio_note_from_blob(note_title, value, nudge_client)
						if note:
							note.set_meta("nudge_hint", hint_data)
							target_vbox.add_note(note)
							created_count += 1

				_:  # text or unknown
					var content: String
					if value is String:
						content = value
					elif value is Dictionary or value is Array:
						content = JSON.stringify(value, "  ")
					else:
						content = str(value)

					if existing_note:
						if existing_note.type == Note.Type.TEXT:
							var text_controls = existing_note.get_controls_container()
							if text_controls and "content" in text_controls:
								text_controls.content = content
						existing_note.set_meta("nudge_hint", hint_data)
						updated_count += 1
					else:
						var note := Note.create_text_note(note_title, content)
						note.set_meta("nudge_hint", hint_data)
						target_vbox.add_note(note)
						created_count += 1

	var msg := "Pulled %d new, %d updated" % [created_count, updated_count]
	if tabs_created > 0:
		msg += " (%d new tabs)" % tabs_created
	SingletonObject.create_toast_notification(msg, ToastNotification.Type.SUCCESS)


func _nudge_push_current_tab() -> void:
	var notes_container: NotesContainer = SingletonObject.notes_container
	if notes_container.get_tab_count() == 0:
		SingletonObject.create_toast_notification("No tabs to push", ToastNotification.Type.WARNING)
		return

	var current_vbox: NoteVBox = notes_container.get_current_tab_control() as NoteVBox
	if not current_vbox:
		SingletonObject.create_toast_notification("No active tab", ToastNotification.Type.WARNING)
		return

	var notes := current_vbox.get_notes()
	if notes.is_empty():
		SingletonObject.create_toast_notification("No notes to push", ToastNotification.Type.WARNING)
		return

	var nudge_client := NudgeMCPClientScript.new()
	var component := current_vbox.name
	var success_count := 0
	var error_count := 0

	for note in notes:
		var result: Dictionary = await nudge_client.push_note_simple(note, component)
		if result.get("error"):
			error_count += 1
			push_warning("Failed to push note '%s': %s" % [note.title, result.get("error")])
		else:
			success_count += 1

	if error_count > 0:
		SingletonObject.create_toast_notification(
			"Pushed %d notes to '%s' (%d failed)" % [success_count, component, error_count],
			ToastNotification.Type.WARNING
		)
	else:
		SingletonObject.create_toast_notification(
			"Pushed %d notes to '%s'" % [success_count, component],
			ToastNotification.Type.SUCCESS
		)


func _show_nudge_status() -> void:
	var connected := false
	if SingletonObject.mcp_manager:
		connected = SingletonObject.mcp_manager.is_server_connected("nudge")

	if connected:
		SingletonObject.create_toast_notification("Nudge: Connected", ToastNotification.Type.SUCCESS)
	else:
		SingletonObject.create_toast_notification("Nudge: Not connected", ToastNotification.Type.ERROR)


## Refresh the servers submenu with current connection status
func _refresh_servers_submenu() -> void:
	if not servers_submenu:
		return

	servers_submenu.clear()

	var mcp = SingletonObject.mcp_manager
	if not mcp:
		servers_submenu.add_item("MCP not initialized", -1)
		servers_submenu.set_item_disabled(0, true)
		return

	var config = mcp.config
	if not config:
		servers_submenu.add_item("No config", -1)
		servers_submenu.set_item_disabled(0, true)
		return

	var server_names = config.get_server_names()
	var idx := 0
	for server_name in server_names:
		var connected = mcp.is_server_connected(server_name)
		var status = "✓" if connected else "✗"
		servers_submenu.add_item("%s %s" % [server_name, status], idx)
		idx += 1

	servers_submenu.add_separator()
	servers_submenu.add_item("Refresh All", 100)


## Handle server submenu item pressed
func _on_mcp_servers_submenu_pressed(id: int) -> void:
	if id == 100:  # Refresh All
		_reconnect_all_mcp_servers()
		return

	var mcp = SingletonObject.mcp_manager
	if not mcp or not mcp.config:
		return

	var server_names = mcp.config.get_server_names()
	if id >= 0 and id < server_names.size():
		var server_name = server_names[id]
		_reconnect_mcp_server(server_name)


## Reconnect a single MCP server
func _reconnect_mcp_server(server_name: String) -> void:
	var mcp = SingletonObject.mcp_manager
	if not mcp:
		SingletonObject.create_toast_notification("MCP not initialized", ToastNotification.Type.ERROR)
		return

	# Disconnect first if connected (to force fresh connection)
	if mcp.is_server_connected(server_name):
		mcp.disconnect_server(server_name)

	SingletonObject.create_toast_notification(
		"%s: Connecting..." % server_name,
		ToastNotification.Type.WARNING
	)

	var err = await mcp.connect_server(server_name)
	if err == OK:
		SingletonObject.create_toast_notification(
			"%s: Connected" % server_name,
			ToastNotification.Type.SUCCESS
		)
	else:
		SingletonObject.create_toast_notification(
			"%s: Connection failed" % server_name,
			ToastNotification.Type.ERROR
		)
	_refresh_servers_submenu()


## Reconnect all MCP servers
func _reconnect_all_mcp_servers() -> void:
	var mcp = SingletonObject.mcp_manager
	if not mcp or not mcp.config:
		SingletonObject.create_toast_notification("MCP not initialized", ToastNotification.Type.ERROR)
		return

	var server_names = mcp.config.get_server_names()
	var connected := 0
	var failed: Array[String] = []

	for server_name in server_names:
		if mcp.is_server_connected(server_name):
			connected += 1
			continue
		var success = await mcp.connect_server(server_name)
		if success:
			connected += 1
		else:
			failed.append(server_name)

	if failed.is_empty():
		SingletonObject.create_toast_notification(
			"MCP: Connected %d/%d" % [connected, server_names.size()],
			ToastNotification.Type.SUCCESS
		)
	else:
		SingletonObject.create_toast_notification(
			"MCP: %d/%d (%s failed)" % [connected, server_names.size(), ", ".join(failed)],
			ToastNotification.Type.ERROR
		)
	_refresh_servers_submenu()


## Connect to MCP manager signals for live status updates
func _connect_mcp_signals() -> void:
	if SingletonObject.mcp_manager:
		var mcp = SingletonObject.mcp_manager
		if not mcp.server_connected.is_connected(_on_mcp_status_changed):
			mcp.server_connected.connect(_on_mcp_status_changed)
		if not mcp.server_disconnected.is_connected(_on_mcp_status_changed):
			mcp.server_disconnected.connect(_on_mcp_status_changed)


## Handle MCP server status change
func _on_mcp_status_changed(_server_name: String) -> void:
	_refresh_servers_submenu()


## Handle MCP menu about to show - refresh servers submenu
func _on_mcp_menu_about_to_popup() -> void:
	_refresh_servers_submenu()
	_connect_mcp_signals()  # Try connecting signals if not already connected
	# Update Agent Mode checkbox state
	if SingletonObject.Chats:
		var agent_mode_idx := mcp_menu.get_item_index(10)
		mcp_menu.set_item_checked(agent_mode_idx, SingletonObject.Chats.agent_mode_enabled)


## Toggle Agent Mode on/off
func _toggle_agent_mode() -> void:
	if not SingletonObject.Chats:
		SingletonObject.create_toast_notification("Chat pane not available", ToastNotification.Type.ERROR)
		return

	var new_state := not SingletonObject.Chats.agent_mode_enabled
	SingletonObject.Chats._on_agent_mode_toggled(new_state)

	if new_state:
		SingletonObject.create_toast_notification("Agent Mode enabled", ToastNotification.Type.SUCCESS)
	else:
		SingletonObject.create_toast_notification("Agent Mode disabled", ToastNotification.Type.WARNING)


## Create an image note from a blob reference
func _create_image_note_from_blob(note_title: String, value, nudge_client) -> Note:
	if not value is Dictionary:
		push_warning("Image note value is not a dictionary")
		return null

	var blob_id: String = value.get("blob_id", "")
	if blob_id.is_empty():
		push_warning("No blob_id in image note value")
		return null

	# Download the blob
	var blob_result: Dictionary = await nudge_client.blob_download(blob_id)
	if blob_result.get("error"):
		push_warning("Failed to download blob: %s" % blob_result.get("error"))
		return null

	var base64_data: String = blob_result.get("data", "")
	if base64_data.is_empty():
		push_warning("Blob data is empty")
		return null

	# Decode base64 to image
	var png_data: PackedByteArray = Marshalls.base64_to_raw(base64_data)
	var image := Image.new()
	var err := image.load_png_from_buffer(png_data)
	if err != OK:
		# Try loading as other formats
		err = image.load_jpg_from_buffer(png_data)
		if err != OK:
			err = image.load_webp_from_buffer(png_data)
			if err != OK:
				push_warning("Failed to load image from blob data")
				return null

	var caption: String = value.get("caption", "")
	return Note.create_image_note(note_title, image, caption)


## Update an existing image note from a blob reference
func _update_image_note_from_blob(note: Note, value, nudge_client) -> bool:
	if note.type != Note.Type.IMAGE:
		return false

	if not value is Dictionary:
		return false

	var blob_id: String = value.get("blob_id", "")
	if blob_id.is_empty():
		return false

	# Download the blob
	var blob_result: Dictionary = await nudge_client.blob_download(blob_id)
	if blob_result.get("error"):
		return false

	var base64_data: String = blob_result.get("data", "")
	if base64_data.is_empty():
		return false

	# Decode base64 to image
	var png_data: PackedByteArray = Marshalls.base64_to_raw(base64_data)
	var image := Image.new()
	var err := image.load_png_from_buffer(png_data)
	if err != OK:
		err = image.load_jpg_from_buffer(png_data)
		if err != OK:
			err = image.load_webp_from_buffer(png_data)
			if err != OK:
				return false

	# Update the image in the controls
	var controls = note.get_controls_container()
	if controls and "image" in controls:
		controls.image = image
		if "caption" in controls:
			controls.caption = value.get("caption", "")
		return true

	return false


## Create an audio note from a blob reference
func _create_audio_note_from_blob(note_title: String, value, nudge_client) -> Note:
	if not value is Dictionary:
		push_warning("Audio note value is not a dictionary")
		return null

	var blob_id: String = value.get("blob_id", "")
	if blob_id.is_empty():
		push_warning("No blob_id in audio note value")
		return null

	var content_type: String = value.get("content_type", "audio/wav")

	# Download the blob
	var blob_result: Dictionary = await nudge_client.blob_download(blob_id)
	if blob_result.get("error"):
		push_warning("Failed to download audio blob: %s" % blob_result.get("error"))
		return null

	var base64_data: String = blob_result.get("data", "")
	if base64_data.is_empty():
		push_warning("Audio blob data is empty")
		return null

	# Decode base64 to audio
	var audio_data: PackedByteArray = Marshalls.base64_to_raw(base64_data)
	var audio_stream: AudioStream

	match content_type:
		"audio/mpeg", "audio/mp3":
			audio_stream = AudioStreamMP3.new()
			audio_stream.data = audio_data
		"audio/ogg":
			audio_stream = AudioStreamOggVorbis.new()
			audio_stream.load_from_buffer(audio_data)
		"audio/wav", _:
			audio_stream = AudioStreamWAV.new()
			audio_stream.data = audio_data

	return Note.create_audio_note(note_title, audio_stream)


func _nudge_push_all_tabs() -> void:
	var notes_container: NotesContainer = SingletonObject.notes_container
	if notes_container.get_tab_count() == 0:
		SingletonObject.create_toast_notification("No tabs to push", ToastNotification.Type.WARNING)
		return

	var nudge_client := NudgeMCPClientScript.new()
	var total_success := 0
	var total_errors := 0
	var tabs_pushed := 0

	for tab_idx in notes_container.get_tab_count():
		var vbox: NoteVBox = notes_container.get_tab_control(tab_idx) as NoteVBox
		if not vbox:
			continue

		var notes := vbox.get_notes()
		if notes.is_empty():
			continue

		var component := vbox.name
		tabs_pushed += 1

		for note in notes:
			var result: Dictionary = await nudge_client.push_note_simple(note, component)
			if result.get("error"):
				total_errors += 1
				push_warning("Failed to push note '%s': %s" % [note.title, result.get("error")])
			else:
				total_success += 1

	if tabs_pushed == 0:
		SingletonObject.create_toast_notification("No notes to push", ToastNotification.Type.WARNING)
		return

	if total_errors > 0:
		SingletonObject.create_toast_notification(
			"Pushed %d notes from %d tabs (%d failed)" % [total_success, tabs_pushed, total_errors],
			ToastNotification.Type.WARNING
		)
	else:
		SingletonObject.create_toast_notification(
			"Pushed %d notes from %d tabs" % [total_success, tabs_pushed],
			ToastNotification.Type.SUCCESS
		)


func _nudge_delete_current_tab() -> void:
	var notes_container: NotesContainer = SingletonObject.notes_container
	if notes_container.get_tab_count() == 0:
		SingletonObject.create_toast_notification("No tabs", ToastNotification.Type.WARNING)
		return

	var current_vbox: NoteVBox = notes_container.get_current_tab_control() as NoteVBox
	if not current_vbox:
		SingletonObject.create_toast_notification("No active tab", ToastNotification.Type.WARNING)
		return

	var notes := current_vbox.get_notes()
	if notes.is_empty():
		SingletonObject.create_toast_notification("No notes in tab to delete from Nudge", ToastNotification.Type.WARNING)
		return

	var nudge_client := NudgeMCPClientScript.new()
	var component := current_vbox.name
	var success_count := 0
	var error_count := 0

	for note in notes:
		# Only delete if the note has a title (key in nudge)
		if note.title.is_empty():
			continue

		var result: Dictionary = await nudge_client.delete_hint(component, note.title)
		if result.get("error"):
			error_count += 1
			push_warning("Failed to delete '%s' from Nudge: %s" % [note.title, result.get("error")])
		else:
			success_count += 1
			# Clear the nudge metadata since it's no longer in nudge
			if note.has_meta("nudge_hint"):
				note.remove_meta("nudge_hint")

	if error_count > 0:
		SingletonObject.create_toast_notification(
			"Deleted %d hints from '%s' (%d failed)" % [success_count, component, error_count],
			ToastNotification.Type.WARNING
		)
	else:
		SingletonObject.create_toast_notification(
			"Deleted %d hints from '%s'" % [success_count, component],
			ToastNotification.Type.SUCCESS
		)


func _on_project_index_pressed(index):
	match index:
		0:
			## Create a new blank project
			SingletonObject.NewProject.emit()
			pass
		1:
			## Open a project
			SingletonObject.OpenProject.emit()
			pass
		2:
			## Save a project
			SingletonObject.SaveProject.emit() 
			pass
		3:
			## Save as a project
			SingletonObject.SaveProjectAs.emit()
			pass
		5:
			popUpRecent.visible = true
			load_recent_projects()
			#pass

func _on_view_id_pressed(id: int):
	# if zoom items are selected
	match id:
		4: SingletonObject.main_scene.zoom_ui(2); return
		5: SingletonObject.main_scene.zoom_ui(-2); return
		6: SingletonObject.main_scene.reset_zoom(); return
		8: _show_messages()
		9: _show_notes()
		11: SingletonObject.set_icon_size_24.emit(); return
		12: SingletonObject.set_icon_size_48.emit(); return
		13: SingletonObject.set_icon_size_68.emit(); return
		16: SingletonObject.increment_scale_ui()
		17: SingletonObject.decrement_ui_scale()
		18: SingletonObject.reset_ui_scale()
	var index = view.get_item_index(id)
	
	if view.is_item_checkable(index):
		view.toggle_item_checked(index)
	
	SingletonObject.main_ui.set_chat_pane_visible(view.is_item_checked(view.get_item_index(0)))
	SingletonObject.main_ui.set_editor_pane_visible(view.is_item_checked(view.get_item_index(1)))
	SingletonObject.main_ui.set_notes_pane_visible(view.is_item_checked(view.get_item_index(2)))
	SingletonObject.main_ui.set_terminal_pane_visible(view.is_item_checked(view.get_item_index(10)))

func _show_messages():
	for ch in SingletonObject.ChatList:
		for chi in ch.HistoryItemList:
			if not chi.Visible:
				chi.Visible = true
				chi.rendered_node.render()

func _show_notes():
	for i in range(SingletonObject.notes_container.get_tab_count()):
		SingletonObject.notes_container.show_notes(i)

func _on_view_about_to_popup():
	view.set_item_checked(0, SingletonObject.main_ui.chat_pane.visible)
	view.set_item_checked(1, SingletonObject.main_ui.editor_pane.visible)
	view.set_item_checked(2, SingletonObject.main_ui.notes_pane.visible)
	view.set_item_checked(view.get_item_index(10), SingletonObject.main_ui.terminal_pane.visible)

func _on_file_about_to_popup():
	#checks if current tabs exists and enables saving features if so
	if SingletonObject.is_editor_file_open():
		%File.set_item_disabled(2, false)
		%File.set_item_disabled(3, false)
	else: 
		%File.set_item_disabled(2, true)
		%File.set_item_disabled(3, true)

func _on_project_about_to_popup() -> void:
	#checks if current editor tabs, chat tabs or notes exists 
	#and enables saving features for their project if so
	if SingletonObject.any_project_features_open():
		%Project.set_item_disabled(2, false)
		%Project.set_item_disabled(3, false)
	else:
		%Project.set_item_disabled(2, true)
		%Project.set_item_disabled(3, true)

#this function gets call when the mouse ers over the MenuBar
#it has a timer so it doesn't execute all the time
var timer
var active: bool = true
func _on_mouse_entered() -> void:
	if active:
		active = false
		call_deferred("load_recent_projects_sub")
		_rebuild_recent_projects_ui()
		#add submenu fro button new edit
		
		timer = Timer.new()
		timer.wait_time = 5.0
		timer.timeout.connect(set_active)
		add_child(timer)
		timer.start()
		

func set_active():
	active = true
	timer.queue_free()

#load recent projects if they exist on the config file
#this function gets called on ready and when you hover over menuMain
var projects_size: int
func load_recent_projects():
	# Clear existing recent project entries in the UI more robustly
	for child in recentList.get_children():
		if child is HBoxContainer:
			child.queue_free()

	if SingletonObject.has_recent_projects():
		var recent_projects = SingletonObject.get_recent_projects()
		projects_size = recent_projects.size()

		if recent_projects:
			for i in range(projects_size):
				var item = recent_projects[i]
				_add_recent_project_ui(i, item)

func _add_recent_project_ui(index: int, item: String):

	var newRecentButtons = preload("res://Scenes/RecentPopUpButtons.tscn").instantiate() # Instantiate a NEW one each time
	
	newRecentButtons.set_meta("project_path", item)
	var RecentBtn = newRecentButtons.find_child("RecentBtn")
	var exitBtn = newRecentButtons.find_child("exitBtn")
	var _dragBtn = newRecentButtons.find_child("DragButton")
	# Limit the text length and add ellipsis if necessary
	newRecentButtons.name = item
	newRecentButtons.index = index
	var displayed_text = item
	#if displayed_text.length() > 16:
		#displayed_text = displayed_text.substr(0, 13) + "..."
	RecentBtn.text = displayed_text
	
	# Set a fixed size for the buttons (optional, but good practice)
	var button_size = Vector2(100, 25) 
	RecentBtn.size = button_size
	exitBtn.size = Vector2(25,25)


	RecentBtn.pressed.connect(_on_open_recent_project.bind(index, item))
	exitBtn.pressed.connect(_on_remove_recent_single.bind(newRecentButtons.get_meta("project_path")))

	recentList.add_child(newRecentButtons) # Add the *new instance* to the VboxContainer

# no idea why this has the index parameter added _ to it to avoid warning
func _on_open_recent_project(_index: int, itemText:String):
	# The "Clear Recent Projects" button should be handled separately, not within this function.  Add this logic to the PopupMenu where that button resides. 
	SingletonObject.OpenRecentProject.emit(itemText)
	popUpRecent.visible = false


func _on_remove_recent_single(index: String):
	SingletonObject.remove_recent_project(index) # Remove the project data
	_rebuild_recent_projects_ui()  # Update the UI
	load_recent_projects_sub()
	projects_size -= 1

func _rebuild_recent_projects_ui():
	var recent_projects = SingletonObject.get_recent_projects()
	var children = recentList.get_children()

	# 1. Remove buttons for projects no longer in the recent list
	for child in children:
		if child.has_meta("project_path") and child.get_meta("project_path") not in recent_projects:
			child.queue_free()

	children = recentList.get_children() # Update children after removal

	# 2. Add buttons for new projects
	for i in range(recent_projects.size()):
		var project_path = recent_projects[i]
		var existing_button = _find_existing_button(project_path, children)
		if !existing_button:
			_add_recent_project_ui(i, project_path)

	children = recentList.get_children() # Update children after adding

	# 3. Reorder existing buttons to match the recent_projects order
	for i in range(recent_projects.size()):
		var project_path = recent_projects[i]
		var button = _find_existing_button(project_path, children)
		if button:
			recentList.move_child(button, i)  # Move to the correct index


func _find_existing_button(project_path: String, children: Array) -> Node:
	for child in children:
		if child.has_meta("project_path") and child.get_meta("project_path") == project_path:
			return child
	return null
	
var submenu: PopupMenu
func load_recent_projects_sub():
	#if submenu: submenu.queue_free()
	if SingletonObject.has_recent_projects():
		# this if statement removes the open recent item if there was one already
		if project.get_tree().has_group("open_recent"):
			project.remove_item(project.item_count - 1)
		if project.get_tree().has_group("open_recent"):
			# Remove the old submenu entirely instead of individual items
			for n in project.get_children():
				if n is PopupMenu and n.is_in_group("open_recent"):
					n.free()  # or n.queue_free() if needed
					break  # Assume only one submenu in the group
					
		
		# create submenu item, fill it with recent projects and add to menu
		submenu = PopupMenu.new()
		submenu.name = "OpenRecentSubmenu"
		submenu.add_to_group("open_recent")
		submenu.index_pressed.connect(_on_open_recent_project_sub)
		var recent_projects = SingletonObject.get_recent_projects()
		projects_size = recent_projects.size()
		
		if recent_projects:
			submenu.get_children().clear()
			for item in recent_projects:
				submenu.add_item(item)
		
		submenu.add_separator()
		var clear_recent_item = "Clear recent Projects"
		submenu.add_item(clear_recent_item)
		
		var manager = "Manage..."
		submenu.add_item(manager)
		
		project.add_child(submenu)# adds submenu to scene tree
		#add submenu as a submenu of indicated item
		project.add_submenu_item("Open Recent", "OpenRecentSubmenu")
		
		

func _on_open_recent_project_sub(index: int):
	if projects_size + 1 == index: # check if the index is for the clear recent projects button
		SingletonObject.clear_recent_projects()
		project.remove_item(project.item_count - 1)
	elif projects_size + 2 == index:
		_rebuild_recent_projects_ui()
		popUpRecent.visible = true
	else:
		var selected_project_name = submenu.get_item_text(index)
		SingletonObject.OpenRecentProject.emit(selected_project_name)

func popUpClose():
	popUpRecent.visible = false

func _on_close_button_pressed() -> void:
	popUpRecent.visible = false

###
### End Reference Information ###
