class_name SkillPresets
extends RefCounted
## Preset skill definitions that ship with Minerva.

static func get_all() -> Array[SkillDefinition]:
	var presets: Array[SkillDefinition] = []

	# General Assistant — broad tool access for everyday chat
	var general := SkillDefinition.new("general_assistant", "General Assistant",
		"Broad tool access for everyday chat and tasks")
	general.origin = "preset"
	general.tool_sets = ["chat", "notes", "editor", "utility"]
	presets.append(general)

	# PCB Design — specialized for electronics design work
	var pcb := SkillDefinition.new("pcb_design", "PCB Design",
		"Electronics design with PCB tools and editor")
	pcb.origin = "preset"
	pcb.tool_sets = ["pcb", "editor", "notes", "utility"]
	pcb.prompt_fragments = [
		"You are assisting with PCB and electronics design. Focus on schematic review, component selection, layout considerations, and design rule checks. When reviewing designs, be precise about pin assignments, trace widths, and clearances.",
	]
	presets.append(pcb)

	# Web Research — browsing and note-taking
	var web := SkillDefinition.new("web_research", "Web Research",
		"Web browsing with cobrowser and note-taking")
	web.origin = "preset"
	web.tool_sets = ["chat", "notes", "utility"]
	web.required_servers = ["cobrowser"]
	web.prompt_fragments = [
		"You have access to a web browser. Use cobrowser tools to navigate, read, and interact with web pages. Summarize findings clearly and save important information to notes.",
	]
	presets.append(web)

	# Code Assistant — coding with file manipulation tools
	var code := SkillDefinition.new("code_assistant", "Code Assistant",
		"Code editing with file tools and analysis")
	code.origin = "preset"
	code.tool_sets = ["chat", "notes", "editor", "autocoder", "utility"]
	code.required_servers = ["codetools"]
	code.prompt_fragments = [
		"You are a code assistant with file manipulation tools. Read files before editing, use glob/grep to search codebases, and write clean, well-structured code. Prefer editing existing files over creating new ones.",
	]
	presets.append(code)

	# Data Analysis — spreadsheet and data tools
	var data := SkillDefinition.new("data_analysis", "Data Analysis",
		"Data analysis with spreadsheet tools")
	data.origin = "preset"
	data.tool_sets = ["spreadsheet", "chat", "notes", "utility"]
	presets.append(data)

	# Project Management — kanban and tracking
	var pm := SkillDefinition.new("project_management", "Project Management",
		"Project tracking with kanban and notes")
	pm.origin = "preset"
	pm.tool_sets = ["kanban", "chat", "notes", "utility"]
	pm.required_servers = ["nudge"]
	presets.append(pm)

	# Full Access — everything enabled (no tool set filter)
	var full := SkillDefinition.new("full_access", "Full Access",
		"All tools enabled with no filtering")
	full.origin = "preset"
	full.tool_sets = []  # Empty = all enabled
	presets.append(full)

	return presets


## Get a preset by ID, or null
static func get_preset(id: String) -> SkillDefinition:
	for preset in get_all():
		if preset.id == id:
			return preset
	return null
