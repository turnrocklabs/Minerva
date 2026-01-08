class_name HumanProvider
extends BaseProvider

func _init():
	provider_name = "Human"

	model_name = "human"
	short_name = "HU"
	# Human provider - placeholder (sorts to bottom of list)
	input_token_cost = 1000.0
	output_token_cost = 1000.0


func _parse_request_results(_response: RequestResults) -> BotResponse:
	var bot_response:= BotResponse.new()
	bot_response.provider = self  # Always set provider
	return bot_response


func generate_content(_prompt: Array[Variant], _additional_params: Dictionary={}):
	var item = _parse_request_results(null)
	
	SingletonObject.chat_completed.emit(item)

	return item


func wrap_memory(item: Note) -> Variant:
	if item.type == Note.Type.TEXT:
		var controls_container = item.get_controls_container() as NoteTextControls
		return controls_container.content
	elif item.type == Note.Type.IMAGE:
		var controls_container = item.get_controls_container() as NoteImageControls
		return controls_container.caption
	else:
		push_warning("Tried to wrap memory but the given note type is not implemented")
		print_stack()

	return ""


func Format(chat_item: ChatHistoryItem) -> Variant:
	# Collect text notes
	var text_notes: = PackedStringArray()
	
	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)

	# Wrap all text notes together once
	var notes_section := ""
	if not text_notes.is_empty():
		notes_section = "### Reference Information ###\n"
		notes_section += "\n\n".join(text_notes)
		notes_section += "\n### End Reference Information ###\n\n"

	# Combine notes section with user message
	var full_text := "%s%s" % [notes_section, chat_item.Message]
	full_text = full_text.strip_edges()

	return {
		"text": full_text
	}

func estimate_tokens(_input) -> int:
	return 0


func estimate_tokens_from_prompt(_input: Array[Variant]):
	return 0


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null
