class_name CodeMarkdownLabel
extends PanelContainer


# https://docs.godotengine.org/en/stable/tutorials/ui/bbcode_in_richtextlabel.html#stripping-bbcode-tags
func _copy_code_label():
	var regex = RegEx.new()
	regex.compile("\\[.*?\\]")
	var text_without_tags = regex.sub(%CodeLabel.text, "", true)

	DisplayServer.clipboard_set(text_without_tags)

func _extract_code_label():
	var regex = RegEx.new()
	regex.compile("\\[.*?\\]")
	var text_without_tags = regex.sub(%CodeLabel.text, "", true)

	SingletonObject.NotesTab.add_note(%SyntaxLabel.text, text_without_tags)



static func create(code_text: String, syntax: String = "Plain Text") -> CodeMarkdownLabel:

	# place the code label in panel container to change the background
	var code_panel = preload("res://Scenes/CodeMarkdownLabel.tscn").instantiate()

	code_text[code_text.find("\n")] = ""
	code_panel.get_node("%CodeLabel").text = code_text

	code_panel.get_node("%SyntaxLabel").text = syntax


	code_panel.get_node("%CopyButton").pressed.connect(code_panel._copy_code_label)

	code_panel.get_node("%ExtractButton").pressed.connect(code_panel._extract_code_label)

	return code_panel