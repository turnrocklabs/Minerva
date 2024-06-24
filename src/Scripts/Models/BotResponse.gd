## botresponse enables me to standarize responses from any chatbot
class_name BotResponse
extends RefCounted


var id: StringName
var text: String
var image: Image

## Setting the error property marks this response as invalid
var error: String

var provider: BaseProvider

# if the message is not completed due to token limit or any other reason, but can be continued
var complete:= true


var prompt_tokens: int
var completion_tokens: int

var total_tokens: int:
	get: return prompt_tokens + completion_tokens


func _to_string():
	if not error:
		return "Bot Response %s: %s..." % [id, text.substr(0, 10)]
	else:
		return "Bot Response %s (Invalid): %s..." % [id, error.substr(0, 10)]
