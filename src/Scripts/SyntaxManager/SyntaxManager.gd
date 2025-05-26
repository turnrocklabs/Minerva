class_name SyntaxManager
extends Node

static var _ext_to_name: = {
	"rs" : "rust",
	"js" : "javascript",
	"ts" : "typescript",
	"py" : "python",
	"gd" : "gdscript"
}

# Cache for loaded syntax definitions
static var _syntax_cache: = {}
static var _color_groups: = {}



func _ready():
	# Load color groups
	_load_color_groups()

func _load_color_groups():
	var file_path: = "res://resources/syntax/color_groups.tres"
	var err := ResourceLoader.load_threaded_request(file_path)
	
	if err == OK:
		var groups_resource: JSON = ResourceLoader.load_threaded_get(file_path)
		
		# Check if the resource is valid and has JSON data
		if groups_resource and groups_resource.data:
		# Access the "colorGroups" dictionary from the JSON data
			if groups_resource.data.has("colorGroups"):
				_color_groups = groups_resource.data.colorGroups
			else:
				push_warning("JSON resource doesn't contain 'colorGroups' key")
		else:
			push_warning("Invalid JSON resource format")
	else:
		push_warning("Failed to load color groups resource")

func get_syntax_for_language(lang_name: String) -> Dictionary:
	# Strip any numbers or special characters from the language name
	var clean_lang: = lang_name.rstrip("01234567890!#$%&/()=.,+*{}[]").strip_edges()
	# extensions dictionary
	if _ext_to_name.has(clean_lang):
		clean_lang = _ext_to_name.get(clean_lang)
	# Return from cache if available
	if _syntax_cache.has(clean_lang):
		return _syntax_cache[clean_lang]
	
	var file_path: = "res://resources/syntax/" + clean_lang + ".tres"
	var err := ResourceLoader.load_threaded_request(file_path)
	
	if err == OK:
		var lang_resource: JSON = ResourceLoader.load_threaded_get(file_path)
		
		# Check if the resource is valid and has JSON data
		if lang_resource and lang_resource.data:
			if lang_resource.data.has("keywords"):
				_syntax_cache.set(clean_lang, lang_resource.data.keywords)
				return lang_resource.data.keywords
			else:
				push_warning("JSON resource doesn't contain 'colorGroups' key")
		else:
			push_warning("Invalid JSON resource format")
	else:
		push_warning("No syntax resource found for language: " + clean_lang)
	
	# Return empty dictionary if loading failed
	return {}

func get_color_groups() -> Dictionary:
	return _color_groups
