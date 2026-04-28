class_name Editor
extends Control
## Editor node is responsible for acting as a CodeEdit or TextureRect
## depending if it handles text or graphics file.
## A file path can be associated with it to save the content of the node to it

## @tutorial Editor.create(Editor.Type.TEXT)

static var editor_scene = preload("res://Scenes/Editor.tscn")
static var graphics_editor_scene = preload("res://Scenes/GraphicsEditorV2.tscn")
static var spreadsheet_editor_scene = preload("res://Scenes/SpreadsheetEditor.tscn")


signal content_changed()
signal save_dialog(dialog_result: DialogResult)
signal note_ready_for_chat(note: Note)  ## Emitted when "Send to LLM" note is created and ready
enum DialogResult { SAVE, CANCEL, CLOSE }

# Flags to represent the saved states
# combining the flags shows the current state of the editor data

## Represents that the editor file is saved, if there is one
const FILE_SAVED: = 0x1

## Represents that the associated object is saved, if there is one
const ASSOCIATED_OBJECT_SAVED: = 0x2

var video_player: VideoPlayer:
	set(value):
		video_player = value
		get_node("%VBoxContainer").add_child(value)

var code_edit: EditorCodeEdit
var graphics_editor: GraphicsEditorV2
var package_editor: PackageEditor
var logs_viewer  # AutocoderLogsViewer - type annotation removed to avoid circular dependency
var kanban_board  # AutocoderKanbanBoard - type annotation removed to avoid circular dependency
var spreadsheet_editor  # SpreadsheetEditor
var pcb_editor  # PCBEditor - type annotation removed to avoid circular dependency
var video_editor_panel  # VideoEditorPanel - type annotation removed to avoid circular dependency
var activity_log_panel  # ActivityLogPanel - type annotation removed to avoid circular dependency
var webview_editor  # WebViewEditor - type annotation removed to avoid circular dependency
var worker_status_panel  # WorkerStatusPanel - type annotation removed to avoid circular dependency
var docket_editor  # DocketEditorPanel - type annotation removed to avoid circular dependency
var plugin_scene_root: Control  ## Mounted scene root for PLUGIN_SCENE editors.

## Set by caller before Editor.create(Type.PLUGIN_SCENE) to identify the panel.
var plugin_id: String = ""
var panel_name: String = ""
## save_mode mirrors the manifest's panel save_mode ("host_owned" | "plugin_owned").
## Set during create() from the panel definition; defaults to "host_owned".
var plugin_save_mode: String = "host_owned"
## Chrome actions the plugin manifest asks Minerva to hide on this PLUGIN_SCENE tab.
## Each entry is one of "save_all" | "save" | "create_note" | "inject_toggle".
## Populated from manifest panel.chrome.suppress in create_plugin_scene().
var plugin_chrome_suppress: Array[String] = []
@onready var _note_check_button: CheckButton = %CheckButton

@onready var autowrap_button: Button = %AutowrapButton
@onready var mic_button: Button = %MicButton
@onready var code_syntax_button: IconsButton = $VBoxContainer/ButtonsHBoxContainer/CodeSyntaxButton
@onready var find_button: IconsButton = %FindButton
@onready var reload_button: IconsButton = %reloadButton
@onready var export_area_button: IconsButton = %ExportAreaButton

#this are control noes for the Ctrl+F UI
@onready var find_string_container: HBoxContainer = %FindStringContainer
@onready var find_string_line_edit: LineEdit = %FindStringLineEdit
@onready var matches_counter_label: Label = %MatchesCounterLabel
@onready var previous_match_button: Button = %PreviousMatchButton
@onready var next_match_button: Button = %NextMatchButton


#this are control nodes for the Ctrl+G popup
@onready var jump_to_line_panel: PopupPanel = %JumpToLinePanel
@onready var jump_to_line_edit: LineEdit = %JumpToLineEdit
@onready var jump_to_line_label: RichTextLabel = %JumpToLineLabel

@onready var text_is_smaller = $VBoxContainer/ButtonsHBoxContainer/TextIsSmaller
@onready var text_is_incoplete = $VBoxContainer/ButtonsHBoxContainer/TextIsIncoplete
@onready var text_is_smaller_and_incoplete = $VBoxContainer/ButtonsHBoxContainer/TextIsSmalleAndIncoplete

enum Type {
	TEXT,
	GRAPHICS,
	VIDEO,
	PACKAGE,
	LOGS,
	KANBAN,
	SPREADSHEET,
	PCB,
	VIDEO_EDITOR,
	ACTIVITY_LOG,
	WEBVIEW,
	PLUGIN_MANAGER,
	WORKER_STATUS,
	DOCKET,
	PLUGIN_SCENE,   ## Native Godot-scene panel contributed by a plugin (design §7.1).
}


## May contain the object that is being edited by this editor.[br]
## Eg. ChatImage, Note, etc..[br]
## Allows switching to existing editor instead of
## opening a new one for same associated object.
var associated_object:
	set(value):
		prints("AS SET TO:", value)
		associated_object = value
		_handle_associated_object_change()
		SingletonObject.UpdateUnsavedTabIcon.emit()

## Callable that overrides what happens when user clicks the editor "save" button.
var _save_override: Callable

var tab_title: String = "":
	set(value):
		tab_title = value
		
		if not SingletonObject.editor_pane.Tabs.is_ancestor_of(self):
			return

		var idx: = SingletonObject.editor_pane.Tabs.get_tab_idx_from_control(self)
		if idx != -1:
			SingletonObject.editor_pane.Tabs.set_tab_title(idx, value)

		if code_edit:
			if code_syntax_enabled:
				code_edit.syntax_highlighter = update_code_hightlighter(tab_title)

var file: String:
	set(value):
		file = value
		if code_edit != null:
			if code_syntax_enabled:
				code_edit.syntax_highlighter = update_code_hightlighter(file)
		if reload_button != null:
			reload_button.disabled = false

#var file_path: String
var type: Type
var _file_saved := false
## Tracks unsaved changes for PLUGIN_SCENE editors; set true on content_changed,
## cleared on successful save.
var _plugin_scene_modified := false

var supported_text_exts: PackedStringArray
## Wether the editor can prompt user to save the content.
var prompt_save:= true

# checks if the editor has been saved at least once
var file_saved_in_disc := false # this is used when you press the save button on the file menu

static var code_syntax_enabled: = true

## Convenience factory for PLUGIN_SCENE editors that pre-sets plugin_id / panel_name
## on the editor instance before Editor.create() reads them in the match arm.
static func create_plugin_scene(p_id: String, p_name: String, file_ = null, name_ = null, associated_object_ = null) -> Editor:
	# Instantiate a bare Editor node, set the plugin fields, then delegate to create().
	# We must set the fields on the instance BEFORE create() runs the match arm,
	# so we instantiate here and call create() with a dummy type that we override.
	# Actually the cleanest path: instantiate directly and run only the PLUGIN_SCENE
	# branch, mirroring what create() does for other types.
	var editor = editor_scene.instantiate()
	editor.type = Type.PLUGIN_SCENE
	editor.plugin_id = p_id
	editor.panel_name = p_name
	editor.associated_object = associated_object_
	if name_:
		editor.tab_title = name_
	if file_:
		editor.file = file_

	var vbox_container: VBoxContainer = editor.get_node("VBoxContainer")

	if p_id.is_empty() or p_name.is_empty():
		push_error(
			"[Editor] create_plugin_scene(): plugin_id and panel_name must be non-empty"
		)
	else:
		vbox_container.clip_contents = true
		var pm = _get_plugin_manager_safe()
		if pm != null:
			var db = pm.get_db()
			var def = db.get_by_id(p_id) if db != null else null
			if def != null:
				for pd in def.ui_panels:
					if pd is Dictionary and pd.get("name", "") == p_name:
						editor.plugin_save_mode = pd.get("save_mode", "host_owned")
						var cs_raw: Variant = pd.get("chrome_suppress", [])
						var cs_list: Array[String] = []
						if cs_raw is Array:
							for cs_item in (cs_raw as Array):
								cs_list.append(str(cs_item))
						editor.plugin_chrome_suppress = cs_list
						break
		var root: Control = PluginScenePanelHost.instantiate_into(
			vbox_container, p_id, p_name, editor
		)
		editor.plugin_scene_root = root
		if root != null and root.has_signal("content_changed"):
			root.content_changed.connect(editor._on_editor_changed)
		if pm != null:
			var tscn_path: String = ""
			var db2 = pm.get_db()
			var def2 = db2.get_by_id(p_id) if db2 != null else null
			if def2 != null:
				for pd2 in def2.ui_panels:
					if pd2 is Dictionary and pd2.get("name", "") == p_name:
						var data_dir: String = def2.data_directory
						var entry_rel: String = pd2.get("entry_scene", "")
						if not entry_rel.is_empty() and not data_dir.is_empty():
							tscn_path = data_dir.path_join(entry_rel).simplify_path()
						break
			pm.register_live_panel(p_id, p_name, tscn_path, vbox_container, root, editor)

	return editor


static func create(type_: Type, file_ = null, name_ = null, associated_object_ = null, initial_setup: = true) -> Editor:
	var editor = editor_scene.instantiate()
	editor.type = type_
	editor.associated_object = associated_object_
	
	if name_:
		editor.tab_title = name_
	if file_: 
		editor.file = file_

	# runs before onready so we need to use get_node
	var vbox_container: VBoxContainer = editor.get_node("VBoxContainer")
	match type_:
		Editor.Type.TEXT:
			var new_code_edit = EditorCodeEdit.new()
			new_code_edit.gui_input.connect(editor._on_code_edit_gui_input)
			new_code_edit.text_changed.connect(editor._on_editor_changed)
			vbox_container.add_child(new_code_edit)
			
			if name_ and code_syntax_enabled:
				name_ = name_ as String
				
				var lang_keywords: Dictionary = SingletonObject.syntax_manager.get_syntax_for_language(name_)
				var code_highlighter: = CodeHighlighter.new()
				if !lang_keywords.is_empty():
					code_highlighter.keyword_colors = lang_keywords
				var color_group: = SingletonObject.syntax_manager.get_color_groups()
				code_highlighter.member_keyword_colors = color_group
				code_highlighter.number_color = color_group.get("numbers")
				code_highlighter.symbol_color = color_group.get("objectRelated")
				code_highlighter.function_color = color_group.get("functions")
				code_highlighter.member_variable_color = color_group.get("types")
				new_code_edit.syntax_highlighter = code_highlighter
			
			editor.code_edit = new_code_edit
		Editor.Type.GRAPHICS:
			var new_graphics_editor: GraphicsEditorV2 = graphics_editor_scene.instantiate()
			new_graphics_editor.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			
			if initial_setup:
				new_graphics_editor.ready.connect(new_graphics_editor.setup)
				new_graphics_editor.graphics_editor_changed.connect(editor._on_graphics_editor_changed)
			# new_graphics_editor.masking_color = Color(0.25098, 0.227451, 0.243137, 0.6)
			#new_graphics_editor.changed.connect(editor._on_editor_changed)
			vbox_container.add_child(new_graphics_editor)
			editor.graphics_editor = new_graphics_editor
			## TODO: Implement changed signal for graphics 
			
		# editor.get_node("%GraphicsEditor").changed.connect(editor._on_editor_changed)
		Editor.Type.VIDEO:
			var new_video_player: VideoPlayer = SingletonObject.video_player_scene.instantiate()
			new_video_player.video_path = file_
			editor.video_player = new_video_player
			editor.get_node("%ButtonsHBoxContainer").queue_free()
			editor.get_node("%FindStringContainer").queue_free()
		
		Editor.Type.PACKAGE:
			editor.package_editor = PackageEditor.create()

			editor.package_editor.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(editor.package_editor)
		Editor.Type.LOGS:
			var AutocoderLogsViewerClass = load("res://Scripts/UI/Controls/Autocoder/AutocoderLogsViewer.gd")
			var logs_widget = AutocoderLogsViewerClass.create()
			logs_widget.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(logs_widget)
			editor.logs_viewer = logs_widget
			logs_widget.entry_added.connect(editor._on_editor_changed)

		Editor.Type.KANBAN:
			var kanban_scene = preload("res://Scripts/UI/Controls/Autocoder/AutocoderKanbanBoard.tscn")
			var kanban_widget = kanban_scene.instantiate()
			kanban_widget.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			kanban_widget.size_flags_horizontal = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(kanban_widget)
			editor.kanban_board = kanban_widget

		Editor.Type.SPREADSHEET:
			var new_spreadsheet_editor = spreadsheet_editor_scene.instantiate()
			new_spreadsheet_editor.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL

			if initial_setup:
				new_spreadsheet_editor.ready.connect(new_spreadsheet_editor.setup)
				new_spreadsheet_editor.content_changed.connect(editor._on_spreadsheet_editor_changed)

			vbox_container.add_child(new_spreadsheet_editor)
			editor.spreadsheet_editor = new_spreadsheet_editor

		Editor.Type.PCB:
			vbox_container.clip_contents = true
			var pcb_editor_scene = load("res://Scenes/PCBEditor.tscn")
			var new_pcb_editor = pcb_editor_scene.instantiate()
			new_pcb_editor.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			new_pcb_editor.size_flags_horizontal = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(new_pcb_editor)
			editor.pcb_editor = new_pcb_editor
			new_pcb_editor.data_changed.connect(func(): SingletonObject.UpdateUnsavedTabIcon.emit())

		Editor.Type.VIDEO_EDITOR:
			vbox_container.clip_contents = true
			var video_editor_scene = load("res://Scenes/VideoEditorPanel.tscn")
			var new_video_editor = video_editor_scene.instantiate()
			new_video_editor.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			new_video_editor.size_flags_horizontal = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(new_video_editor)
			editor.video_editor_panel = new_video_editor
			new_video_editor.data_changed.connect(func(): SingletonObject.UpdateUnsavedTabIcon.emit())
			if file_:
				new_video_editor.load_from_path(file_)

		Editor.Type.ACTIVITY_LOG:
			var panel = ActivityLogPanel.new()
			panel.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			panel.size_flags_horizontal = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(panel)
			editor.activity_log_panel = panel

		Editor.Type.WEBVIEW:
			# Prefer CEF (texture-based Chromium) when available — texture/offscreen
			# hosting fixes the caret-rendering gap WRY has on Linux/X11 (DCR
			# 019dac8d). Falls back to WRY-based WebViewEditor if godot-cef
			# extension isn't installed.
			var webview_scene_path: String = "res://Scenes/WebViewEditor.tscn"
			if ClassDB.class_exists("CefTexture"):
				webview_scene_path = "res://Scenes/CefWebViewEditor.tscn"
			var webview_editor_scene = load(webview_scene_path)
			var new_webview_editor = webview_editor_scene.instantiate()
			new_webview_editor.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			new_webview_editor.size_flags_horizontal = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(new_webview_editor)
			editor.webview_editor = new_webview_editor
			new_webview_editor.content_changed.connect(editor._on_editor_changed)

		Editor.Type.PLUGIN_MANAGER:
			vbox_container.clip_contents = true
			var plugin_manager_scene = load("res://Scenes/PluginManagerPanel.tscn")
			var new_plugin_manager = plugin_manager_scene.instantiate()
			new_plugin_manager.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			new_plugin_manager.size_flags_horizontal = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(new_plugin_manager)

		Editor.Type.WORKER_STATUS:
			var panel = WorkerStatusPanel.new()
			panel.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			panel.size_flags_horizontal = SizeFlags.SIZE_EXPAND_FILL
			vbox_container.add_child(panel)
			editor.worker_status_panel = panel

		Editor.Type.DOCKET:
			vbox_container.clip_contents = true
			var new_docket_panel = DocketPanel.new()
			new_docket_panel.size_flags_vertical = SizeFlags.SIZE_EXPAND_FILL
			new_docket_panel.size_flags_horizontal = SizeFlags.SIZE_EXPAND_FILL
			var dm: DocketManager = SingletonObject.docket_manager
			if dm:
				new_docket_panel.init(dm)
			vbox_container.add_child(new_docket_panel)
			editor.docket_editor = new_docket_panel

		Editor.Type.PLUGIN_SCENE:
			# PLUGIN_SCENE editors must be created via Editor.create_plugin_scene()
			# so that plugin_id and panel_name are set before the match arm runs.
			# If create() is called directly with PLUGIN_SCENE, log an error and
			# leave the editor without a mounted scene (placeholder will show via
			# PluginScenePanelHost when plugin_id is empty).
			push_error(
				"[Editor] create() called with Type.PLUGIN_SCENE — use " +
				"Editor.create_plugin_scene(plugin_id, panel_name, ...) instead."
			)

	return editor


## Return PluginManager from SingletonObject safely (no hard dependency at parse time).
static func _get_plugin_manager_safe():
	var loop := Engine.get_main_loop()
	if loop == null or not loop is SceneTree:
		return null
	var root: Node = (loop as SceneTree).root
	if root == null:
		return null
	var so: Node = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	if "plugin_manager" in so:
		return so.get("plugin_manager")
	return null


## Return PluginEditorRegistry from SingletonObject safely.
static func _get_plugin_editor_registry_safe():
	var loop := Engine.get_main_loop()
	if loop == null or not loop is SceneTree:
		return null
	var root: Node = (loop as SceneTree).root
	if root == null:
		return null
	var so: Node = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	if "plugin_editor_registry" in so:
		return so.get("plugin_editor_registry")
	return null

func toggle(on: bool) -> void:
	_note_check_button.button_pressed = on


func update_code_hightlighter(lang: String) -> CodeHighlighter:
	var lang_keywords = SingletonObject.syntax_manager.get_syntax_for_language(lang)
	var code_highlighter: = CodeHighlighter.new()
	if !lang_keywords.is_empty():
		code_highlighter.keyword_colors = lang_keywords
	var color_group: = SingletonObject.syntax_manager.get_color_groups()
	code_highlighter.member_keyword_colors = color_group
	code_highlighter.number_color = color_group.get("numbers")
	code_highlighter.symbol_color = color_group.get("objectRelated")
	code_highlighter.function_color = color_group.get("functions")
	code_highlighter.member_variable_color = color_group.get("types")
	return code_highlighter


func _ready():
	SingletonObject.injection_consumed.connect(_on_injection_consumed)
	($CloseDialog as ConfirmationDialog).add_button("Close", true, "close")
	if file:
		match type:
			Type.TEXT: _load_text_file(file)
			Type.GRAPHICS: _load_graphics_file(file)
			Type.VIDEO: video_player.video_path = file
			Type.PCB: _load_pcb_file(file)
			Type.KANBAN: _load_kanban_file(file)
			Type.SPREADSHEET: _load_spreadsheet_file(file)
			Type.WEBVIEW: _load_webview_file(file)
			Type.PLUGIN_SCENE: _load_plugin_scene_file(file)

	_note_check_button.disabled = type != Type.TEXT and type != Type.GRAPHICS and type != Type.KANBAN and type != Type.LOGS and type != Type.SPREADSHEET and type != Type.PCB and type != Type.VIDEO_EDITOR and type != Type.ACTIVITY_LOG and type != Type.WEBVIEW and type != Type.PLUGIN_SCENE
	
	#set the text formats that are supported we add a "*" to the start of every ext
	for ext in SingletonObject.supported_text_formats:
		ext = "*." +ext 
		supported_text_exts.append(ext)
	$FileDialog.filters = supported_text_exts
	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = $FileDialog.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 12)
	SingletonObject.UpdateLastSavePath.connect(update_last_path)
	#code_edit.text_changed.connect(_on_editor_changed)
	
	if self.type == Type.TEXT:
		mic_button.show()
		autowrap_button.show()
		export_area_button.hide()
		toggle_autowrap()
	elif self.type == Type.LOGS:
		mic_button.hide()
		autowrap_button.hide()
		find_string_container.hide()
		jump_to_line_panel.hide()
		$VBoxContainer/ButtonsHBoxContainer.hide()
	elif self.type == Type.KANBAN:
		mic_button.hide()
		autowrap_button.hide()
		find_string_container.hide()
		jump_to_line_panel.hide()
		$VBoxContainer/ButtonsHBoxContainer.hide()
	elif self.type == Type.ACTIVITY_LOG:
		mic_button.hide()
		autowrap_button.hide()
		find_string_container.hide()
		jump_to_line_panel.hide()
		$VBoxContainer/ButtonsHBoxContainer.hide()
	elif self.type == Type.PLUGIN_MANAGER:
		mic_button.hide()
		autowrap_button.hide()
		find_string_container.hide()
		jump_to_line_panel.hide()
		$VBoxContainer/ButtonsHBoxContainer.hide()
	elif self.type == Type.WORKER_STATUS:
		mic_button.hide()
		autowrap_button.hide()
		find_string_container.hide()
		jump_to_line_panel.hide()
		$VBoxContainer/ButtonsHBoxContainer.hide()
	elif self.type == Type.WEBVIEW:
		mic_button.hide()
		autowrap_button.hide()
		find_string_container.hide()
		jump_to_line_panel.hide()
		code_syntax_button.hide()
		find_button.hide()
		%btnApplyDiff.hide()
		reload_button.hide()
		export_area_button.hide()
		$VBoxContainer/Control.hide()
		$VBoxContainer/FillerControl3.hide()
	elif self.type == Type.PLUGIN_SCENE:
		# Cycle 1 R2: PLUGIN_SCENE tabs participate in the editor-tab chrome
		# contract. Hide controls that don't apply to plugin scenes (mic, find,
		# autowrap, code-syntax, apply-diff, reload, export-region) but KEEP
		# the right-three actions (Save All / Save / Turn-into-Note) and the
		# inject toggle visible by default. Plugin manifest's chrome.suppress
		# field selectively hides any of those four; save_mode == "none"
		# additionally disables Save / Save All on a per-tab basis.
		mic_button.hide()
		autowrap_button.hide()
		find_string_container.hide()
		jump_to_line_panel.hide()
		code_syntax_button.hide()
		find_button.hide()
		%btnApplyDiff.hide()
		reload_button.hide()
		export_area_button.hide()
		_apply_plugin_chrome_visibility()
	else:
		mic_button.hide() 
		autowrap_button.hide()
		code_syntax_button.hide()
		find_button.hide()
		%btnApplyDiff.hide()
		reload_button.hide()
		export_area_button.show()
		
		mic_button.queue_free()
		autowrap_button.queue_free()
		code_syntax_button.queue_free()
		find_button.queue_free()
		find_string_container.queue_free()
		jump_to_line_panel.queue_free()
		%btnApplyDiff.queue_free()
		reload_button.queue_free()
		
		if export_area_button:
			SingletonObject.editor_pane.Tabs.tab_changed.connect(_on_tab_connect)
	
	if type == Type.TEXT:
		text_is_smaller.pressed.connect(_on_close_warrning.bind(text_is_smaller))
		text_is_incoplete.pressed.connect(_on_close_warrning.bind(text_is_incoplete))
		text_is_smaller_and_incoplete.pressed.connect(_on_close_warrning.bind(text_is_smaller_and_incoplete))


func _exit_tree() -> void:
	if _proxy_note:
		SingletonObject.detached_note_proxies.erase(_proxy_note)
	# PLUGIN_SCENE cleanup: fire unload hook, unregister from broker and PluginManager.
	if type == Type.PLUGIN_SCENE and not plugin_id.is_empty() and not panel_name.is_empty():
		PluginScenePanelHost.invoke_unload(plugin_scene_root)
		var pm = _get_plugin_manager_safe()
		if pm != null:
			pm.unregister_live_panel(plugin_id, panel_name)

func update_last_path(new_path: String) -> void:
	SingletonObject.last_saved_path = new_path + "/"


func _load_text_file(filename: String):
	if code_syntax_enabled:
		if !filename.get_extension().is_empty():
			code_edit.syntax_highlighter = update_code_hightlighter(filename.get_extension())
		else:
			code_edit.syntax_highlighter = update_code_hightlighter(filename)
	var fa_object = FileAccess.open(filename, FileAccess.READ)
	if fa_object == null:
				var error: = error_string(FileAccess.get_open_error())
				push_warning(error)
				SingletonObject.ErrorDisplay("Couldn't open file", error)
				return
	if fa_object:
		#file_path = file
		code_edit.text = fa_object.get_as_text()
		code_edit.saved_content = code_edit.text
		code_edit.text_changed.emit() # the signal is not emitted for some reason
	else:
		code_edit.text = "Could not retrieve file"
	# %SaveButton.disabled = false


func _load_graphics_file(filename: String):
	var image = Image.load_from_file(filename)
	graphics_editor.create_new_image_layer(filename.get_file().get_basename(), image)
	#_file_saved = true
	#SingletonObject.UpdateUnsavedTabIcon.emit()
	# %SaveButton.disabled = false


func _load_pcb_file(filename: String) -> void:
	var fa := FileAccess.open(filename, FileAccess.READ)
	if not fa:
		SingletonObject.ErrorDisplay("Couldn't open file", error_string(FileAccess.get_open_error()))
		return
	var json := JSON.new()
	if json.parse(fa.get_as_text()) != OK:
		SingletonObject.ErrorDisplay("Invalid PCB file", json.get_error_message())
		return
	if json.data is Dictionary and pcb_editor:
		pcb_editor.load_from_dict(json.data)


func _load_kanban_file(filename: String) -> void:
	var fa := FileAccess.open(filename, FileAccess.READ)
	if not fa:
		SingletonObject.ErrorDisplay("Couldn't open file", error_string(FileAccess.get_open_error()))
		return
	var json := JSON.new()
	if json.parse(fa.get_as_text()) != OK:
		SingletonObject.ErrorDisplay("Invalid Kanban file", json.get_error_message())
		return
	if json.data is Dictionary and kanban_board:
		var AutocoderTaskStoreClass = load("res://Scripts/UI/Controls/Autocoder/AutocoderTaskStore.gd")
		var task_store = AutocoderTaskStoreClass.deserialize(json.data)
		kanban_board.set_task_store(task_store)


func _load_spreadsheet_file(filename: String) -> void:
	if not spreadsheet_editor:
		return
	var fa := FileAccess.open(filename, FileAccess.READ)
	if not fa:
		SingletonObject.ErrorDisplay("Couldn't open file", error_string(FileAccess.get_open_error()))
		return
	var json := JSON.new()
	if json.parse(fa.get_as_text()) != OK:
		SingletonObject.ErrorDisplay("Invalid spreadsheet file", json.get_error_message())
		return
	if json.data is Dictionary:
		spreadsheet_editor.deserialize(json.data)


func _load_webview_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		SingletonObject.ErrorDisplay("File not found", path)
		return
	var html = FileAccess.get_file_as_string(path)
	if webview_editor:
		webview_editor.set_html(html)
		webview_editor.mark_saved()


## Load a file into a PLUGIN_SCENE editor by calling invoke_load on the scene root.
## Called from _ready() when a file path is associated with the editor at creation time.
##
## The document handed to the plugin always includes `file_path`. If the file
## body is valid JSON Dictionary (round-trip from _on_panel_save_request), its
## keys are merged into the document. Otherwise `raw_text` carries the body so
## non-JSON plugin formats (.mcad, custom DSLs) can read their own document.
func _load_plugin_scene_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		SingletonObject.ErrorDisplay("File not found", path)
		return
	if plugin_scene_root == null:
		push_warning(
			("[Editor] _load_plugin_scene_file: plugin_scene_root is null for '%s'") % path
		)
		return
	var doc: Dictionary = {"file_path": path}
	var content: String = FileAccess.get_file_as_string(path)
	if not content.is_empty():
		var json := JSON.new()
		if json.parse(content) == OK and json.data is Dictionary:
			doc.merge(json.data, true)
		else:
			doc["raw_text"] = content
	PluginScenePanelHost.invoke_load(plugin_scene_root, doc)


## Apply manifest-driven chrome visibility for a PLUGIN_SCENE editor tab.
##
## Action vocabulary (matches PluginDefinition._parse_panel_entry):
##   - "save_all"      → SaveOpenEditorTabsButton
##   - "save"          → SaveButton
##   - "create_note"   → CreateNoteButton
##   - "inject_toggle" → CheckButton (chat-injection toggle)
##
## Behaviour:
##   - The chrome row (ButtonsHBoxContainer) is always visible — Round 2 of
##     Cycle 1 explicitly removes the legacy blanket-hide.
##   - Each control is hidden iff its action name is in plugin_chrome_suppress.
##   - save_mode == "none" additionally hides Save and Save All (the host's
##     save dispatch already short-circuits — see Type.PLUGIN_SCENE branch in
##     save_file_to_disc — but hiding the buttons makes the no-op explicit).
##
## Round 2 design decision: hide-when-suppressed (not disable). Disabled
## buttons make the no-save case look like an error; hiding signals "the
## plugin does not participate in this action," which is the truth.
func _apply_plugin_chrome_visibility() -> void:
	var buttons_row: HBoxContainer = $VBoxContainer/ButtonsHBoxContainer
	if buttons_row == null:
		return
	buttons_row.show()

	var save_all_btn: Button = buttons_row.get_node_or_null("SaveOpenEditorTabsButton")
	var save_btn: Button = buttons_row.get_node_or_null("SaveButton")
	var create_note_btn: Button = buttons_row.get_node_or_null("CreateNoteButton")
	var inject_toggle: CheckButton = _note_check_button

	var hide_save_all: bool = plugin_chrome_suppress.has("save_all") or plugin_save_mode == "none"
	var hide_save:     bool = plugin_chrome_suppress.has("save")     or plugin_save_mode == "none"
	var hide_note:     bool = plugin_chrome_suppress.has("create_note")
	var hide_inject:   bool = plugin_chrome_suppress.has("inject_toggle")

	if save_all_btn != null:
		save_all_btn.visible = not hide_save_all
	if save_btn != null:
		save_btn.visible = not hide_save
	if create_note_btn != null:
		create_note_btn.visible = not hide_note
	if inject_toggle != null:
		inject_toggle.visible = not hide_inject


## Changes the function that runs when user clicks the "save" button
## from the [method prompt_close] to [parameter save_function].[br]
## To revert back pass the empty [parameter save_function]:[br]
## [code]override_save(Callable.new())[/code]
func override_save(save_function: Callable) -> void:
	_save_override = save_function


## Prompts user to save the file
## show_save_file_dialog determines if user should be asked wether he wants to save the editor first
## otherwise if shows save file dialog straight away
func prompt_close(show_save_file_dialog := false, new_entry:= false, open_in_this_path: String = "") -> bool:	
	#var dialog_filters: = ($FileDialog as FileDialog).filters # we may need to temporarily alter file dialog filters
	if open_in_this_path != "":
		$FileDialog.current_path = open_in_this_path
	
	match type:
		Type.GRAPHICS:
			$FileDialog.filters = PackedStringArray(["*.png"])
		Type.PCB:
			$FileDialog.filters = PackedStringArray(["*.minpcb ; Minerva PCB"])
		Type.KANBAN:
			$FileDialog.filters = PackedStringArray(["*.minkb ; Minerva Kanban"])
		Type.SPREADSHEET:
			$FileDialog.filters = PackedStringArray(["*.minsheet ; Minerva Spreadsheet", "*.csv ; CSV Files"])
		Type.WEBVIEW:
			$FileDialog.filters = PackedStringArray(["*.html ; HTML Files"])
		Type.PLUGIN_SCENE:
			# Set filter to the plugin's registered extension(s), falling back to all files.
			var reg = _get_plugin_editor_registry_safe()
			if reg != null:
				var exts: Array[String] = reg.list_extensions()
				var filters: PackedStringArray = PackedStringArray()
				for ext in exts:
					filters.append(("*%s ; Plugin file") % ext)
				if not filters.is_empty():
					$FileDialog.filters = filters

	if not prompt_save: return true
	if not show_save_file_dialog:
		$CloseDialog.popup_centered(Vector2i(300, 100))

		var should_save = await save_dialog
		
		if should_save == DialogResult.CANCEL:
			return false
		elif should_save == DialogResult.CLOSE:
			return true
	
	if not file:
		($FileDialog as FileDialog).title = "Save \"%s\" editor" % tab_title
		var line_edit: LineEdit = $FileDialog.get_line_edit()
		if type == Type.TEXT:
			line_edit.text = tab_title# + "." + SingletonObject.supported_text_formats[0]
		else:
			line_edit.text = tab_title
		$FileDialog.popup_centered(Vector2i(700, 500))

		await ($FileDialog as FileDialog).visibility_changed
		
	else:
		if new_entry:# this is used for the save as.. feature
			($FileDialog as FileDialog).title = "Save \"%s\" editor" % tab_title
			
			
			$FileDialog.popup_centered(Vector2i(700, 500))
			
			await ($FileDialog as FileDialog).visibility_changed
			
		else:
			_on_file_dialog_file_selected(file)
	
	# _file_saved is set when user select a save file in `_on_file_dialog_file_selected`
	# if we saved the file close the editor, and revert the _file_saved
	if _file_saved:
		_file_saved = false
		return true
	# if user canceled the file select dialog, just return to the editor
	else:
		return false

## Calls the save implementation that could be altered by [method override_save],[br]
## and then updates the unsaved changes icon.
func save():
	if associated_object is Note and associated_object.file:
		save_file_to_disc(associated_object.file)
	elif SingletonObject.last_saved_path:
		await prompt_close(true, false, SingletonObject.last_saved_path)
	else:
		await prompt_close(true)
	
	# Explicitly update the note after saving
	# if has_meta("memory_item"):
	# 	_update_memory_item(get_meta("memory_item"))
	
	# Post save emit the signals
	match type:
		Type.TEXT:
			code_edit.text_changed.emit()
		Type.GRAPHICS:
			graphics_editor.saved = true
		Type.PCB:
			if pcb_editor:
				pcb_editor.is_modified = false

	SingletonObject.UpdateUnsavedTabIcon.emit()

## Returns the bitmask of the saved state for the editor.
func get_saved_state() -> int:
	var state: int = 0x0

	match type:
		Type.TEXT:
			# if we have a file and the content matches, add the FILE_SAVED mask
			if file and code_edit.text == code_edit.saved_content:
				state |= FILE_SAVED
			
			# if there's associated_object and the content matches add the ASSOCIATED_OBJECT_SAVED flag
			if associated_object:
				if associated_object is Note:
					if associated_object.content_matches(code_edit.text):
						state |= ASSOCIATED_OBJECT_SAVED
				
				# if it's not a note, just mark it as saved
				else:
					state |= ASSOCIATED_OBJECT_SAVED
			
			# if we have no file or associated object, but the content is marked as saved
			# that usually means that the editors was just created (content is empty string)
			if not (file or is_instance_valid(associated_object)) and code_edit.text == code_edit.saved_content:
				state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.GRAPHICS:
			# if there's no graphics editor, even tho that's the type, just return all saved states
			if not graphics_editor: state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

			if file and graphics_editor.saved:
				state |= FILE_SAVED

			elif associated_object and graphics_editor.saved:
				if associated_object is Note:
					state |= ASSOCIATED_OBJECT_SAVED

				else:
					state |= ASSOCIATED_OBJECT_SAVED
		Type.LOGS:
			if logs_viewer and logs_viewer.is_saved():
				state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.SPREADSHEET:
			# For now, spreadsheets are considered saved (no file association yet)
			if not spreadsheet_editor:
				state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED
			else:
				# TODO: Add proper save tracking for spreadsheet
				state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.PCB:
			if not pcb_editor or not pcb_editor.is_modified:
				state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.KANBAN:
			state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.VIDEO_EDITOR:
			# Video editors save their edits to the recording directory
			state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.ACTIVITY_LOG:
			# Activity log is read-only / append-only, always considered saved
			state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.WEBVIEW:
			if webview_editor and not webview_editor.is_saved():
				pass  # state stays 0 — unsaved
			else:
				state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.PLUGIN_MANAGER:
			# Plugin manager is read-only control panel, always considered saved
			state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.WORKER_STATUS:
			# Worker status is a live read-only view, always considered saved
			state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

		Type.PLUGIN_SCENE:
			# Plugin scene is_modified flag is driven by content_changed signal from the
			# scene root.  Track via _plugin_scene_modified set in _on_editor_changed.
			if not _plugin_scene_modified:
				state |= FILE_SAVED | ASSOCIATED_OBJECT_SAVED

	return state

## Returns whether the editor content is saved in regards to the file or the associated object.[br]
## [parameter file_save], if set to true will return whether the editor is saved to a file[br],
## or, if false if the editor is saved at the associted object (eg. Note).
func is_content_saved(file_save: = true) -> bool:
	var state: = get_saved_state()

	if file_save:
		return state & FILE_SAVED
	
	return state & ASSOCIATED_OBJECT_SAVED



func _on_save_dialog_canceled():
	save_dialog.emit(DialogResult.CANCEL)


func _on_save_dialog_confirmed():
	save_dialog.emit(DialogResult.SAVE)


func _on_close_dialog_custom_action(action: StringName):
	if action == "close":
		save_dialog.emit(DialogResult.CLOSE)
		$CloseDialog.hide()


func _on_file_dialog_file_selected(path: String):
	save_file_to_disc(path)


func save_file_to_disc(path: String) -> void:
	file = path
	match type:
		Type.TEXT:
			# Save text content to file
			var save_file = FileAccess.open(path, FileAccess.WRITE)
			if save_file == null:
				var error: = error_string(FileAccess.get_open_error())
				push_warning(error)
				SingletonObject.ErrorDisplay("Couldn't save file", error)
				return
				
			save_file.store_string(code_edit.text)
			code_edit.tag_saved_version()
			code_edit.saved_content = code_edit.text
			
			if associated_object is Note:
				_update_note(associated_object)

		Type.GRAPHICS:
			# Save image to file
			var img = await graphics_editor.compose_final_image()
			if img:
				# Temporarily change filters for PNG save
				var dialog = ($FileDialog as FileDialog)
				var original_filters = dialog.filters
				dialog.filters = ["*.png"]
				
				var err = img.save_png(path)
				if err != OK:
					push_warning("Failed to save image: " + error_string(err))
					SingletonObject.ErrorDisplay("Save Failed", "Couldn't save image to " + path)
					return
				
				dialog.filters = original_filters  # Restore original filters
				
				if associated_object is Note:
					_update_note(associated_object)

				graphics_editor.saved = true

		Type.VIDEO:
			# Handle video file saving if needed
			push_warning("Video saving not implemented")
		Type.LOGS:
			if logs_viewer == null:
				return
			var serialized_text: String = logs_viewer.export_text()
			var save_file = FileAccess.open(path, FileAccess.WRITE)
			if save_file == null:
				var error_log := error_string(FileAccess.get_open_error())
				push_warning(error_log)
				SingletonObject.ErrorDisplay("Couldn't save file", error_log)
				return
			save_file.store_string(serialized_text)
			logs_viewer.mark_saved_snapshot()

		Type.PCB:
			if pcb_editor:
				var dict = pcb_editor.to_dict()
				var json_string = JSON.stringify(dict, "\t")
				var save_file = FileAccess.open(path, FileAccess.WRITE)
				if save_file == null:
					var error := error_string(FileAccess.get_open_error())
					push_warning(error)
					SingletonObject.ErrorDisplay("Couldn't save PCB file", error)
					return
				save_file.store_string(json_string)
				pcb_editor.is_modified = false

		Type.KANBAN:
			if kanban_board and kanban_board.task_store:
				var dict = kanban_board.task_store.serialize()
				var json_string = JSON.stringify(dict, "\t")
				var save_file = FileAccess.open(path, FileAccess.WRITE)
				if save_file == null:
					var error := error_string(FileAccess.get_open_error())
					push_warning(error)
					SingletonObject.ErrorDisplay("Couldn't save Kanban file", error)
					return
				save_file.store_string(json_string)

		Type.SPREADSHEET:
			if spreadsheet_editor:
				var dict = spreadsheet_editor.serialize()
				var json_string = JSON.stringify(dict, "\t")
				var save_file = FileAccess.open(path, FileAccess.WRITE)
				if save_file == null:
					var error := error_string(FileAccess.get_open_error())
					push_warning(error)
					SingletonObject.ErrorDisplay("Couldn't save spreadsheet file", error)
					return
				save_file.store_string(json_string)

		Type.WEBVIEW:
			if webview_editor:
				var save_file = FileAccess.open(path, FileAccess.WRITE)
				if save_file == null:
					var error := error_string(FileAccess.get_open_error())
					push_warning(error)
					SingletonObject.ErrorDisplay("Couldn't save HTML file", error)
					return
				save_file.store_string(webview_editor.get_html())
				webview_editor.mark_saved()

				if associated_object is Note:
					_update_note(associated_object)

		Type.PLUGIN_SCENE:
			if plugin_save_mode == "none":
				return
			if plugin_save_mode == "plugin_owned":
				# TODO: dispatch capability:editor.request_save when capability
				# framework is wired (task 019dc125834f72e987ffdaf88fc152a7).
				push_warning(
					("[Editor] PLUGIN_SCENE save: plugin_owned mode not yet implemented. " +
					"Plugin '%s' panel '%s' — file NOT written by Minerva.") %
					[plugin_id, panel_name]
				)
				return
			# host_owned: call _on_panel_save_request, serialise, write.
			var ctx: Dictionary = {}
			var payload: Variant = PluginScenePanelHost.invoke_save(plugin_scene_root, ctx)
			if payload == null:
				SingletonObject.ErrorDisplay(
					"Save failed",
					("Plugin '%s' panel '%s' did not return a save payload.") %
					[plugin_id, panel_name]
				)
				return
			if not payload is Dictionary:
				SingletonObject.ErrorDisplay(
					"Save failed",
					("Plugin '%s' panel '%s' _on_panel_save_request must return a Dictionary.") %
					[plugin_id, panel_name]
				)
				return
			var payload_dict: Dictionary = payload as Dictionary
			# If the dict contains a "_bytes" key with PackedByteArray, write raw bytes.
			if payload_dict.has("_bytes") and payload_dict["_bytes"] is PackedByteArray:
				var raw_bytes: PackedByteArray = payload_dict["_bytes"]
				var f_raw := FileAccess.open(path, FileAccess.WRITE)
				if f_raw == null:
					var err_raw := error_string(FileAccess.get_open_error())
					push_warning(err_raw)
					SingletonObject.ErrorDisplay("Couldn't save plugin file", err_raw)
					return
				f_raw.store_buffer(raw_bytes)
			else:
				var json_str: String = JSON.stringify(payload_dict, "\t")
				var f_json := FileAccess.open(path, FileAccess.WRITE)
				if f_json == null:
					var err_json := error_string(FileAccess.get_open_error())
					push_warning(err_json)
					SingletonObject.ErrorDisplay("Couldn't save plugin file", err_json)
					return
				f_json.store_string(json_str)
			_plugin_scene_modified = false

	# Update editor state
	_file_saved = true
	file_saved_in_disc = true
	SingletonObject.UpdateLastSavePath.emit(path.get_base_dir())
	
	# Update config if needed
	if SingletonObject.config_has_saved_section("LastSavedPath"):
		SingletonObject.config_clear_section("LastSavedPath")
		SingletonObject.save_to_config_file("LastSavedPath", "path", SingletonObject.last_saved_path)
	
	# Update tab info
	tab_title = path.get_file()
	var idx = SingletonObject.editor_pane.Tabs.get_tab_idx_from_control(self)
	if idx >= 0:
		SingletonObject.editor_pane.Tabs.set_tab_title(idx, tab_title)
		SingletonObject.editor_pane.Tabs.set_tab_tooltip(idx, path)
	
	# Notify changes
	SingletonObject.UpdateUnsavedTabIcon.emit()
	content_changed.emit()
#region bottom of the pane buttons

func _on_save_button_pressed():
	save()


func _on_create_note_button_pressed() -> void:
	
	if is_instance_valid(associated_object) and associated_object is Note:
		_update_note(associated_object)
		SingletonObject.UpdateUnsavedTabIcon.emit()
		return
	
	var new_note: Note

	match type:
		Type.TEXT:
			new_note = Note.create_text_note(tab_title, code_edit.text)
		Type.GRAPHICS:
			new_note = Note.create_image_note(tab_title, await graphics_editor.compose_final_image())
		Type.SPREADSHEET:
			var markdown_content: String = spreadsheet_editor.spreadsheet_data.to_markdown()
			new_note = Note.create_spreadsheet_note(tab_title, tab_title, markdown_content)
		Type.PCB:
			var pcb_image = await pcb_editor.canvas.capture_to_image(800, 600)
			# Full PCB note with state for Edit button restoration
			new_note = Note.create_pcb_note(tab_title, pcb_image, pcb_editor.data.to_dict())
		Type.WEBVIEW:
			if webview_editor:
				var html = webview_editor.get_html()
				new_note = Note.create_html_note(tab_title, html)
		Type.PLUGIN_SCENE:
			new_note = await _create_plugin_scene_note()
		_:
			new_note = Note.create_error_note(tab_title, "Can't create a note for the specified Editor type (%s)" % type)

	if new_note == null:
		return

	SingletonObject.notes_container.add_note(new_note)
	
	associated_object = new_note

	

	await get_tree().process_frame
	SingletonObject.UpdateUnsavedTabIcon.emit()


func _handle_associated_object_change():
	if associated_object == null: return

	if associated_object is Note:
		associated_object.title_changed.connect(
			func():
				tab_title = associated_object.title
		)

		# bind the editor to the lambda so we can unset the associated object it the note is getting deleted
		associated_object.tree_exited.connect(
			func():
				if associated_object.is_queued_for_deletion():
					associated_object = null
					SingletonObject.UpdateUnsavedTabIcon.emit()
		)


## Apply diff button stuff 
func enable_apply_diff() -> void:
	%btnApplyDiff.disabled = false
	
func _on_btn_apply_diff_pressed() -> void:
	self.code_edit.apply_preview()
	%btnApplyDiff.disabled = true

#this functions calls the file linked to the editor to be loaded again into memory
func _on_reload_button_pressed() -> void:
	if file:
		match type:
			Type.GRAPHICS:
				_load_graphics_file(file)
			Type.TEXT:
				_load_text_file(file)
				text_is_smaller.visible = false
				text_is_incoplete.visible = false
				text_is_smaller_and_incoplete.visible = false

#this emits a signal that gets picked by the projectMenuActions to save open editor tabs
func _on_save_open_editor_tabs_button_pressed() -> void:
	SingletonObject.SaveOpenEditorTabs.emit()

#endregion bottom of the pane buttons

#region Code Editor
#region code editor action commands

#this function catches input when the code editor is focused
func _on_code_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and event.keycode == KEY_CTRL:
			%FindStringLineEdit.set_process_input(false)
			%FindStringLineEdit.set_process_unhandled_key_input(false)
		else:
			%FindStringLineEdit.set_process_input(true)
			%FindStringLineEdit.set_process_unhandled_key_input(true)
	if event.is_action_pressed("jump_to_line"):
		jump_to_line()
	elif  event.is_action_pressed("find_string"):
		find_string_in_code_edit()
	


func toggle_autowrap() -> void:
	if code_edit == null:
		return
	if code_edit.wrap_mode != TextEdit.LINE_WRAPPING_BOUNDARY:
		code_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	if code_edit.autowrap_mode == TextServer.AutowrapMode.AUTOWRAP_OFF:
		code_edit.autowrap_mode = TextServer.AUTOWRAP_WORD
	else:
		code_edit.autowrap_mode = TextServer.AutowrapMode.AUTOWRAP_OFF


#this are variables for Ctrl+F
var text_to_search: String = ""
var results_number: int = 0
var results_to_current: int = 0
#this is called when the user presses 'Ctrl+F'
func find_string_in_code_edit() -> void:
	if !find_string_container.visible:
		find_string_container.show()
	
	if code_edit.get_selected_text() != "":
		
		find_string_line_edit.text = code_edit.get_selected_text()
		
		code_edit.add_selection_for_next_occurrence()
		text_to_search = code_edit.get_selected_text()
		update_search(code_edit.get_selected_text())
		find_string_line_edit.select_all()
	else:
		await get_tree().create_timer(0.1).timeout
		find_string_line_edit.grab_focus()


func update_search(new_text: String) -> void:
	code_edit.set_search_text(new_text)
	text_to_search = new_text
	code_edit.highlight_all_occurrences = true
	count_text_occurrences()


func _on_find_string_line_edit_text_changed(new_text: String) -> void:
	update_search(new_text)
	
	var result: = code_edit.search(text_to_search, TextEdit.SearchFlags.SEARCH_WHOLE_WORDS, code_edit.get_caret_line(),code_edit.get_caret_column())
	if result.x != -1:
		code_edit.set_caret_column(result.x)
		code_edit.set_caret_line(result.y)
		code_edit.select(result.y,result.x, result.y, result.x + text_to_search.length())
	code_edit.add_selection_for_next_occurrence()


func count_text_occurrences() -> void:
	results_number = 0
	results_to_current = 0
	
	for line: String in code_edit.text.split("\n"):
		results_number += line.countn(text_to_search,0,0)
	
	var for_idx: = 0
	for i : String in code_edit.text.split("\n"):
		if code_edit.get_caret_line() == for_idx:
			results_to_current += i.countn(text_to_search, 0, code_edit.get_caret_column())
			break
		else:
			results_to_current += i.countn(text_to_search, 0, )
		
		for_idx += 1
	
	update_matches_label(results_to_current, results_number)


func update_matches_label(current_search, occurrences) -> void:
	if occurrences < 1:
		matches_counter_label.text = "No matches"
		matches_counter_label.modulate = Color.RED
	else:
		matches_counter_label.text = "%s of  %s matches: " % [current_search, occurrences]
		matches_counter_label.modulate = Color.WHITE


#region find string buttons
func _on_previous_match_button_pressed() -> void:
	code_edit.deselect()
	if code_edit.get_caret_column() - text_to_search.length() -1  <= 0:
		code_edit.set_caret_column(0)
		if code_edit.get_caret_line() - 1 >= 0:
			code_edit.set_caret_line(code_edit.get_caret_line() - 1)
			code_edit.set_caret_column(code_edit.get_text().split("\n")[code_edit.get_caret_line()].length())
	else:
		code_edit.set_caret_column( code_edit.get_caret_column() - text_to_search.length() - 1)
	
	var result: = code_edit.search(text_to_search, TextEdit.SearchFlags.SEARCH_BACKWARDS, code_edit.get_caret_line(),code_edit.get_caret_column())
	if result.x != -1:
		#print("result from prev:" + str(result))
		code_edit.select(result.y,result.x , result.y, result.x + text_to_search.length())
		code_edit.adjust_viewport_to_caret()
	count_text_occurrences()


func _on_next_match_button_pressed() -> void:
	var result: = code_edit.search(text_to_search, 0, code_edit.get_caret_line(),code_edit.get_caret_column())
	if result.x != -1:
		print("result from next:" + str(result))
		code_edit.set_caret_column(result.x)
		code_edit.set_caret_line(result.y)
		code_edit.select(result.y,result.x , result.y, result.x + text_to_search.length())
		code_edit.adjust_viewport_to_caret()
	count_text_occurrences()

#close button for the find string UI controls
func _on_close_button_pressed() -> void:
	code_edit.highlight_all_occurrences = false
	code_edit.set_search_text('')
	find_string_container.hide()

#endregion find string buttons

#this function is called when the user presses 'Ctrl+G'
func jump_to_line() -> void:
	if !jump_to_line_panel.visible and type == Type.TEXT:
		var string_format = "you are currently on line %d, character %d, type a line number between %d and %d to jump to."

		#this is a ternary operator equivalent
		var column: int = code_edit.get_caret_column() if code_edit.get_caret_column() > 1 else 1
		var line: int = code_edit.get_caret_line() + 1 if code_edit.get_caret_line() > 1 else 1
		var line_count: int = code_edit.get_line_count() if code_edit.get_line_count() > 1 else 1
		
		var new_text = string_format % [line, column, 1, line_count]
		jump_to_line_label.text = new_text
		jump_to_line_edit.call_deferred("grab_focus")
		jump_to_line_panel.call_deferred("show")


func _on_jump_to_line_edit_text_submitted(new_text: String) -> void:
	
	jump_to_line_edit.text = ""
	if new_text.is_valid_int():
		code_edit.set_caret_line(new_text.to_int() -1)
		jump_to_line_panel.call_deferred("hide")
	else:
		jump_to_line_label.text += "\nINPUT PROVIDED WAS NOT VALID." 

#endregion code editor action commands

func _on_editor_changed(text: String = ""):
	if code_edit and text != "":
		# this line gets the max number cf chars for the line edit e.g.: "12345" = 5
		jump_to_line_edit.max_length = str(code_edit.get_line_count()).length()
		# SingletonObject.UpdateUnsavedTabIcon.emit()
		# _file_saved = false
		# file_saved_in_disc = false

	if type == Type.PLUGIN_SCENE:
		_plugin_scene_modified = true

	content_changed.emit()

#region Top Editor buttons
func delete_chars() -> void:
	if Type.TEXT != type:
		return
	
	code_edit.backspace()
	
	code_edit.grab_focus()


func add_new_line() -> void:
	if Type.TEXT != type:
		return
	code_edit.insert_text_at_caret("\n")
	code_edit.grab_focus()


func undo_action():
	match type:
		Type.TEXT:
			code_edit.undo()
			code_edit.grab_focus()
			text_is_smaller.visible = false
			text_is_incoplete.visible = false
			text_is_smaller_and_incoplete.visible = false
		Type.GRAPHICS:
			if graphics_editor:
				graphics_editor.undo_command()
		Type.PCB:
			if pcb_editor:
				if pcb_editor.data.undo():
					pcb_editor.canvas.queue_redraw()
		Type.SPREADSHEET:
			if spreadsheet_editor:
				spreadsheet_editor._perform_undo()


func redo_action():
	match type:
		Type.TEXT:
			code_edit.redo()
			code_edit.grab_focus()
		Type.GRAPHICS:
			if graphics_editor:
				graphics_editor.redo_command()
		Type.PCB:
			if pcb_editor:
				if pcb_editor.data.redo():
					pcb_editor.canvas.queue_redraw()
		Type.SPREADSHEET:
			if spreadsheet_editor:
				spreadsheet_editor._perform_redo()

func clear_text():
	if Type.TEXT != type:
		return
	code_edit.clear()
	code_edit.grab_focus()


func _on_mic_button_pressed() -> void:
	var req := AudioToTexts.PTTRequest.new()
	req.target = code_edit
	req.mic_button = mic_button
	var err: int = SingletonObject.AtT.start_ptt(req)
	if err != OK:
		push_warning("Editor PTT failed: %s" % error_string(err))

#endregion Top Editor buttons
#endregion Code Editor

## Returns whether or not this editor instance can be turned into a [class Note] objects
func _supports_note():
	return type in [Type.TEXT, Type.GRAPHICS, Type.SPREADSHEET, Type.PCB, Type.PLUGIN_SCENE]

## Creates a Note from this Editor.[br]
## If [member type] of this editor is not supported `null` is returned.
func _create_note() -> Note:
	print("[Editor] _create_note() called, type=%s" % type)

	if not _supports_note():
		print("[Editor] _create_note: type not supported, returning null")
		return null

	var note: Note

	match type:
		Type.TEXT:
			print("[Editor] Creating TEXT note...")
			note = Note.create_text_note("Editor Note", code_edit.text)
		Type.GRAPHICS:
			print("[Editor] Creating GRAPHICS note, calling compose_final_image()...")
			var image = await graphics_editor.compose_final_image()
			if image:
				print("[Editor] compose_final_image() returned: %s (size: %dx%d, format: %s)" % [image, image.get_width(), image.get_height(), image.get_format()])
				if image.is_empty():
					push_error("[Editor] compose_final_image() returned an empty image!")
			else:
				push_error("[Editor] compose_final_image() returned null!")
			note = Note.create_image_note("Editor Note", image)
			print("[Editor] Image note created: %s" % note)
		Type.SPREADSHEET:
			print("[Editor] Creating SPREADSHEET note...")
			var csv_content = spreadsheet_editor.get_content()
			note = Note.create_text_note("Spreadsheet Note", csv_content)
			print("[Editor] Spreadsheet note created: %s" % note)
		Type.PCB:
			print("[Editor] Creating PCB image note for LLM...")
			var image = await pcb_editor.canvas.capture_to_image(800, 600)
			# Simple image note for LLM context (transient, no Edit needed)
			note = Note.create_image_note("PCB Note", image)
			print("[Editor] PCB image note created: %s" % note)
		Type.PLUGIN_SCENE:
			note = await _create_plugin_scene_note()

	if note == null:
		push_warning("[Editor] _create_note: note is null, returning null")
		return null

	note.enabled = true
	print("[Editor] _create_note() returning note: %s" % note)

	return note


## Build a Note for a PLUGIN_SCENE editor.
##
## Dispatch policy:
##   1. Try the panel's optional `_on_panel_create_note_request(ctx)` hook
##      via PluginScenePanelHost.invoke_create_note. The hook should return a
##      Dictionary with at minimum {"kind": "text"|"image"|"html", ...} —
##      see _build_note_from_plugin_payload below for the recognised shapes.
##   2. If the hook is missing, returns invalid data, or raises an error,
##      fall back to a screenshot of the plugin scene viewport packaged as
##      an image note. This is the default policy: every plugin tab can
##      contribute *some* visual context to a chat, even without code.
##
## Errors during the plugin hook are surfaced via host.notify (toast +
## Activity:MCP) so the user knows the panel mis-handled the call.
func _create_plugin_scene_note() -> Note:
	var note_title: String = tab_title if not tab_title.is_empty() else panel_name
	var ctx: Dictionary = {
		"plugin_id":  plugin_id,
		"panel_name": panel_name,
		"tab_title":  note_title,
	}

	var payload: Variant = null
	if plugin_scene_root != null:
		payload = PluginScenePanelHost.invoke_create_note(plugin_scene_root, ctx)

	if payload != null:
		var maybe_note: Note = _build_note_from_plugin_payload(note_title, payload)
		if maybe_note != null:
			return maybe_note
		# Plugin returned something we couldn't interpret — surface to the user
		# (DCR R1-C host.notify pipe) and fall through to screenshot fallback.
		_notify_plugin_chrome_error(
			("create_note: plugin '%s' panel '%s' returned invalid note payload " +
			"— falling back to screenshot.") % [plugin_id, panel_name]
		)

	return await _create_plugin_scene_screenshot_note(note_title)


## Translate a plugin-returned payload into a Note. Recognised shapes:
##   {kind: "text",  title?: String, content: String}
##   {kind: "html",  title?: String, html: String}
##   {kind: "image", title?: String, image: Image}              # in-memory Image
## Returns null on unknown/invalid shape so the caller can fall back.
func _build_note_from_plugin_payload(default_title: String, payload: Variant) -> Note:
	if not (payload is Dictionary):
		return null
	var d: Dictionary = payload as Dictionary
	var kind: String = str(d.get("kind", "")).to_lower()
	var title: String = str(d.get("title", default_title))
	if title.is_empty():
		title = default_title
	match kind:
		"text":
			var content: String = str(d.get("content", ""))
			return Note.create_text_note(title, content)
		"html":
			var html: String = str(d.get("html", ""))
			return Note.create_html_note(title, html)
		"image":
			var img_v: Variant = d.get("image", null)
			if img_v is Image:
				return Note.create_image_note(title, img_v as Image)
			return null
		_:
			return null


## Default fallback for PLUGIN_SCENE create-note: capture the plugin's scene
## viewport as a PNG-backed image note. Mirrors the GraphicsEditor / PCB
## screenshot pattern but uses get_viewport().get_texture() because plugin
## scenes don't expose a dedicated capture API.
##
## Capture happens after the next post-draw signal so the image reflects the
## current frame (avoids a 1-frame stale capture). On Linux we still fall
## back to the synchronous get_image() if the deferred path fails — this
## helper is best-effort, not perf-critical.
func _create_plugin_scene_screenshot_note(default_title: String) -> Note:
	var title: String = default_title if not default_title.is_empty() else "Plugin Note"
	var img: Image = await _capture_plugin_scene_image()
	if img == null:
		# Couldn't capture — return an error note so the user gets feedback in
		# the chat rather than a silent failure.
		_notify_plugin_chrome_error(
			("create_note: failed to capture plugin '%s' panel '%s' viewport.") %
			[plugin_id, panel_name]
		)
		return Note.create_error_note(title,
			"Failed to capture plugin panel screenshot.")
	return Note.create_image_note(title, img)


## Synchronous-feeling viewport capture for the plugin scene root. Uses the
## RenderingServer.frame_post_draw signal to ensure GPU work is flushed
## before get_image() — without this the texture can be stale and produce
## a partially-rendered note.
func _capture_plugin_scene_image() -> Image:
	if plugin_scene_root == null or not is_instance_valid(plugin_scene_root):
		return null
	var vp: Viewport = plugin_scene_root.get_viewport()
	if vp == null:
		return null
	# Wait one post-draw cycle so the latest frame is on the GPU.
	await RenderingServer.frame_post_draw
	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null:
		return null
	# Crop to the panel rect so the note is just the plugin's own content,
	# not the surrounding chrome / other tabs.
	var rect: Rect2 = plugin_scene_root.get_global_rect()
	var x: int = max(0, int(rect.position.x))
	var y: int = max(0, int(rect.position.y))
	var w: int = min(int(rect.size.x), img.get_width() - x)
	var h: int = min(int(rect.size.y), img.get_height() - y)
	if w > 0 and h > 0 and (x > 0 or y > 0 or w < img.get_width() or h < img.get_height()):
		img = img.get_region(Rect2i(x, y, w, h))
	return img


## Toast-and-log surface for chrome-action errors specific to PLUGIN_SCENE.
## Routes through PluginNotifyRouter so messages land in both a toast and
## the Activity:MCP editor tab — same channel R1-C set up for host.notify.
func _notify_plugin_chrome_error(message: String) -> void:
	push_warning("[Editor] %s" % message)
	var router_script := load("res://Scripts/Services/Plugins/PluginNotifyRouter.gd")
	if router_script != null:
		router_script.route(plugin_id, {
			"level": "error",
			"message": message,
		})
	else:
		# Fallback: at least show a toast so the user notices.
		if SingletonObject and SingletonObject.has_method("create_toast_notification"):
			SingletonObject.call("create_toast_notification", message,
				ToastNotification.Type.ERROR)


func _update_note(note: Note) -> void:
	if type == Type.TEXT:
		var controls_container = note.get_controls_container() as NoteTextControls
		controls_container.content = code_edit.text

	elif type == Type.GRAPHICS:
		var controls_container = note.get_controls_container() as NoteImageControls
		controls_container.image = await graphics_editor.compose_final_image()

	elif type == Type.SPREADSHEET:
		var controls_container = note.get_controls_container() as NoteTextControls
		controls_container.content = spreadsheet_editor.spreadsheet_data.to_markdown()

	elif type == Type.PCB:
		var controls_container = note.get_controls_container() as NoteImageControls
		controls_container.image = await pcb_editor.canvas.capture_to_image(800, 600)
		# If this is a persistent note (has linked_pcb_data), update the PCB state too
		if not note.linked_pcb_data.is_empty():
			note.linked_pcb_data = JSON.stringify(pcb_editor.data.to_dict())

	elif type == Type.WEBVIEW:
		if webview_editor:
			var html = webview_editor.get_html()
			note.linked_html = html
			var controls_container = note.get_controls_container()
			if controls_container and controls_container.has_method("setup"):
				controls_container.content = html


var _proxy_note: Note.Proxy

func _on_injection_consumed(_history_id: String) -> void:
	## If our proxy was consumed (no longer in the array), uncheck the toggle.
	if _proxy_note and _proxy_note not in SingletonObject.detached_note_proxies:
		_proxy_note = null
		if _note_check_button:
			_note_check_button.set_pressed_no_signal(false)

func _on_check_button_toggled(toggled_on: bool):
	print("[Editor] _on_check_button_toggled(%s) called for editor type=%s" % [toggled_on, type])

	# PLUGIN_SCENE: forward toggle state to the panel so plugins can react
	# (e.g. start/stop streaming live state to chat). Fire-and-forget — the
	# panel does not have to implement the hook, and Minerva's own injection
	# bookkeeping continues to run regardless.
	if type == Type.PLUGIN_SCENE and plugin_scene_root != null:
		PluginScenePanelHost.invoke_inject_toggle(plugin_scene_root, toggled_on)

	if not _supports_note():
		SingletonObject.ErrorDisplay("Not supported", "Notes for this editor type are not supported.")
		_note_check_button.set_pressed_no_signal(false)
		return

	if toggled_on:
		print("[Editor] Creating proxy and starting note creation...")
		_proxy_note = Note.Proxy.new(_create_note)

		_proxy_note.note_created.connect(func(note: Note):
			print("[Editor] note_created signal received! note=%s, type=%s" % [note, str(note.type) if note else "null"])
			note.changed.connect(_on_proxy_note_changed.bind(note))
			print("[Editor] Emitting note_ready_for_chat signal...")
			note_ready_for_chat.emit(note)
			print("[Editor] note_ready_for_chat emitted")
		)

		# Start note creation AFTER connecting signal handler
		_proxy_note.create_note()
		print("[Editor] create_note() called (async), handler connected")

		SingletonObject.detached_note_proxies.append(_proxy_note)
		print("[Editor] Proxy added to detached_note_proxies")

		# Update token estimation when editor note is enabled
		if SingletonObject.Chats:
			SingletonObject.Chats.update_token_estimation()

	else:
		print("[Editor] Toggling OFF, cleaning up proxy...")
		if _proxy_note:
			SingletonObject.detached_note_proxies.erase(_proxy_note)

		_proxy_note = null
		print("[Editor] Proxy cleared")

		# Update token estimation when editor note is disabled
		if SingletonObject.Chats:
			SingletonObject.Chats.update_token_estimation()

func _on_proxy_note_changed(_prop_name: StringName, note: Note) -> void:
	_note_check_button.set_pressed_no_signal(note.enabled)

func _on_close_warrning(path):
	path.visible = false;


func _on_find_button_pressed() -> void:
	code_edit.highlight_all_occurrences = false
	code_edit.set_search_text('')
	find_string_container.visible = !find_string_container.visible


func _on_code_syntax_button_toggled(toggled_on: bool) -> void:
	code_syntax_enabled = toggled_on
	
	if !code_syntax_enabled:
		code_edit.syntax_highlighter = null
		#code_edit.syntax_highlighter.update_cache()
	else:
		if file:
			code_edit.syntax_highlighter = update_code_hightlighter(file)
		else:
			code_edit.syntax_highlighter = update_code_hightlighter(tab_title)


func _on_graphics_editor_changed() -> void:
	content_changed.emit()


func _on_spreadsheet_editor_changed() -> void:
	content_changed.emit()


func _on_export_area_button_pressed() -> void:
	var current_tab = SingletonObject.editor_pane.Tabs.get_current_tab_control()

	if current_tab is Editor and current_tab.type == Editor.Type.GRAPHICS:
		current_tab.graphics_editor.activate_export_region_tool()


func _on_tab_connect(_tab_idx: int) -> void:
	var current_tab = SingletonObject.editor_pane.Tabs.get_current_tab_control()

	if current_tab is Editor and current_tab.type == Editor.Type.GRAPHICS:
		if export_area_button:
			export_area_button.disabled = false
			export_area_button.show()
	else:
		if export_area_button:
			export_area_button.disabled = true
			export_area_button.hide()
