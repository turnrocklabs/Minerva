class_name CodeMarkdownLabel
extends PanelContainer

@onready var regex = RegEx.new()

const REGEX_PATTERNS = {
	# Matches TODO comments (e.g., // TODO:, # TODO:, /* TODO: */)
	"TODO": r"(\/\/|#|\/\*)\s*TODO:.*",

	# Matches FIXME comments (e.g., // FIXME:, # FIXME:, /* FIXME: */)
	"FIXME": r"(\/\/|#|\/\*)\s*FIXME:.*",

	# Matches placeholder comments (e.g., // ..., # ..., /* ... */)
	"PLACEHOLDER": r"(\/\/|#|\/\*)\s*\.\.\..*",

	# Matches incomplete functions (e.g., func foo() { ... }, def foo(): # ..., void foo() { // ... })
	"INCOMPLETE_FUNCTION": r"(func|def|void|\w+)\s+\w+\s*\(.*?\)\s*[\{:]\s*(\/\/|#|\/\*)\s*\.\.\..*",

	# Matches incomplete classes/structs (e.g., class Foo { ... }, struct Bar { // ... })
	"INCOMPLETE_CLASS": r"(class|struct)\s+\w+\s*[\{:]\s*(\/\/|#|\/\*)\s*\.\.\..*",

	# Matches any comment with "incomplete" in it (e.g., // This is incomplete, # incomplete, /* incomplete */)
	"INCOMPLETE_COMMENT": r"(\/\/|#|\/\*)\s*.*incomplete.*",

	# Matches unimplemented functions (e.g., func foo();, def foo(): pass, void foo();)
	"UNIMPLEMENTED_FUNCTION": r"(func|def|void|\w+)\s+\w+\s*\(.*?\)\s*;\s*$",

	# Matches unimplemented classes/structs (e.g., class Foo;, struct Bar;)
	"UNIMPLEMENTED_CLASS": r"(class|struct)\s+\w+\s*;\s*$",

	# Matches deprecated code (e.g., // DEPRECATED, # DEPRECATED, /* DEPRECATED */)
	"DEPRECATED": r"(\/\/|#|\/\*)\s*DEPRECATED.*",

	# Matches hacky code (e.g., // HACK, # HACK, /* HACK */)
	"HACK": r"(\/\/|#|\/\*)\s*HACK.*",

	# Matches temporary code (e.g., // TEMP, # TEMP, /* TEMP */)
	"TEMP": r"(\/\/|#|\/\*)\s*TEMP.*",

	# Matches debugging code (e.g., // DEBUG, # DEBUG, /* DEBUG */)
	"DEBUG": r"(\/\/|#|\/\*)\s*DEBUG.*",
}
signal created_text_note(index, memory_item_UUID)
signal update_expanded(index, is_expanded)
var linked_memory_item: String = ""
var dict_index: String = ""

@export_range(0.1, 2.0, 0.1) var expand_anim_duration: float = 0.5
@export var expand_transition_type: Tween.TransitionType = Tween.TRANS_SPRING
@export var expand_ease_type: Tween.EaseType = Tween.EASE_OUT
@export var expand_icon_color: Color = Color.WHITE

@onready var expand_button: Button = %ExpandButton
@onready var code_label: MarkdownLabel = %CodeLabel
@onready var p_2: PanelContainer = %p2

var label_size: = 0
var expanded: bool = true

func _ready() -> void:
	
	await get_tree().create_timer(0.05).timeout
	_update_label_size()
	if !expanded:
		code_label.fit_content = false
		code_label.custom_minimum_size.y = 0
		p_2.custom_minimum_size.y = 0
		expand_button.rotation = deg_to_rad(-90.0)
		expand_button.modulate = expand_icon_color
		p_2.call_deferred("hide")


func get_selected_text() -> String:
	return %CodeLabel.get_selected_text()

func _parse_code_block(input: String) -> String:
	# Adjusted regex to ignore [lb] and [rb] and still remove other bbcode
	var temp_regex = RegEx.new()
	temp_regex.compile("\\[(?!lb\\]|rb\\]).*?\\]")
	var text_without_tags = temp_regex.sub(input, "", true)

	# Replacing [lb] and [rb] with [ and ]
	text_without_tags = text_without_tags.replace("[lb]", "[").replace("[rb]", "]")
	return text_without_tags

# https://docs.godotengine.org/en/stable/tutorials/ui/bbcode_in_richtextlabel.html#stripping-bbcode-tags
func _copy_code_label():
	var text_without_tags: String = _parse_code_block(%CodeLabel.text)
	DisplayServer.clipboard_set(text_without_tags)

func _extract_code_label():
	var text_without_tags: String = _parse_code_block(%CodeLabel.text)
	if linked_memory_item == "":
		linked_memory_item = SingletonObject.NotesTab.add_note(%SyntaxLabel.text, text_without_tags).UUID
		created_text_note.emit(dict_index, linked_memory_item)
	else:
		var return_memory = SingletonObject.NotesTab.update_note(linked_memory_item, text_without_tags)
		if return_memory == null:
			linked_memory_item = SingletonObject.NotesTab.add_note(%SyntaxLabel.text, text_without_tags).UUID
	SingletonObject.main_ui.set_notes_pane_visible(true)

static var code_markdown_label: = preload("res://Scenes/CodeMarkdownLabel.tscn")
static func create(code_text: String, syntax: String = "Plain Text", index: String = "", memory_item_UUID: String = "", expanded_value: bool = true) -> CodeMarkdownLabel:
	# place the code label in panel container to change the background
	var code_panel = code_markdown_label.instantiate()
	code_panel.dict_index = index
	if memory_item_UUID != "":
		code_panel.linked_memory_item = memory_item_UUID
	code_text[code_text.find("\n")] = ""
	code_panel.get_node("%CodeLabel").text = code_text

	code_panel.get_node("%SyntaxLabel").text = syntax
	code_panel.expanded = expanded_value
	code_panel.get_node("%CopyButton").pressed.connect(code_panel._copy_code_label)
	code_panel.get_node("%ExtractButton").pressed.connect(code_panel._extract_code_label)
	code_panel.get_node("%CodeLabel").finished.connect(code_panel._update_label_size)
	return code_panel

func _on_smartdiff_pressed() -> bool:
	# get the active editor and ask it to handle the diff
	var ep: EditorPane = SingletonObject.editor_pane
	var active_tab_editor_node: Editor
	var tab_count: int = ep.Tabs.get_tab_count()
	if tab_count > 0:
		active_tab_editor_node = ep.Tabs.get_current_tab_control()
	else:
		# do nothing
		return false
	
	# see if we can get a EditorCodeEdit type
	var editor: EditorCodeEdit
	if active_tab_editor_node.code_edit != null:
		editor = active_tab_editor_node.code_edit 
	
	# get the string of the gnerated code
	var new_text: String = _parse_code_block(%CodeLabel.text)
#	editor.apply_diff(new_text)
	active_tab_editor_node.enable_apply_diff()
	editor.preview_diff(new_text)
	return true

func _on_replace_all_pressed():
	# Get the EditorPane instance
	var ep: EditorPane = SingletonObject.editor_pane
	
	# Parse and prepare the new text
	var new_text: String = _parse_code_block(%CodeLabel.text)
	print("Replacing all text in the text editor.")
	
	# Get the currently active tab
	var active_tab_editor_node: Editor = ep.Tabs.get_current_tab_control()
	
	# If no active tab exists, create a new text editor tab
	if ep.Tabs.get_tab_count() < 1:
		active_tab_editor_node = ep.add(Editor.Type.TEXT, null, %SyntaxLabel.text, null)
		print("No active tab, created a new one.")
	
	# If the active tab is not a text editor, create a new text editor tab
	elif active_tab_editor_node.type == Editor.Type.GRAPHICS:
		active_tab_editor_node = ep.add(Editor.Type.TEXT, null, %SyntaxLabel.text, null)
		print("Active tab is not a text editor, created a new text tab.")
	
	# Ensure the active tab is a text editor
	if active_tab_editor_node is Editor and active_tab_editor_node.type == Editor.Type.TEXT:
		# Update the tab title if no file is associated
		if !active_tab_editor_node.file:
			ep.Tabs.set_tab_title(ep.Tabs.get_current_tab(), ep.editor_name_to_use(%SyntaxLabel.text))
		
		# Get the CodeEdit node
		var code_edit_node = active_tab_editor_node.code_edit
		#active_tab_editor_node.update_code_hightlighter(%SyntaxLabel.text)
		if code_edit_node:
			# Get the old text from the metadata
			var old_text: String = code_edit_node.get_meta("old_text", code_edit_node.text)
			
			# Set the new text
			code_edit_node.text = new_text
			
			#code_edit_node.syntax_highlighter = Editor.get_code_highlighter(ep.editor_name_to_use(%SyntaxLabel.text))

			for i in REGEX_PATTERNS:
				var pattern = REGEX_PATTERNS[i]
				regex.compile(pattern)
				if regex.search(code_edit_node.text):
					SingletonObject.Is_code_completed = false
					break
			# Call check_incomplete_snippet with old_text and new_text
			ep.check_incomplete_snippet(active_tab_editor_node, old_text, code_edit_node.text)
			
		else:
			print("Error: CodeEdit node not found in active Text tab.")
	else:
		print("Error: Active tab is not a Text editor.")
	
	# Update the tab icons
	ep.update_tabs_icon()


func _update_label_size() -> void:
	await get_tree().process_frame
	label_size = int(code_label.size.y)


func _on_expand_button_pressed() -> void:
	expanded = !expanded
	if !expanded:
		contract_code()
	else:
		expand_code()
	update_expanded.emit(dict_index, expanded)

var expand_tween: Tween
func expand_code() -> void:
	if expand_tween and expand_tween.is_running():
		expand_tween.kill()
		return
	if label_size == 0 or label_size > int(code_label.size.y):
		_update_label_size()
	
	p_2.show()
	expand_tween = create_tween().set_ease(expand_ease_type).set_trans(expand_transition_type)
	expand_tween.finished.connect(enable_expand_button)
	expand_button.disabled = true
	expand_tween.tween_property(code_label, "custom_minimum_size:y", label_size, expand_anim_duration)
	expand_tween.set_parallel()
	expand_tween.tween_property(p_2, "custom_minimum_size:y", label_size, expand_anim_duration)
	expand_tween.set_parallel()
	expand_tween.tween_property(expand_button,"rotation", deg_to_rad(0.0), expand_anim_duration)
	expand_tween.set_parallel()
	expand_tween.tween_property(expand_button, "modulate", Color.WHITE, expand_anim_duration)
	await get_tree().create_timer(expand_anim_duration - 0.24).timeout
	code_label.fit_content = true


func contract_code() -> void:
	if expand_tween and expand_tween.is_running():
		expand_tween.kill()
		return
	if label_size == 0 or label_size > int(code_label.size.y):
		_update_label_size()
	code_label.fit_content = false
	expand_tween = create_tween().set_ease(expand_ease_type).set_trans(expand_transition_type)
	expand_tween.finished.connect(enable_expand_button)
	expand_button.disabled = true
	expand_tween.tween_property(code_label, "custom_minimum_size:y", 0, expand_anim_duration)
	expand_tween.set_parallel()
	expand_tween.tween_property(p_2, "custom_minimum_size:y", 0, expand_anim_duration)
	expand_tween.set_parallel()
	expand_tween.tween_property(expand_button,"rotation", deg_to_rad(-90.0), expand_anim_duration)
	expand_tween.set_parallel()
	expand_tween.tween_property(expand_button, "modulate", expand_icon_color, expand_anim_duration)
	
	await get_tree().create_timer(expand_anim_duration - 0.24).timeout
	p_2.hide()


func enable_expand_button() -> void:
	expand_button.disabled = false
