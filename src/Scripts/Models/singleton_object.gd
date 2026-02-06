extends Node

#region global variables
# Suported video format MIME types by GoogleAI see: https://ai.google.dev/gemini-api/docs/vision?lang=python
var google_supported_video_formats: = { 
	"mp4": "video/mp4", 
	"mpeg": "video/mpeg", 
	"mov": "video/mov",
	"avi": "video/avi", 
	"x-flv": "video/x-flv", 
	"mpg":  "video/mpg",
	"webm": "video/webm",
	"wmv": "video/wmv",
	"3gpp": "video/3gpp"
}
# Suported audio format MIME types by GoogleAI see: https://ai.google.dev/gemini-api/docs/audio?lang=python
var google_supported_audio_formats: = { 
	"wav": "audio/wav",
	"mp3": "audio/mp3",
	"aiff": "audio/aiff",
	"aac": "audio/aac",
	"ogg": "audio/ogg",
	"flac": "audio/flac"
}

# this are the formats that we support in this app
var supported_image_formats: PackedStringArray = ["png", "jpg", "jpeg", "bmp", "svg", "webp"] # "gif", "tiff"
var supported_text_formats: PackedStringArray = ["txt", "rs", "toml", "md", "json", "xml", "csv", "log", "py", "cs", "minproj", "gd", "tscn", "godot", "go", "java"]
var supported_video_formats: PackedStringArray = ["mp4", "mov", "avi", "mkv", "webm", "ogv"]
var supported_audio_formats: PackedStringArray = ["mp3", "wav", "ogg"]

var experimental_enabled: bool = false
signal toggle_experimental(enabled)

## When enabled, prints verbose/debug logging (discovery data, service info, etc.)
var verbose_logging: bool = false
signal toggle_verbose_logging(enabled)

## Emitted when user requests to stop active AI/tool operations
## history_id: The HistoryId of the chat to stop, or empty string to stop all
@warning_ignore("unused_signal")
signal stop_all_requests(history_id: String)

## Emitted when a provider's enabled state changes - UI should refresh model lists
signal provider_enabled_changed(provider: API_PROVIDER, enabled: bool)

## History IDs that have been cancelled - check and remove when acting on cancellation
var cancelled_history_ids: Array[String] = []

## Check if a history_id has been cancelled without clearing it (for repeated checks in loops)
func is_cancelled(history_id: String) -> bool:
	return history_id in cancelled_history_ids

## Clear the cancelled state for a history_id (call when cancellation is fully handled)
func clear_cancelled(history_id: String) -> void:
	var idx := cancelled_history_ids.find(history_id)
	if idx >= 0:
		cancelled_history_ids.remove_at(idx)

## Helper for verbose logging - only prints if verbose_logging is enabled
func verbose_log(message: String) -> void:
	if verbose_logging:
		print(message)

var syntax_manager: SyntaxManager

# used by the old editor.
# TODO: clean up at some point properly
var is_graph:bool = false
var is_masking:bool
var is_picture:bool = false
#this is where we save the last path used to save a file or project
var last_saved_path: String

var CloudType

var is_brush
var is_square
var is_crayon
var is_marker
#endregion global variables

var GEN_AI_HIST_FILE_PATH: = "user://gen_ai_history.csv"

#region Config File
var _config_file_name: String = "user://config_file.cfg"
var config_file = ConfigFile.new()

func load_config_file() -> ConfigFile:
	var err = config_file.load(_config_file_name)
	if err != OK:
		return null
	else: 
		return config_file

# use this method to save any settings to the file
func save_to_config_file(section: String, field: String, value):
	#config_file.get_sections()
	#config_file = load_config_file()
	config_file.set_value(section, field, value)
	config_file.save(_config_file_name)
	

func config_has_saved_section(section: String) -> bool:
	if !section: return false
	return config_file.has_section(section)


func get_config_file_value(section: String, field: String) -> Variant:
	if config_has_saved_section(section) and config_file.has_section_key(section, field):
		return config_file.get_value(section, field)
	return null


func config_clear_section(section: String)-> void:
	if !section: return
	
	config_file.erase_section(section)
	config_file.save(_config_file_name)


#method for checking if the user has saved files
func has_recent_projects() -> bool:
	
	return config_file.has_section("OpenRecent")

#method for adding the project to the open recent list
func save_recent_project(path: String):
	var path_split = path.split("/")
	var project_name_index: int = path_split.size() - 1
	var project_name = path_split[project_name_index]
	
	save_to_config_file("OpenRecent",project_name, path)

# this function returns an array with the files 
# names of the recent project saved in config file
func get_recent_projects() -> Array:
	if has_recent_projects():
		return config_file.get_section_keys("OpenRecent")
	return ["no recent projects"]

# method for getting the p0ath on disk of the specified project file
func get_project_path(project_name: String) -> String:
	
	return config_file.get_value("OpenRecent", project_name)

# method for erasing all the recently opened projects
func clear_recent_projects() -> void:
	config_file.erase_section("OpenRecent")
	config_file.save(_config_file_name)

func remove_recent_project(project_name: String) -> void:
	if !has_recent_projects():
		return

	if !config_file.has_section_key("OpenRecent", project_name):
		printerr("Project '" + project_name + "' not found in recent projects.")
		return

	config_file.erase_section_key("OpenRecent", project_name)
	config_file.save(_config_file_name)


#region Autocoder Session Source Directory Storage

const AUTOCODER_SESSIONS_SECTION = "AutocoderSessions"

## Save the source directory path associated with an autocoder session
func save_session_source_dir(session_id: String, source_dir: String) -> void:
	if session_id.is_empty():
		return
	save_to_config_file(AUTOCODER_SESSIONS_SECTION, session_id, source_dir)

## Get the source directory path for an autocoder session
func get_session_source_dir(session_id: String) -> String:
	if session_id.is_empty():
		return ""
	if not has_session_source_dir(session_id):
		return ""
	var value = config_file.get_value(AUTOCODER_SESSIONS_SECTION, session_id, "")
	return value if value is String else ""

## Check if a session has a stored source directory
func has_session_source_dir(session_id: String) -> bool:
	if session_id.is_empty():
		return false
	return config_file.has_section_key(AUTOCODER_SESSIONS_SECTION, session_id)

## Remove the source directory mapping for a session
func remove_session_source_dir(session_id: String) -> void:
	if session_id.is_empty():
		return
	if config_file.has_section_key(AUTOCODER_SESSIONS_SECTION, session_id):
		config_file.erase_section_key(AUTOCODER_SESSIONS_SECTION, session_id)
		config_file.save(_config_file_name)

## Get all stored session source directories (returns Dictionary[session_id] = source_dir)
func get_all_session_source_dirs() -> Dictionary:
	var result: Dictionary = {}
	if config_file.has_section(AUTOCODER_SESSIONS_SECTION):
		for key in config_file.get_section_keys(AUTOCODER_SESSIONS_SECTION):
			result[key] = config_file.get_value(AUTOCODER_SESSIONS_SECTION, key)
	return result

#endregion Autocoder Session Source Directory Storage

#endregion Config File


var _registered_objects: Dictionary[Variant, Object] = {}

## Registers an objects by mapping it [param field_name] value to it
## so even after the project has been reopened the correct object can be found.[br]
## If an object is already registered with the same value,
## nothing happens and `false` is returned.[br]
## Example of registering a [class Note] object so editor can associate with it
## even after reopening the project:
## [codeblock]
## 	SingletonObject.register_object(self, &"uuid")
## 	...
##	# to get the object:
## 	SingletonObject.get_registered_object(uuid)
## [/codeblock]
## Returns `true` on success.
func register_object(object: Object, field_name: StringName) -> bool:

	var field_value = object.get(field_name)

	if field_value == null:
		push_error("Can't register object %s. Field %s is null." % [object, field_name])
		return false

	# Object with same value already exists
	if field_value in _registered_objects.keys():
		return false

	_registered_objects[field_value] = object

	print("Registerd object %s under the value %s" % [object, field_value])

	return true

## Returns the object that has been registered using the [method register_object]
## if the object is not `null` and [method is_instance_valid] returns `true`.
func get_registered_object(value: Variant) -> Object:
	prints("get_registered_object:", value)
	var object = _registered_objects.get(value)

	if object == null or not is_instance_valid(object):
		# unregister object since it's not valid anymore
		_registered_objects.erase(value)
		return null

	return object

## Removes the [param value] key from registered object.[br]
## Uses `Array.erase` to remove the object and
## returns whether the object existed before this operation.
func remove_registered_object(value: Variant) -> bool:
	return _registered_objects.erase(value)
	
## Clears all registered objects.[br]
## Primary use at project close.
func clear_registered_objects():
	print("Clearing registered object")
	_registered_objects.clear()

## Given the object, tries to find the uuid for that object
## if it's registered. Returns `null` if object is not found.[br]
## Eg. Editor serialization tries to get the [member Editor.associated_object]
## and save it so that on the next load it can find the associated object again.
## The Note must register itself with the uuid field for this to work.
func registered_object_get_uuid(object: Object):
	for key in _registered_objects.keys():
		if _registered_objects[key] == object:
			prints("Found registered object", key, object)
			return key
	
	return null

#region Notes

## Manages relations between [class Note] objects and core note services
var notes_sync_manger: = NoteSyncManager.new()

var notes_container: NotesContainer
var drawer_notes_container: NotesContainer

## Notes that don't reside inside any thread. eg. Editor and terminal notes
var detached_note_proxies: Array[Note.Proxy]

enum note_type {
	TEXT,
	AUDIO, 
	IMAGE,
	VIDEO,
	BINARY
}

enum NotesDrawState {
	UNSET,
	DRAWING,
}

# this signals get used in memoryTabs.gd and new_thread_popup.gd 
# for creating and updating notes tabs names
@warning_ignore("unused_signal")
signal create_notes_tab(name: String)
@warning_ignore("unused_signal")
signal associated_notes_tab(tab_name, tab: Control)
@warning_ignore("unused_signal")
signal pop_up_new_tab
@warning_ignore("unused_signal")
signal pop_up_new_drawer_tab #it's made for fast fix of double open window when dopuble click on tab for rename. it'll be remove after i'll move drawer to Main scene
@warning_ignore("unused_signal")
signal notes_draw_state_changed(state: int)
@warning_ignore("unused_signal")
signal create_drawer_tab

var notes_draw_state: int


@warning_ignore("unused_signal")
signal AttachNoteFile(file_path:String)

## Emitted by `vboxMemoryList` when a note is toggled on/off.[br]
@warning_ignore("unused_signal")
signal note_toggled(note: Note, on: bool)
## Emitted by `vboxMemoryList` when a note has been changed.[br]
@warning_ignore("unused_signal")
signal note_changed(note: Note)

func toggle_all_notes(notes_enabled: bool):
	for i in SingletonObject.notes_container.get_tab_count():
		(SingletonObject.notes_container.enable_notes if notes_enabled else SingletonObject.notes_container.disable_notes).call(i)
	
	for i in SingletonObject.drawer_notes_container.get_tab_count():
		(SingletonObject.drawer_notes_container.enable_notes if notes_enabled else SingletonObject.drawer_notes_container.disable_notes).call(i)

## Tries to find the [class NoteVbox] object that the [param note] resides in.[br]
## returns `null` if not found.
func find_notes_vbox_parent(note: Note) -> NoteVBox:
	var tab_idx: int

	tab_idx = SingletonObject.notes_container.find_note(note)
	if tab_idx != -1:
		return SingletonObject.notes_container.get_tab_control(tab_idx)
	
	tab_idx = SingletonObject.drawer_notes_container.find_note(note)
	if tab_idx != -1:
		return SingletonObject.drawer_notes_container.get_tab_control(tab_idx)

	return null

#endregion Notes

#region Autocoder

var autocoder_manager: AutocodeManager

#endregion Autocoder

#region MCP

const MCPManagerScript := preload("res://Scripts/Services/MCP/MCPManager.gd")
const CoBrowserMCPClientScript := preload("res://Scripts/Services/MCP/Servers/CoBrowserMCPClient.gd")

## Manager for MCP (Model Context Protocol) server connections
var mcp_manager: Node = null

## Co-Browser client for browser automation
var cobrowser_client: RefCounted = null

## MCP HTTP Server settings - allows external agents to connect to Minerva
var mcp_http_server_port: int = 9315:
	set(value):
		mcp_http_server_port = clampi(value, 1024, 65535)
		save_to_config_file("MCPServer", "http_port", mcp_http_server_port)
	get:
		if mcp_http_server_port <= 0:
			var saved = get_config_file_value("MCPServer", "http_port")
			mcp_http_server_port = saved if saved != null and saved > 0 else 9315
		return mcp_http_server_port

var mcp_http_server_auto_start: bool = false:
	set(value):
		mcp_http_server_auto_start = value
		save_to_config_file("MCPServer", "auto_start", value)
	get:
		var saved = get_config_file_value("MCPServer", "auto_start")
		if saved != null:
			if saved is bool:
				mcp_http_server_auto_start = saved
			else:
				mcp_http_server_auto_start = str(saved).to_lower() == "true"
		return mcp_http_server_auto_start

## Initialize MCP manager (call from main scene _ready)
func initialize_mcp() -> void:
	if mcp_manager:
		return
	mcp_manager = MCPManagerScript.new()
	add_child(mcp_manager)
	await mcp_manager.initialize()

	# Auto-start HTTP server if configured
	if mcp_http_server_auto_start:
		var err = mcp_manager.start_http_server(mcp_http_server_port)
		if err == OK:
			print("[MCP] HTTP server auto-started on port %d" % mcp_http_server_port)
		else:
			push_warning("[MCP] Failed to auto-start HTTP server: %s" % error_string(err))

## Initialize Co-Browser client (call when needed)
func get_cobrowser_client() -> RefCounted:
	if not cobrowser_client:
		cobrowser_client = CoBrowserMCPClientScript.new()
	return cobrowser_client

## Check if Co-Browser is available
func is_cobrowser_available() -> bool:
	var client = get_cobrowser_client()
	return await client.has_active_session()


## Get the MCP manager instance (lazy initialization)
func get_mcp_manager() -> Node:
	if not mcp_manager:
		mcp_manager = MCPManagerScript.new()
		add_child(mcp_manager)
	return mcp_manager


## Start the MCP HTTP server for external agent access
func start_mcp_http_server(port: int = -1) -> Error:
	if port < 0:
		port = mcp_http_server_port
	return get_mcp_manager().start_http_server(port)


## Stop the MCP HTTP server
func stop_mcp_http_server() -> void:
	if mcp_manager:
		mcp_manager.stop_http_server()


## Check if the MCP HTTP server is running
func is_mcp_http_server_running() -> bool:
	return mcp_manager != null and mcp_manager.is_http_server_running()

#endregion MCP

#region Image Generation Settings

## Maximum iterations allowed for iterative image generation in agentic mode
var max_image_iterations: int = 3:
	set(value):
		max_image_iterations = clampi(value, 1, 20)
		save_to_config_file("ImageGeneration", "max_image_iterations", max_image_iterations)
	get:
		if max_image_iterations <= 0:
			var saved = get_config_file_value("ImageGeneration", "max_image_iterations")
			max_image_iterations = saved if saved != null and saved > 0 else 3
		return max_image_iterations

## Nano Banana Pro (Google Image) settings
var nbp_google_search_enabled: bool = false:
	set(value):
		nbp_google_search_enabled = value
		save_to_config_file("NanoBananaPro", "google_search_enabled", value)
	get:
		var saved = get_config_file_value("NanoBananaPro", "google_search_enabled")
		if saved != null:
			if saved is bool:
				nbp_google_search_enabled = saved
			else:
				nbp_google_search_enabled = str(saved).to_lower() == "true"
		return nbp_google_search_enabled

var nbp_aspect_ratio: String = "1:1":
	set(value):
		nbp_aspect_ratio = value
		save_to_config_file("NanoBananaPro", "aspect_ratio", value)
	get:
		var saved = get_config_file_value("NanoBananaPro", "aspect_ratio")
		if saved != null and not saved.is_empty():
			nbp_aspect_ratio = saved
		return nbp_aspect_ratio

var nbp_image_size: String = "1K":
	set(value):
		nbp_image_size = value
		save_to_config_file("NanoBananaPro", "image_size", value)
	get:
		var saved = get_config_file_value("NanoBananaPro", "image_size")
		if saved != null and not saved.is_empty():
			nbp_image_size = saved
		return nbp_image_size

## Model-chat (Ollama) context window size
var model_chat_num_ctx: int = 40000:
	set(value):
		model_chat_num_ctx = value
		save_to_config_file("ModelChat", "num_ctx", value)
	get:
		var saved = get_config_file_value("ModelChat", "num_ctx")
		if saved != null and saved is int and saved > 0:
			model_chat_num_ctx = saved
		return model_chat_num_ctx

#endregion Image Generation Settings

#region Per-Model Settings (Timeout & Context)

## Per-model timeout overrides (seconds). 0 = use provider default.
## Keys are model names (e.g., "gpt-5.2", "model-chat (glm-4.7-flash)")
var _model_timeouts: Dictionary = {}

## Per-model context window overrides. 0 = use default.
## Keys are model names
var _model_contexts: Dictionary = {}

## Get the timeout override for a model (0 means use default)
func get_model_timeout(model_name: String) -> float:
	# Load from config if not loaded yet
	if _model_timeouts.is_empty():
		var saved = get_config_file_value("Models", "Timeouts")
		if saved and saved is Dictionary:
			_model_timeouts = saved
	return _model_timeouts.get(model_name, 0.0)

## Set the timeout override for a model
func set_model_timeout(model_name: String, timeout: float) -> void:
	if timeout <= 0:
		_model_timeouts.erase(model_name)
	else:
		_model_timeouts[model_name] = timeout
	save_to_config_file("Models", "Timeouts", _model_timeouts)

## Get the context window override for a model (0 means use default)
func get_model_context(model_name: String) -> int:
	# Load from config if not loaded yet
	if _model_contexts.is_empty():
		var saved = get_config_file_value("Models", "Contexts")
		if saved and saved is Dictionary:
			_model_contexts = saved
	return _model_contexts.get(model_name, 0)

## Set the context window override for a model
func set_model_context(model_name: String, context: int) -> void:
	if context <= 0:
		_model_contexts.erase(model_name)
	else:
		_model_contexts[model_name] = context
	save_to_config_file("Models", "Contexts", _model_contexts)

## Per-model GPU layer overrides. -1 = use default, 0 = CPU only, N = N layers on GPU
var _model_num_gpu: Dictionary = {}

## Get the num_gpu override for a model (-1 means use default)
func get_model_num_gpu(model_name: String) -> int:
	# Load from config if not loaded yet
	if _model_num_gpu.is_empty():
		var saved = get_config_file_value("Models", "NumGpu")
		if saved and saved is Dictionary:
			_model_num_gpu = saved
	return _model_num_gpu.get(model_name, -1)

## Set the num_gpu override for a model
func set_model_num_gpu(model_name: String, num_gpu: int) -> void:
	if num_gpu < 0:
		_model_num_gpu.erase(model_name)
	else:
		_model_num_gpu[model_name] = num_gpu
	save_to_config_file("Models", "NumGpu", _model_num_gpu)

#endregion Per-Model Settings

#region Chats
@warning_ignore("unused_signal")
signal chat_completed(response: BotResponse)
var current_message: MessageMarkdown = null

var ChatList: Array[ChatHistory]
var NotesList: Array[NotesServiceHistory]

var last_thread_index: int
var last_tab_index: int
# var active_chatindex: int just use Chats.current_tab
# var Provider: BaseProvider
var Chats: ChatPane
var Notes: NotesPane

var chat: Chat

#Add undo to use it through the singleton
var undo: undoMain = undoMain.new()
#Add AtT to use it through the singleton
var AtT: AudioToTexts = AudioToTexts.new()

#region UI Scaling
var initial_ui_scale: float = 1.0
var min_ui_scale: float = 0.5
var max_ui_scale: float = 2.5
var scaling_factor: float = 0.04

func increment_scale_ui() -> void:
	var ui_scale: float = get_tree().root.content_scale_factor
	if ui_scale < max_ui_scale:
		var new_scale: float = minf(ui_scale + scaling_factor, max_ui_scale)
		get_tree().root.content_scale_factor = new_scale
		_save_ui_scale(new_scale)
		main_scene.queue_redraw()


func decrement_ui_scale() -> void:
	var ui_scale: float = get_tree().root.content_scale_factor
	if ui_scale > min_ui_scale:
		var new_scale: float = maxf(ui_scale - scaling_factor, min_ui_scale)
		get_tree().root.content_scale_factor = new_scale
		_save_ui_scale(new_scale)
		main_scene.queue_redraw()


func reset_ui_scale() -> void:
	get_tree().root.content_scale_factor = 1.0
	_save_ui_scale(1.0)
	main_scene.queue_redraw()


func set_ui_scale(new_scale: float) -> void:
	if new_scale >= min_ui_scale and new_scale <= max_ui_scale:
		get_tree().root.content_scale_factor = new_scale
		_save_ui_scale(new_scale)
		main_scene.queue_redraw()


func _save_ui_scale(scale: float) -> void:
	save_to_config_file("UI", "scale", scale)


func _load_ui_scale() -> void:
	var saved_scale: float = config_file.get_value("UI", "scale", 1.0)
	if saved_scale >= min_ui_scale and saved_scale <= max_ui_scale:
		get_tree().root.content_scale_factor = saved_scale

#endregion UI Scaling

func _ready():
	SingletonObject.notes_draw_state_changed.connect(
		func(state: int):
			notes_draw_state = state
	)
	
	add_child(AtT)
	add_child(undo)
	supported_text_formats.sort()
	# this is for when you toggle experimental features
	toggle_experimental.connect(toggle_experimental_actions)
	terminal_input_event = InputMap.action_get_events("ui_terminal")
	output_device_changed.connect(set_output_device)
	
	# Here we create, load and add the audioPlayer for the notification sound on bot response
	chat_notification_player = AudioStreamPlayer.new()
	chat_notification_player.stream = load("res://assets/Audio/notification-new.mp3")
	chat_notification_player.bus = "AudioNotesBus"
	chat_notification_player.volume_db = 12
	get_tree().root.call_deferred("add_child", chat_notification_player)
	
	# Here we create, load and add the audioPlayer for the notification sound on bot response
	transcription_notification_player = AudioStreamPlayer.new()
	transcription_notification_player.stream = load("res://assets/Audio/transcription_sound.mp3")
	transcription_notification_player.bus = "AudioNotesBus"
	transcription_notification_player.volume_db = 12
	get_tree().root.call_deferred("add_child", transcription_notification_player)

	var err = config_file.load(_config_file_name)
	if err != OK:
		return null

	# Initialize enabled providers from config (must be after config_file.load)
	_init_enabled_providers()

	# Load UI scale from config
	_load_ui_scale()

	var theme_enum = get_theme_enum()
	if theme_enum > -1:
		set_theme(theme_enum)
	
	if config_has_saved_section("LastSavedPath"):
		last_saved_path = config_file.get_section_keys("LastSavedPath")[0]
	else:
		last_saved_path = "/"
	
	var mic_selected = get_microphone()
	if mic_selected:
		set_microphone(mic_selected)
	
	set_output_device(get_output_device())
	
	toggle_experimental_actions(config_file.get_value("Experimental","enabled",false))

	# Load verbose logging setting
	set_verbose_logging(config_file.get_value("Logging", "verbose", false))

	syntax_manager = SyntaxManager.new()
	add_child(syntax_manager)

	# Initialize MCP manager (connects to Nudge, etc.)
	# Defer to avoid add_child errors during scene tree setup
	initialize_mcp.call_deferred()


## Recursively release all textures in a node tree to prevent RID leaks on exit
func _release_textures_recursive(node: Node) -> void:
	if not is_instance_valid(node):
		return
	# Release texture if this is a TextureRect
	if node is TextureRect and node.texture:
		node.texture = null
	# Release texture if this is a Sprite2D
	if node is Sprite2D and node.texture:
		node.texture = null
	# Release icon if this is a BaseButton (Button, etc.)
	if node is BaseButton and node.icon:
		node.icon = null
	# Null out SubViewportContainer to break viewport texture references
	if node is SubViewportContainer:
		node.stretch = false
	# Recurse into children
	for child in node.get_children():
		_release_textures_recursive(child)


func _exit_tree() -> void:
	# Ensure proper cleanup order during shutdown
	print("[SingletonObject] Cleaning up...")

	# Release all textures in notes container before freeing nodes
	if notes_container and is_instance_valid(notes_container):
		print("[SingletonObject] Releasing textures in notes...")
		_release_textures_recursive(notes_container)

	# Release all textures in chat pane before freeing nodes
	if Chats and is_instance_valid(Chats):
		print("[SingletonObject] Releasing textures in chats...")
		_release_textures_recursive(Chats)

	# Release all textures in editor container before freeing nodes
	if editor_container and is_instance_valid(editor_container):
		print("[SingletonObject] Releasing textures in editor...")
		_release_textures_recursive(editor_container)

	# Force RenderingServer to release pending resources
	RenderingServer.force_sync()

	# Clear registered objects (notes, etc.)
	clear_registered_objects()

	print("[SingletonObject] Cleanup complete")


var chat_notification_player: AudioStreamPlayer
var transcription_notification_player: AudioStreamPlayer
func initialize_chats(_chats: ChatPane, chat_histories: Array[ChatHistory] = []):
	ChatList = chat_histories
	Chats = _chats
	Chats.clear_all_chats()
	
	# last_tab_index = 0
	# active_chatindex = 0

	for ch in chat_histories:
		Chats.render_history(ch)

#endregion Chats

#region Editor

@onready var editor_container: EditorContainer = $"/root/RootControl/VBoxRoot/VSplitContainer/MainUI/HSplitContainer/HSplitContainer2/MiddlePane/VBoxContainer/vboxEditorMain"
@onready var editor_pane: EditorPane = editor_container.editor_pane if editor_container else null
var editors: Array[Editor]
var Is_code_completed:bool = true
#endregion

#region Common UI Tasks

@onready var main_ui = $"/root/RootControl/VBoxRoot/VSplitContainer/MainUI"

###
# Create a common error display system that will popup an error and show
# and show the message
var errorPopup: PersistentWindow
var errorTitle: Label
var errorText: Label
func ErrorDisplay(error_title:String, error_message: String, on_close_focus: Node = null):
	errorTitle.text = error_title
	errorText.text = error_message
	errorPopup.popup_centered()

	if on_close_focus and on_close_focus.has_method("grab_focus"):
		errorPopup.close_requested.connect(func(): on_close_focus.grab_focus())

func create_toast_notification(content: String, type: = ToastNotification.Type.INFO):
	# Also log to console for debugging
	match type:
		ToastNotification.Type.ERROR:
			push_error("[Toast] %s" % content)
		ToastNotification.Type.WARNING:
			push_warning("[Toast] %s" % content)
		_:
			print("[Toast] %s" % content)

	var toast: = ToastNotification.create(type, content)

	main_scene.add_child(toast)



@onready var main_scene = $"/root/RootControl"

#endregion Common UI Tasks

#region API Consumer
enum API_PROVIDER { GOOGLE, OPENAI, ANTHROPIC, LOCAL, TURNROCK, OPENROUTER, CLAUDE_CODE }

# Preload provider scripts to ensure class_names are available
const OpenAIProviderScript = preload("res://Scripts/Services/Providers/OpenAI/OpenAIProvider.gd")
const OpenAIImageProviderScript = preload("res://Scripts/Services/Providers/OpenAI/OpenAIImageProvider.gd")
const GoogleProviderScript = preload("res://Scripts/Services/Providers/GoogleAi/GoogleProvider.gd")
const GoogleImageProviderScript = preload("res://Scripts/Services/Providers/GoogleAi/GoogleImageProvider.gd")
const AnthropicProviderScript = preload("res://Scripts/Services/Providers/Anthropic/AnthropicProvider.gd")
const OpenRouterProviderScript = preload("res://Scripts/Services/Providers/OpenRouter/OpenRouterProvider.gd")
const ClaudeCodeProviderScript = preload("res://Scripts/Services/Providers/ClaudeCode/ClaudeCodeProvider.gd")
const LocalProviderScript = preload("res://Scripts/Services/Providers/LocalProvider.gd")

# changing the order here will probably result in having wrong provider selected
# in AISettings, as it relies on this enum to load the provider script, but not a big deal
enum API_MODEL_PROVIDERS {
	HUMAN,
	# Local/Ollama
	NEMOTRON_NANO,
	DEVSTRAL_SMALL,
	# OpenAI Chat
	GPT_NANO,
	GPT_STANDARD,
	GPT_DEEP,
	# OpenAI Images
	GPT_IMAGE_15,
	# Google Chat
	GEMINI_FLASH,
	GEMINI_PRO,
	# Google Images
	NANO_BANANA_PRO,
	# Anthropic
	CLAUDE_HAIKU,
	CLAUDE_SONNET,
	CLAUDE_OPUS,
	# TurnRock
	TURNROCK,
	# OpenRouter
	OPENROUTER_GLM47,
	OPENROUTER_MINIMAX_M21,
	OPENROUTER_KIMI_K25,
	OPENROUTER_GROK41_FAST,
	# Claude Code (Max/Pro)
	CLAUDE_CODE_SONNET,
	CLAUDE_CODE_OPUS,
}

## Dictionary of all model providers and scripts that implement their functionality
var API_MODEL_PROVIDER_SCRIPTS: = {
	API_MODEL_PROVIDERS.HUMAN: HumanProvider,
	# Local/Ollama
	API_MODEL_PROVIDERS.NEMOTRON_NANO: LocalProviderScript,
	API_MODEL_PROVIDERS.DEVSTRAL_SMALL: LocalProviderScript.DevstralSmall2,
	# OpenAI Chat - GPT-5.2 with different reasoning levels
	API_MODEL_PROVIDERS.GPT_NANO: OpenAIProviderScript.Nano,
	API_MODEL_PROVIDERS.GPT_STANDARD: OpenAIProviderScript.Standard,
	API_MODEL_PROVIDERS.GPT_DEEP: OpenAIProviderScript.Deep,
	# OpenAI Images
	API_MODEL_PROVIDERS.GPT_IMAGE_15: OpenAIImageProviderScript.GPTImage15,
	# Google Chat - Gemini 3
	API_MODEL_PROVIDERS.GEMINI_FLASH: GoogleProviderScript.Flash,
	API_MODEL_PROVIDERS.GEMINI_PRO: GoogleProviderScript.Pro,
	# Google Images
	API_MODEL_PROVIDERS.NANO_BANANA_PRO: GoogleImageProviderScript.NanaBananaPro,
	# Anthropic - Claude 4.5
	API_MODEL_PROVIDERS.CLAUDE_HAIKU: AnthropicProviderScript.Haiku,
	API_MODEL_PROVIDERS.CLAUDE_SONNET: AnthropicProviderScript.Sonnet,
	API_MODEL_PROVIDERS.CLAUDE_OPUS: AnthropicProviderScript.Opus,
	# TurnRock
	API_MODEL_PROVIDERS.TURNROCK: CoreProvider,
	# OpenRouter
	API_MODEL_PROVIDERS.OPENROUTER_GLM47: OpenRouterProviderScript.GLM47,
	API_MODEL_PROVIDERS.OPENROUTER_MINIMAX_M21: OpenRouterProviderScript.MinimaxM21,
	API_MODEL_PROVIDERS.OPENROUTER_KIMI_K25: OpenRouterProviderScript.KimiK25,
	API_MODEL_PROVIDERS.OPENROUTER_GROK41_FAST: OpenRouterProviderScript.Grok41Fast,
	# Claude Code (Max/Pro)
	API_MODEL_PROVIDERS.CLAUDE_CODE_SONNET: ClaudeCodeProviderScript.Sonnet,
	API_MODEL_PROVIDERS.CLAUDE_CODE_OPUS: ClaudeCodeProviderScript.Opus,
}

## Maps each model to its parent provider (for enable/disable filtering)
const MODEL_TO_PROVIDER: Dictionary = {
	API_MODEL_PROVIDERS.HUMAN: API_PROVIDER.LOCAL,
	# Local/Ollama
	API_MODEL_PROVIDERS.NEMOTRON_NANO: API_PROVIDER.LOCAL,
	API_MODEL_PROVIDERS.DEVSTRAL_SMALL: API_PROVIDER.LOCAL,
	# OpenAI
	API_MODEL_PROVIDERS.GPT_NANO: API_PROVIDER.OPENAI,
	API_MODEL_PROVIDERS.GPT_STANDARD: API_PROVIDER.OPENAI,
	API_MODEL_PROVIDERS.GPT_DEEP: API_PROVIDER.OPENAI,
	API_MODEL_PROVIDERS.GPT_IMAGE_15: API_PROVIDER.OPENAI,
	# Google
	API_MODEL_PROVIDERS.GEMINI_FLASH: API_PROVIDER.GOOGLE,
	API_MODEL_PROVIDERS.GEMINI_PRO: API_PROVIDER.GOOGLE,
	API_MODEL_PROVIDERS.NANO_BANANA_PRO: API_PROVIDER.GOOGLE,
	# Anthropic
	API_MODEL_PROVIDERS.CLAUDE_HAIKU: API_PROVIDER.ANTHROPIC,
	API_MODEL_PROVIDERS.CLAUDE_SONNET: API_PROVIDER.ANTHROPIC,
	API_MODEL_PROVIDERS.CLAUDE_OPUS: API_PROVIDER.ANTHROPIC,
	# TurnRock
	API_MODEL_PROVIDERS.TURNROCK: API_PROVIDER.TURNROCK,
	# OpenRouter
	API_MODEL_PROVIDERS.OPENROUTER_GLM47: API_PROVIDER.OPENROUTER,
	API_MODEL_PROVIDERS.OPENROUTER_MINIMAX_M21: API_PROVIDER.OPENROUTER,
	API_MODEL_PROVIDERS.OPENROUTER_KIMI_K25: API_PROVIDER.OPENROUTER,
	API_MODEL_PROVIDERS.OPENROUTER_GROK41_FAST: API_PROVIDER.OPENROUTER,
	# Claude Code
	API_MODEL_PROVIDERS.CLAUDE_CODE_SONNET: API_PROVIDER.CLAUDE_CODE,
	API_MODEL_PROVIDERS.CLAUDE_CODE_OPUS: API_PROVIDER.CLAUDE_CODE,
}

## User-friendly names for providers (used in menu)
const PROVIDER_DISPLAY_NAMES: Dictionary = {
	API_PROVIDER.GOOGLE: "Google",
	API_PROVIDER.OPENAI: "OpenAI",
	API_PROVIDER.ANTHROPIC: "Anthropic",
	API_PROVIDER.LOCAL: "Local",
	API_PROVIDER.TURNROCK: "TurnRock",
	API_PROVIDER.OPENROUTER: "OpenRouter",
	API_PROVIDER.CLAUDE_CODE: "Claude Code",
}

## Enabled state for each provider (all enabled by default)
var _enabled_providers: Dictionary = {}

## Initialize enabled providers from config or defaults
func _init_enabled_providers() -> void:
	# Default all providers to enabled
	for provider in API_PROVIDER.values():
		_enabled_providers[provider] = true

	# Load saved state from config
	if config_has_saved_section("EnabledProviders"):
		for provider in API_PROVIDER.values():
			var provider_name = API_PROVIDER.keys()[provider]
			var saved = get_config_file_value("EnabledProviders", provider_name)
			if saved != null:
				_enabled_providers[provider] = saved

## Check if a provider is enabled
func is_provider_enabled(provider: API_PROVIDER) -> bool:
	return _enabled_providers.get(provider, true)

## Check if a model's provider is enabled
func is_model_enabled(model: API_MODEL_PROVIDERS) -> bool:
	var provider = MODEL_TO_PROVIDER.get(model, API_PROVIDER.LOCAL)
	return is_provider_enabled(provider)

## Set a provider's enabled state
func set_provider_enabled(provider: API_PROVIDER, enabled: bool) -> void:
	_enabled_providers[provider] = enabled
	var provider_name = API_PROVIDER.keys()[provider]
	save_to_config_file("EnabledProviders", provider_name, enabled)
	provider_enabled_changed.emit(provider, enabled)

## Get display name for a provider
func get_provider_display_name(provider: API_PROVIDER) -> String:
	return PROVIDER_DISPLAY_NAMES.get(provider, "Unknown")

## Model name aliases for backward compatibility with saved projects
const MODEL_ALIASES: Dictionary = {
	# Old OpenAI names -> New
	"gpt-5-thinking": "gpt-5.2",
	"gpt-5": "gpt-5.2",
	"o4-mini-medium": "gpt-5.2",
	"o4-mini-high": "gpt-5.2",
	"gpt-4o": "gpt-5.2",
	"gpt-3.5-turbo": "gpt-5.2",
	"o3": "gpt-5.2",
	# Old Google names -> New
	"gemini-2.5-flash": "gemini-3-flash-preview",
	"gemini-3-flash": "gemini-3-flash-preview",
	# Old Anthropic names -> New
	"claude-45-sonnet": "claude-sonnet-4.5",
	"claude-sonnet-45": "claude-sonnet-4.5",
	"claude-sonnet-4-5-20250929": "claude-sonnet-4.5",
	"claude-opus-4-1": "claude-opus-4.5",
	# Old image model names
	"dall-e-2": "dall-e-3",
}

## Resolve old model names to new ones for backward compatibility
func resolve_model_alias(saved_name: String) -> String:
	return MODEL_ALIASES.get(saved_name, saved_name)

# ## This function will return the `API_MODEL_PROVIDERS` enum value
# ## for the provider currently in use by passed tab or the active one
# func get_active_provider(tab: int = SingletonObject.Chats.current_tab) -> API_MODEL_PROVIDERS:
	
# 	# get currently used provider script or the chats default one
# 	var provider_script = Chats.default_provider_script if ChatList.is_empty() else ChatList[tab].provider.get_script()

# 	for key: API_MODEL_PROVIDERS in API_MODEL_PROVIDER_SCRIPTS:
# 		if API_MODEL_PROVIDER_SCRIPTS[key] == provider_script:
# 			return key

# 	# fallback to first provider shown in the chat dropdown
# 	return Chats._provider_option_button.get_item_id(0) as API_MODEL_PROVIDERS

@onready var preferences_popup: PreferencesPopup = $"/root/RootControl/PreferencesPopup"

#endregion API Consumer

#region Project Management
@warning_ignore("unused_signal")
signal NewProject
@warning_ignore("unused_signal")
signal OpenProject(path: String)
@warning_ignore("unused_signal")
signal OpenRecentProject(recent_project_name: String)
@warning_ignore("unused_signal")
signal SaveProject
@warning_ignore("unused_signal")
signal SaveProjectAs
@warning_ignore("unused_signal")
signal PackageProject
@warning_ignore("unused_signal")
signal UnpackageProject
@warning_ignore("unused_signal")
signal CloseProject
@warning_ignore("unused_signal")
signal RedrawAll
@warning_ignore("unused_signal")
signal SaveOpenEditorTabs
@warning_ignore("unused_signal")
signal UpdateLastSavePath(new_path: String)
@warning_ignore("unused_signal")
signal UpdateUnsavedTabIcon
##
@warning_ignore("unused_signal")
signal set_icon_size_24
@warning_ignore("unused_signal")
signal set_icon_size_48
@warning_ignore("unused_signal")
signal set_icon_size_68
@warning_ignore("unused_signal")
signal drawer_save_data
@warning_ignore("unused_signal")
signal openDrawerNotes
@warning_ignore("unused_signal")
signal deleted_drawer_note

var saved_state = true
signal updated_save_state(project_name:String,saved: bool)
func save_state(state: bool): 
	saved_state = state
	updated_save_state.emit("", state)


#endregion Project Management

#region Check if features are open

#checks if the editor pane has a current tab
func is_editor_file_open() -> bool:
	var editor: Editor = editor_container.editor_pane.Tabs.get_current_tab_control()
	if editor is Editor and editor.type == Editor.Type.TEXT:
		return true
	return false

func is_graphics_editor_open() -> bool:
	var editor: Editor = editor_container.editor_pane.Tabs.get_current_tab_control()
	if editor is Editor and editor.type == Editor.Type.GRAPHICS:
		return true
	return false


func is_notes_open() -> bool:# checks if a notes list exists
	if notes_container:
		return true
	return false


func is_chat_open() -> bool: #checks if a chat lists exists
	if ChatList:
		return true
	return false

#checks if ANY project features are open
func any_project_features_open() -> bool:
	if is_chat_open() or is_notes_open() or is_editor_file_open():
		return true
	return false

#checks if ALL project features are open
func all_project_features_open() -> bool:
	if is_chat_open() and is_notes_open() and (is_editor_file_open() or is_graphics_editor_open()):
		return true
	return false

#endregion Check if features are open

#region Theme change

# get the root control node and apply the theme to it, all its children inherit the theme
#@onready var root_control: Control = $"/root/RootControl"

#more themes can be added in the future with ease using the enums
enum theme {LIGHT_MODE, DARK_MODE, WINDOWS_MODE}
@warning_ignore("unused_signal")
signal theme_changed(theme_enum)


func get_theme_enum() -> int:
	if config_has_saved_section("theme"):
		return config_file.get_value("theme", "theme_enum",0)
	else:
		return theme.DARK_MODE


func set_theme(themeID: int) -> void:
	if get_theme_enum() == themeID:
		return
	var root_control: Control = get_tree().current_scene
	var new_theme: Theme
	match themeID:
		theme.LIGHT_MODE:
			var _light_theme_status: = ResourceLoader.load_threaded_request("res://assets/themes/light_mode.theme")
			new_theme = ResourceLoader.load_threaded_get("res://assets/themes/light_mode.theme")
		theme.DARK_MODE:
			var _dark_theme_status: = ResourceLoader.load_threaded_request("res://assets/themes/blue_dark_mode.theme")
			new_theme = ResourceLoader.load_threaded_get("res://assets/themes/blue_dark_mode.theme")
		theme.WINDOWS_MODE:
			var _windows_theme_request: = ResourceLoader.load_threaded_request("res://assets/themes/windows_mode.theme")
			new_theme = ResourceLoader.load_threaded_get("res://assets/themes/windows_mode.theme")
	root_control.theme = new_theme
	save_to_config_file("theme", "theme_enum", themeID)
	theme_changed.emit(themeID)

#endregion Theme change


#region Audio Settings
@warning_ignore("unused_signal")
signal mic_changed(microphone)

func get_microphone():
	return config_file.get_value("AudioSettings", "SelectedMic",  "Default")


func set_microphone(mic: String) -> void:
	AudioServer.set_input_device(mic)
	save_to_config_file("AudioSettings", "SelectedMic", mic)
	mic_changed.emit(mic)

#endregion Audio Settings


#region Loading screen stuff
@warning_ignore("unused_signal")
signal Loading(state, label_text)

func show_loading_screen(_label_text: String = ""):
	Loading.emit(true, _label_text)

func hide_loading_screen():
	Loading.emit(false, "")

#endregion Loading screen stuff


#region ChatNotification Player
func play_chat_notification() -> void:
	await get_tree().create_timer(0.25).timeout
	chat_notification_player.play()


#endregion ChatNotification Player

func reorder_recent_project(firstIndex: int, secondIndex: int) -> void:

	if !has_recent_projects():
		return

	var recent_projects: Array = get_recent_projects()

	if firstIndex < 0 or firstIndex >= recent_projects.size() or secondIndex < 0 or secondIndex >= recent_projects.size():
		printerr("Invalid indices for reordering recent project.")
		return

	# Get the project NAME at the first index
	var project_name_to_move = recent_projects[firstIndex]
	# Get the corresponding PATH
	var project_path_to_move = get_project_path(project_name_to_move)

	# Remove the project from its original position (by name/key)
	config_file.erase_section_key("OpenRecent", project_name_to_move)


	#Create a temporary dictionary to store the reordered projects
	var reordered_projects: Dictionary = {}
	var i := 0
	for project_name in recent_projects:
		if i == secondIndex:
			reordered_projects[project_name_to_move] = project_path_to_move # Insert at the new index
		if i != firstIndex: #Skip the original index of the moved project.
			reordered_projects[project_name] = get_project_path(project_name)
		i += 1

	if secondIndex >= recent_projects.size(): #handle inserting at the end
		reordered_projects[project_name_to_move] = project_path_to_move
		


	# Clear the "OpenRecent" section and add the reordered projects
	config_file.erase_section("OpenRecent")
	for key in reordered_projects:
		config_file.set_value("OpenRecent", key, reordered_projects[key])


	config_file.save(_config_file_name)

# generate IDs for items: chat items, memory items and editor
func generate_UUID() -> String:
	var rng = RandomNumberGenerator.new() # Instantiate the RandomNumberGenerator
	rng.randomize() # Uses the current time to seed the random number generator
	var random_number = rng.randi() # Generates a random integer
	var hash256 = str(random_number).sha256_text()
	return hash256

var terminal_input_event: Array[InputEvent]
var view_menu: PopupMenu
var add_graphics_button: Button
func toggle_experimental_actions(enable: bool) -> void:
	if !enable:
		if InputMap.has_action("ui_terminal"):
			InputMap.action_erase_events("ui_terminal")
	else:
		for i in terminal_input_event:
			InputMap.action_add_event("ui_terminal", i)
	for i in get_tree().get_nodes_in_group("Experimental"):
		i = i as Control
		i.visible = enable
	experimental_enabled = enable


## Set verbose logging state and save to config
func set_verbose_logging(enable: bool) -> void:
	verbose_logging = enable
	save_to_config_file("Logging", "verbose", enable)
	toggle_verbose_logging.emit(enable)

#region Output Device

signal output_device_changed(device: String)

func get_output_device() -> String:
	if config_has_saved_section("AudioSettings"):
		return config_file.get_value("AudioSettings", "OutputDevice",  "Default")
	else:
		return "Default"


func set_output_device(device: String) -> void:
	if device in AudioServer.get_output_device_list():
		AudioServer.output_device = device
		if get_output_device() != device:
			save_to_config_file("AudioSettings", "OutputDevice",  device)


#endregion Output Device
