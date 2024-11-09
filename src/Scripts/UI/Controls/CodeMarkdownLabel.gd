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
	# Get the reference to the EditorPane
	var ep: EditorPane =  SingletonObject.editor_pane
	var text_without_tags: String = _parse_code_block(%CodeLabel.text)
	print("Replacing all text in the text editor.")
	
	# Get the currently active tab
	var active_tab_editor_node: Editor = ep.Tabs.get_current_tab_control()
	
	if ep.Tabs.get_tab_count() < 1:
		active_tab_editor_node = ep.add(Editor.Type.TEXT, null ,%SyntaxLabel.text, null)
		print("no active tab")
	elif active_tab_editor_node.type == Editor.Type.GRAPHICS:
		active_tab_editor_node = ep.add(Editor.Type.TEXT, null ,%SyntaxLabel.text, null)
		print("active tab not text")
	
	# Check if the active tab is an Editor and is a Text editor
	
	if active_tab_editor_node is Editor: #and (active_tab_editor_node.type != Editor.Type.GRAPHICS):
		if active_tab_editor_node.type != Editor.Type.GRAPHICS:
			if !active_tab_editor_node.file:
				ep.Tabs.set_tab_title(ep.Tabs.get_current_tab(),  ep.editor_name_to_use(%SyntaxLabel.text))
			var code_edit_node = active_tab_editor_node.get_node("%CodeEdit")
			
			if code_edit_node:
				#print(text_without_tags)
				code_edit_node.text = text_without_tags
				
			else:
				print("Error: CodeEdit node not found in active Text tab.")
		else: 
			print("Error: Active tab is not a Text editor.")
		ep.update_tabs_icon()
	#elif ep.Tabs.get_child(current_tab_idx):
		#var editor = ep.Tabs.get_child(current_tab_idx)
		#var FindCodeEdit = editor.get_child(0)
		#var code_edit_node = FindCodeEdit.get_node("%CodeEdit")
		#if code_edit_node:
			#code_edit_node.text = text_without_tags
			#return
	else:
		print("Error: Active tab is not an Editor.")
