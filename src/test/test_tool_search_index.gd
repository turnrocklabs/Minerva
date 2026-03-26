extends SceneTree
## Tests for ToolSearchIndex keyword search.
## Run: godot --headless --script test/test_tool_search_index.gd

var _pass_count: int = 0
var _fail_count: int = 0

func _init():
	print("=== ToolSearchIndex Tests ===\n")

	var index := _build_test_index()

	test_exact_name_match(index)
	test_exact_name_with_prefix(index)
	test_keyword_search(index)
	test_keyword_multi_word(index)
	test_category_filter(index)
	test_no_match(index)
	test_limit(index)
	test_all_tools_summary(index)
	test_partial_match(index)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass_count += 1
		print("  PASS: %s" % desc)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % desc)


func _build_test_index() -> ToolSearchIndex:
	var index := ToolSearchIndex.new()
	index.register_tool("minerva_file_read", "Read file contents with line numbers", {"name": "minerva_file_read", "description": "Read file"}, "codetools")
	index.register_tool("minerva_file_write", "Write content to a file. Creates directories if needed", {"name": "minerva_file_write", "description": "Write file"}, "codetools")
	index.register_tool("minerva_file_edit", "Replace a string in a file. old_string must be unique", {"name": "minerva_file_edit", "description": "Edit file"}, "codetools")
	index.register_tool("minerva_bash", "Execute a shell command", {"name": "minerva_bash", "description": "Run command"}, "codetools")
	index.register_tool("minerva_pcb_add_annotation", "Add an annotation to the PCB (arrow, text, region, polyline). Call minerva_pcb_describe_component first.", {"name": "minerva_pcb_add_annotation", "description": "Add PCB annotation"}, "pcb")
	index.register_tool("minerva_pcb_describe_component", "Describe a PCB component with its pins and position", {"name": "minerva_pcb_describe_component", "description": "Describe component"}, "pcb")
	index.register_tool("minerva_send_message", "Send a message to a chat. Requires chat_id from minerva_list_chats.", {"name": "minerva_send_message", "description": "Send message"}, "chat")
	index.register_tool("minerva_create_spreadsheet_editor", "Create a new spreadsheet editor", {"name": "minerva_create_spreadsheet_editor", "description": "Create spreadsheet"}, "spreadsheet")
	index.register_tool("minerva_format_cells", "Apply formatting to cells. Requires editor_name from minerva_list_editors.", {"name": "minerva_format_cells", "description": "Format cells"}, "spreadsheet")
	index.register_tool("minerva_create_chart", "Create a chart from spreadsheet data. Requires editor_name.", {"name": "minerva_create_chart", "description": "Create chart"}, "spreadsheet")
	return index


func test_exact_name_match(index: ToolSearchIndex):
	print("test_exact_name_match:")
	var results := index.search("minerva_file_edit")
	check("exact match returns 1 result", results.size() == 1)
	check("correct tool returned", results[0].name == "minerva_file_edit")
	check("schema included", not results[0].schema.is_empty())


func test_exact_name_with_prefix(index: ToolSearchIndex):
	print("test_exact_name_with_prefix:")
	var results := index.search("file_edit")
	check("prefix-less name finds tool", results.size() == 1)
	check("correct tool", results[0].name == "minerva_file_edit")


func test_keyword_search(index: ToolSearchIndex):
	print("test_keyword_search:")
	var results := index.search("edit file")
	check("keyword search finds results", results.size() > 0)
	# file_edit should rank highest (matches both "edit" and "file")
	check("file_edit ranked first", results[0].name == "minerva_file_edit")


func test_keyword_multi_word(index: ToolSearchIndex):
	print("test_keyword_multi_word:")
	var results := index.search("pcb annotation")
	check("finds pcb annotation tool", results.size() > 0)
	var found := false
	for r in results:
		if r.name == "minerva_pcb_add_annotation":
			found = true
			break
	check("pcb_add_annotation in results", found)


func test_category_filter(index: ToolSearchIndex):
	print("test_category_filter:")
	var results := index.search("create", "spreadsheet")
	check("category filter returns results", results.size() > 0)
	var all_spreadsheet := true
	for r in results:
		if r.name != "minerva_create_spreadsheet_editor" and r.name != "minerva_create_chart":
			all_spreadsheet = false
	check("all results are spreadsheet tools", all_spreadsheet)


func test_no_match(index: ToolSearchIndex):
	print("test_no_match:")
	var results := index.search("xyznonexistent")
	check("no match returns empty", results.size() == 0)


func test_limit(index: ToolSearchIndex):
	print("test_limit:")
	var results := index.search("file", "", 2)
	check("limit caps results", results.size() <= 2)


func test_all_tools_summary(index: ToolSearchIndex):
	print("test_all_tools_summary:")
	var summary := index.get_all_tools_summary()
	check("summary has all tools", summary.size() == 10)
	check("summary has name field", summary[0].has("name"))
	check("summary has description", summary[0].has("description"))
	check("summary has no schema", not summary[0].has("schema"))


func test_partial_match(index: ToolSearchIndex):
	print("test_partial_match:")
	var results := index.search("annot")  # partial for "annotation"
	check("partial match finds results", results.size() > 0)
	var found := false
	for r in results:
		if r.name == "minerva_pcb_add_annotation":
			found = true
	check("partial matches pcb_add_annotation", found)
