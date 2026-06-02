class_name MCPOSTools
extends MCPToolModule
## MCP tool module for OS-level actions. Currently: minerva_os_open, which opens
## a file in the OS default application (PDF viewer, image viewer, …) so the user
## can preview/print it — the cross-platform OS.shell_open (xdg-open / open /
## start) under the hood.
##
## GATING (W11): OS.shell_open can launch executables, so opening is allowlisted
## by OSOpenPolicy — a path is allowed if its extension is a known-safe
## document/media type OR its filename is in a user-approved named-binary
## allowlist (e.g. "Docket.app"). Both lists are extendable WITHOUT a recompile
## via the user config_file [OSOpen] section (extra_extensions, allowed_binaries)
## — defaults live in code so a fresh binary install works with zero config. See
## work-item 019e89eb8951 / policy-discoverability 019e8a27092e.


func _init(mcp_server = null) -> void:
	super._init(mcp_server)


func get_tool_names() -> Array[String]:
	return ["minerva_os_open"]


func register_tools() -> void:
	server._register_tool("minerva_os_open",
		"Open a file in the OS default application (e.g. the system PDF viewer, for preview/print) via the OS handler. NOT the same as minerva_open_file, which opens an in-app editor tab. Allowlisted for safety: the path's extension must be a known-safe document/media type, or its filename must be in the user's approved app allowlist (config_file [OSOpen] allowed_binaries). Refuses anything else.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute path to the file (or app bundle) to open in its OS default handler."},
		}, "required": ["path"]}, "general")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_os_open": return _os_open(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


# ── Implementation ───────────────────────────────────────────────────────────

func _os_open(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return _err("path is required")
	if not path.is_absolute_path():
		return _err("path must be absolute")
	# .app bundles are directories, so accept either a file or a directory.
	var exists: bool = FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)
	if not exists:
		return _err("path not found: %s" % path)

	var extra: PackedStringArray = _config_list("extra_extensions")
	var bins: PackedStringArray = _config_list("allowed_binaries")
	if not OSOpenPolicy.is_allowed(path, extra, bins):
		return _err(("refused to open %s — not an allowed type. Allowed extensions: %s " +
			"(extend via config_file [OSOpen] extra_extensions), or add its filename to " +
			"[OSOpen] allowed_binaries to approve a specific app.") % [path.get_file(), ", ".join(OSOpenPolicy.DEFAULT_EXTENSIONS)])

	var rc: int = OS.shell_open(path)
	if rc != OK:
		return _err("OS.shell_open failed (error %d) for %s" % [rc, path])
	return _ok({"opened": true, "path": path})


## Read a comma-separated (or array) override list from config_file [OSOpen].
## Defaults to empty when the config/section/key is absent (fresh install).
func _config_list(key: String) -> PackedStringArray:
	var out: PackedStringArray = []
	if not SingletonObject or not SingletonObject.config_file:
		return out
	var raw: Variant = SingletonObject.config_file.get_value("OSOpen", key, "")
	if raw is String:
		for part in str(raw).split(",", false):
			var s: String = str(part).strip_edges()
			if s != "":
				out.append(s)
	elif raw is Array or raw is PackedStringArray:
		for part in raw:
			var s: String = str(part).strip_edges()
			if s != "":
				out.append(s)
	return out


# ── Local response helpers (mirror MCPDiskTools to stay headless-testable) ──

static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}
