## botresponse enables me to standarize responses from any chatbot
class_name BotResponse
extends RefCounted


var FullText: String
var Picture: Texture
var Snips: Array[String]
var Error: String

var _vertex_response_extractor: RegEx
# var _markdown_snip_extractor: RegEx

func _init():
	self._vertex_response_extractor = RegEx.new()
	var pattern = '^\\s*\\{.*\\}\\s*$' # Basic pattern to check for something starting with { and ending with }
	self._vertex_response_extractor.compile(pattern)
	pass

func FromVertex(input: Variant) -> BotResponse:
	## dictionary["candidates"]["content"]["parts"]
	var all_parts_concatenated:String = ""
	
	if "candidates" not in input:
		FullText = "An error occurred."
		pass

	for candidate in input["candidates"]:
		if "content" not in candidate:
			FullText = "Model refused to answer. " +str(candidate)
			return
		var content = candidate["content"]
		for part in content["parts"]:
			for text in part["text"]:
				all_parts_concatenated += text
	
	## I might get back a JSON string because Google Vertex APIs have a bug
	## Where the result is an "instruct" formatted JSON object (even though Google uses different role words)
	var result = _vertex_response_extractor.search(all_parts_concatenated)

	if result:
		# turn the JSON into a dictionary, then grab the text property.
		var parsed: Variant = JSON.parse_string(all_parts_concatenated)
		FullText = parsed["parts"]["text"]
	else:
		FullText = all_parts_concatenated

	return self

# Parse out the markdown snips into the Snips array
func parse_snips():
	pass
