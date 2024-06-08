## botresponse enables me to standarize responses from any chatbot
class_name BotResponse
extends RefCounted


var FullText: String
var Picture: Texture
var Snips: Array[String]

## Setting the error property marks this response as invalid
var Error: String

var ModelName: String
var ModelShortName: String


## Providing the `BotResponse` with provider set the model name and it's short name automatically
func _init(provider: BaseProvider = null):
	if provider:
		ModelName = provider.model_name
		ModelShortName = provider.short_name

