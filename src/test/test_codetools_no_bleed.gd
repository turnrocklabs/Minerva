extends SceneTree
## No-bleed boundary test (DCR 019e7b6609 P2.3, contract comment 410).
##
## Run: godot --headless --path src --script test/test_codetools_no_bleed.gd
##
## Asserts core Minerva registers NONE of the file-primitive / code-intelligence
## tools — those live only in the optional `codetools` marketplace plugin as
## minerva_codetools_*. The agent file *tools* belong to the sidecar; only the
## generic platform stays in core.
##
## Forbidden on the CORE server ("minerva"):
##   - minerva_file_glob / minerva_file_grep / minerva_bash / minerva_cwd
##     (removed in P2.3; no core tool may re-register them)
##   - minerva_file_read / minerva_file_write / minerva_file_edit (never core; defensive)
##   - any minerva_codetools_* registered by the CORE server (plugin-namespaced)
##
## Positive sanity: core STILL has the kept document tools (minerva_doc_read).

const FORBIDDEN_EXACT := [
	"minerva_file_glob",
	"minerva_file_grep",
	"minerva_bash",
	"minerva_cwd",
	"minerva_file_read",
	"minerva_file_write",
	"minerva_file_edit",
]
const CORE_SERVER := "minerva"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== CodeTools No-Bleed Boundary Test (P2.3) ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	# Let the SingletonObject autoload finish so the MCP tool registry is built.
	await process_frame
	await process_frame

	var so = root.get_node_or_null("SingletonObject")
	if so == null or so.get("mcp_manager") == null \
			or so.mcp_manager.get("tool_registry") == null:
		print("  SKIP: SingletonObject / mcp_manager.tool_registry not available")
		return

	var registry: Dictionary = so.mcp_manager.tool_registry

	# 1. None of the forbidden exact names exist anywhere in the registry.
	for name in FORBIDDEN_EXACT:
		_check("forbidden tool '%s' is NOT registered" % name, not registry.has(name))

	# 2. The CORE server registers no plugin-namespaced minerva_codetools_* tool.
	var core_bleed: Array = []
	for tool_name in registry.keys():
		var tool = registry[tool_name]
		var sname: String = str(tool.get("server_name")) if tool is Object else ""
		if sname == CORE_SERVER and tool_name.begins_with("minerva_codetools_"):
			core_bleed.append(tool_name)
	_check("core server registers no minerva_codetools_* (%s)" % str(core_bleed),
		core_bleed.is_empty())

	# 3. Positive sanity — the kept document tools are still core.
	_check("core STILL registers minerva_doc_read", registry.has("minerva_doc_read"))
	_check("core STILL registers minerva_disk_read", registry.has("minerva_disk_read"))


func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		print("  FAIL: %s" % label)
