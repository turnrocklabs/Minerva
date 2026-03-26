class_name ToolSearchIndex
extends RefCounted
## Keyword-based search index for MCP tool discovery.
## Built at registration time, searched by minerva_tool_search.

## Inverted index: keyword → Array of tool names
var _keyword_index: Dictionary = {}

## Tool metadata: name → {description: String, tool_set: String}
var _tool_meta: Dictionary = {}

## All tool schemas: name → full schema Dictionary
var _tool_schemas: Dictionary = {}

## Words to skip in indexing (too common to be useful)
const STOP_WORDS: Array[String] = [
	"a", "an", "the", "to", "for", "of", "in", "on", "by", "or", "and",
	"is", "it", "its", "with", "from", "this", "that", "all", "can",
	"be", "as", "at", "if", "not", "no", "are", "was", "has", "have",
]


func register_tool(name: String, description: String, schema: Dictionary, tool_set: String = "") -> void:
	## Register a tool in the search index.
	_tool_meta[name] = {"description": description, "tool_set": tool_set}
	_tool_schemas[name] = schema

	# Tokenize name and description into keywords
	var text: String = name.replace("minerva_", "").replace("_", " ") + " " + description.to_lower()
	var words: PackedStringArray = text.split(" ", false)

	for word in words:
		# Clean punctuation
		word = word.strip_edges().trim_suffix(".").trim_suffix(",").trim_suffix(":")
		if word.length() < 2 or word in STOP_WORDS:
			continue
		if not _keyword_index.has(word):
			_keyword_index[word] = []
		if name not in _keyword_index[word]:
			_keyword_index[word].append(name)


func search(query: String, category: String = "", limit: int = 5) -> Array[Dictionary]:
	## Search for tools matching the query. Returns array of {name, description, schema}.

	# Exact name match — highest priority
	if _tool_schemas.has(query):
		return [_format_result(query)]

	# Also try with minerva_ prefix
	var prefixed: String = "minerva_" + query if not query.begins_with("minerva_") else query
	if _tool_schemas.has(prefixed):
		return [_format_result(prefixed)]

	# Keyword search
	var scores: Dictionary = {}  # tool_name → match count
	var query_words: PackedStringArray = query.to_lower().replace("_", " ").split(" ", false)

	for word in query_words:
		word = word.strip_edges().trim_suffix(".").trim_suffix(",")
		if word.length() < 2:
			continue

		# Exact keyword match
		if _keyword_index.has(word):
			for tool_name in _keyword_index[word]:
				scores[tool_name] = scores.get(tool_name, 0) + 2

		# Partial match (prefix)
		for indexed_word in _keyword_index:
			if indexed_word.begins_with(word) or word.begins_with(indexed_word):
				for tool_name in _keyword_index[indexed_word]:
					scores[tool_name] = scores.get(tool_name, 0) + 1

	# Filter by category if specified
	if not category.is_empty():
		var filtered: Dictionary = {}
		for tool_name in scores:
			if _tool_meta.has(tool_name) and _tool_meta[tool_name].tool_set == category:
				filtered[tool_name] = scores[tool_name]
		scores = filtered

	# Sort by score descending
	var sorted_tools: Array = []
	for tool_name in scores:
		sorted_tools.append({"name": tool_name, "score": scores[tool_name]})
	sorted_tools.sort_custom(func(a, b): return a.score > b.score)

	# Return top results with full schemas
	var results: Array[Dictionary] = []
	for i in range(mini(limit, sorted_tools.size())):
		results.append(_format_result(sorted_tools[i].name))

	return results


func get_all_tools_summary() -> Array[Dictionary]:
	## Return compact list of all tools (names + descriptions, no schemas).
	var result: Array[Dictionary] = []
	for name in _tool_meta:
		result.append({
			"name": name,
			"description": _tool_meta[name].description,
			"tool_set": _tool_meta[name].tool_set,
		})
	return result


func get_tool_count() -> int:
	return _tool_meta.size()


func _format_result(name: String) -> Dictionary:
	return {
		"name": name,
		"description": _tool_meta[name].description if _tool_meta.has(name) else "",
		"schema": _tool_schemas.get(name, {}),
	}
