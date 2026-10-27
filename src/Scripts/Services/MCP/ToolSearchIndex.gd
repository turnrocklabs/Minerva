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


func register_tool(name: String, description: String, schema: Dictionary, tool_set: String = "", plugin_id: String = "", plugin_name: String = "") -> void:
	## Register a tool in the search index.
	if _tool_meta.has(name):
		unregister_tool(name)
	_tool_meta[name] = {"description": description, "tool_set": tool_set, "plugin_id": plugin_id}
	_tool_schemas[name] = schema

	# Tokenize name and description into keywords
	var text: String = (name.replace("minerva_", "").replace("_", " ") + " " + description + " " + plugin_id + " " + plugin_name).to_lower().replace("\n", " ")
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


func unregister_tool(name: String) -> void:
	_tool_meta.erase(name)
	_tool_schemas.erase(name)
	for word: Variant in _keyword_index.keys():
		var names: Array = _keyword_index[word]
		names.erase(name)
		if names.is_empty():
			_keyword_index.erase(word)


func search(query: String, category: String = "", limit: int = 5, plugin_id: String = "") -> Array[Dictionary]:
	## Search for tools matching the query. Returns array of {name, description, schema}.
	## If query is empty or "*", returns all tools (optionally filtered by category).

	# List all in category (or all tools) when query is empty or wildcard
	var clean_query := query.strip_edges()
	if clean_query.is_empty() or clean_query == "*":
		var all_results: Array[Dictionary] = []
		for name in _tool_meta:
			if not _matches(name, category, plugin_id):
				continue
			all_results.append(_format_result(name))
			if all_results.size() >= limit:
				break
		return all_results

	# Exact name match — highest priority
	if _tool_schemas.has(query) and _matches(query, category, plugin_id):
		return [_format_result(query)]

	# Also try with minerva_ prefix
	var prefixed: String = "minerva_" + query if not query.begins_with("minerva_") else query
	if _tool_schemas.has(prefixed) and _matches(prefixed, category, plugin_id):
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

	# Origin and functional category are independent, exact filters.
	if not category.is_empty() or not plugin_id.is_empty():
		var filtered: Dictionary = {}
		for tool_name in scores:
			if _matches(tool_name, category, plugin_id):
				filtered[tool_name] = scores[tool_name]
		scores = filtered

	# Sort by score descending
	var sorted_tools: Array = []
	for tool_name in scores:
		sorted_tools.append({"name": tool_name, "score": scores[tool_name]})
	sorted_tools.sort_custom(func(a, b): return a.score > b.score)

	# Suppress native tools unless query explicitly requests them.
	# Tools with "_native_" in their name require explicit OS-level permissions
	# and should not surface in general searches.
	var want_native: bool = "native" in query.to_lower()

	# Return top results with full schemas
	var results: Array[Dictionary] = []
	for i in range(sorted_tools.size()):
		if results.size() >= limit:
			break
		var tname: String = sorted_tools[i].name
		if not want_native and "_native_" in tname:
			continue
		results.append(_format_result(tname))

	return results


func get_all_tools_summary() -> Array[Dictionary]:
	## Return compact list of all tools (names + descriptions, no schemas).
	var result: Array[Dictionary] = []
	for name: String in _tool_meta:
		var metadata: Dictionary = _tool_meta[name]
		result.append({
			"name": name,
			"description": metadata.description,
			"tool_set": metadata.tool_set,
			"category": metadata.tool_set,
			"plugin_id": metadata.plugin_id,
		})
	return result


func get_tool_count() -> int:
	return _tool_meta.size()


func _format_result(name: String) -> Dictionary:
	var metadata: Dictionary = _tool_meta.get(name, {})
	return {
		"name": name,
		"description": metadata.description if _tool_meta.has(name) else "",
		"category": metadata.tool_set,
		"plugin_id": metadata.plugin_id,
		"schema": _tool_schemas.get(name, {}),
	}


func _matches(name: String, category: String, plugin_id: String) -> bool:
	var metadata: Dictionary = _tool_meta.get(name, {})
	return _tool_meta.has(name) and (category.is_empty() or metadata.tool_set == category) \
		and (plugin_id.is_empty() or metadata.plugin_id == plugin_id)


func categories() -> Dictionary:
	var counts: Dictionary = {}
	for metadata: Dictionary in _tool_meta.values():
		var category: String = metadata.tool_set
		if not category.is_empty():
			counts[category] = int(counts.get(category, 0)) + 1
	return counts
