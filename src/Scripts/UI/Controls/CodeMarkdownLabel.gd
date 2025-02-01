class_name CodeMarkdownLabel
extends PanelContainer


func get_selected_text() -> String:
	return %CodeLabel.get_selected_text()

func _parse_code_block(input: String) -> String:
	# Adjusted regex to ignore [lb] and [rb] and still remove other bbcode
	var regex = RegEx.new()
	regex.compile("\\[(?!lb\\]|rb\\]).*?\\]")
	var text_without_tags = regex.sub(input, "", true)

	# Replacing [lb] and [rb] with [ and ]
	text_without_tags = text_without_tags.replace("[lb]", "[").replace("[rb]", "]")
	return text_without_tags

# https://docs.godotengine.org/en/stable/tutorials/ui/bbcode_in_richtextlabel.html#stripping-bbcode-tags
func _copy_code_label():
	var text_without_tags: String = _parse_code_block(%CodeLabel.text)
	DisplayServer.clipboard_set(text_without_tags)

func _extract_code_label():
	var text_without_tags: String = _parse_code_block(%CodeLabel.text)
	SingletonObject.NotesTab.add_note(%SyntaxLabel.text, text_without_tags)
	SingletonObject.main_ui.set_notes_pane_visible(true)

static func create(code_text: String, syntax: String = "Plain Text") -> CodeMarkdownLabel:
	# place the code label in panel container to change the background
	var code_panel = preload("res://Scenes/CodeMarkdownLabel.tscn").instantiate()

	code_text[code_text.find("\n")] = ""
	code_panel.get_node("%CodeLabel").text = code_text

	code_panel.get_node("%SyntaxLabel").text = syntax

	code_panel.get_node("%CopyButton").pressed.connect(code_panel._copy_code_label)
	code_panel.get_node("%ExtractButton").pressed.connect(code_panel._extract_code_label)

	return code_panel


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
		
		if code_edit_node:
			# Get the old text from the metadata
			var old_text: String = code_edit_node.get_meta("old_text", code_edit_node.text)
			
			# Set the new text
			code_edit_node.text = new_text
			
			# Call check_incomplete_snippet with old_text and new_text
			ep.check_incomplete_snippet(active_tab_editor_node, old_text, code_edit_node.text)
		else:
			print("Error: CodeEdit node not found in active Text tab.")
	else:
		print("Error: Active tab is not a Text editor.")
	
	# Update the tab icons
	ep.update_tabs_icon()
