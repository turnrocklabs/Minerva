class_name PassthroughLaunchDialog
extends Window
## Passthrough launch dialog (chat-passthrough W3). Replaces W2's placeholder
## picker behind the "⇅" top-bar button.
##
## Two launch paths:
##   NEW SESSION  — creates a BACKGROUND terminal session (T2 registry), runs
##                  the startup command in it under a login-shell environment,
##                  starts the agent-relay watch, and binds a passthrough chat
##                  once the provider entry appears in the registry.
##   BIND EXISTING — skips session creation + command; starts the watch on a
##                  terminal the user already has, then the same await + bind.
##
## Construction idiom follows AgentManagerWindow (code-built Window + VBox +
## LineEdits + OptionButtons; no .tscn).
##
## Injectable seams (headless-testable without the agent-relay plugin):
##   watch_starter: Callable({terminal_id, profile}) -> Dictionary
##       Default dispatches the plugin tool through PluginToolRegistry (the
##       same internal path MCP dispatch uses). Tests inject a stub.
##   chat_starter: Callable(entry_key, display_name, terminal_id, command, cwd)
##       ChatPane wires this to launch_passthrough_chat. Tests inject a stub.

## v1 COUPLING (deliberate, documented): core knows the agent-relay plugin's
## tool name + entry-id scheme here. B7's TerminalProvider registers entry_id
## "terminal-<tid>" → key "plugin:agent_relay:terminal-<tid>" when watch_start
## succeeds. A later round can generalize this to a capability-advertised
## "launchable provider" contract; for v1 the dialog IS the agent-relay UX.
const AGENT_RELAY_PLUGIN_ID := "agent_relay"
const AGENT_RELAY_WATCH_TOOL := "minerva_agent_relay_watch_start"

## Profiles the agent-relay watch understands (override allowed in the form).
const PROFILES: Array[String] = ["claude", "codex", "opencode"]

## How long to wait for the provider entry to appear after watch_start
## succeeds. Tests shrink this.
var entry_wait_timeout_sec: float = 10.0

## Injectable watch seam — see header. Empty Callable → _default_watch_start.
var watch_starter: Callable = Callable()

## Injectable chat-creation seam — see header. Empty Callable → error (the
## owning ChatPane must wire it).
var chat_starter: Callable = Callable()

# --- form controls (code-built) ---
var _name_edit: LineEdit
var _command_edit: LineEdit
var _cwd_edit: LineEdit
var _cwd_browse_button: Button
var _cwd_dialog: FileDialog
var _profile_dropdown: OptionButton
var _existing_dropdown: OptionButton
var _error_label: Label
var _start_button: Button
var _cancel_button: Button

## Existing-terminal ids parallel to _existing_dropdown items (index 0 = new).
var _existing_ids: Array[String] = []

## True once the user manually picked a profile — stops auto-inference.
var _profile_overridden: bool = false

## True while a Start attempt is in flight (debounce).
var _launching: bool = false


func _init() -> void:
	title = "New Passthrough Chat"
	size = Vector2i(520, 360)
	min_size = Vector2i(440, 320)
	transient = true
	exclusive = false
	wrap_controls = true
	close_requested.connect(hide)


func _ready() -> void:
	if get_tree() != null and get_tree().root != null:
		content_scale_factor = get_tree().root.content_scale_factor
	_build_ui()


# ---------------------------------------------------------------------------
# Pure helpers (unit-tested)
# ---------------------------------------------------------------------------

## Infer the agent-relay profile from the startup command (W3 contract):
## contains "claude" → claude; "codex" → codex; "opencode" → opencode;
## anything else → default "claude".
static func infer_profile(command: String) -> String:
	var c := command.to_lower()
	if c.contains("claude"):
		return "claude"
	if c.contains("codex"):
		return "codex"
	if c.contains("opencode"):
		return "opencode"
	return "claude"


## Defensive POSIX single-quote wrapping: 'foo' with embedded single quotes
## escaped as '\'' — safe to splice into a shell line.
static func shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"


## The exact PTY incantation for the startup command. `exec bash -lc` is the
## v1 answer to the nvm-PATH gotcha: a bare forkpty shell lacks the user's
## login PATH (codex died on it); bash -lc sources the login profile, and exec
## replaces the wrapper shell so the agent owns the PTY + its exit code.
static func build_launch_line(command: String) -> String:
	return "exec bash -lc %s\r" % shell_quote(command)


## The cd line written before the launch line when a working dir is set.
static func build_cd_line(cwd: String) -> String:
	return "cd %s\r" % shell_quote(cwd)


## Registry key the agent-relay provider entry appears under for a terminal.
static func entry_key_for_terminal(terminal_id: String) -> String:
	return "plugin:%s:terminal-%s" % [AGENT_RELAY_PLUGIN_ID, terminal_id]


# ---------------------------------------------------------------------------
# UI construction (AgentManagerWindow idiom)
# ---------------------------------------------------------------------------

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# Session name (required — chat title + terminal session name)
	vbox.add_child(_label("Session name:"))
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "e.g. Claude on Minerva"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_name_edit)

	# Startup command (empty = bare shell)
	vbox.add_child(_label("Startup command (empty = bare shell):"))
	_command_edit = LineEdit.new()
	_command_edit.placeholder_text = "e.g. claude --dangerously-skip-permissions"
	_command_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_command_edit.text_changed.connect(_on_command_changed)
	vbox.add_child(_command_edit)

	# Working directory (optional). Typed OR picked: the Browse… button opens a
	# directory chooser that only FILLS the LineEdit — the text stays the single
	# source of truth, so both entry styles go through the same validation.
	vbox.add_child(_label("Working directory (optional):"))
	var cwd_row := HBoxContainer.new()
	cwd_row.add_theme_constant_override("separation", 6)
	vbox.add_child(cwd_row)
	_cwd_edit = LineEdit.new()
	_cwd_edit.placeholder_text = "e.g. /home/me/project"
	_cwd_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cwd_row.add_child(_cwd_edit)
	_cwd_browse_button = Button.new()
	_cwd_browse_button.text = "Browse…"
	_cwd_browse_button.pressed.connect(_on_cwd_browse_pressed)
	cwd_row.add_child(_cwd_browse_button)

	# Profile (auto-inferred from command; manual pick sticks)
	vbox.add_child(_label("Agent profile:"))
	_profile_dropdown = OptionButton.new()
	_profile_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in PROFILES:
		_profile_dropdown.add_item(p)
	_profile_dropdown.select(0)
	_profile_dropdown.item_selected.connect(func(_idx: int): _profile_overridden = true)
	vbox.add_child(_profile_dropdown)

	# Alternate path: bind to an existing terminal session
	vbox.add_child(_label("Terminal:"))
	_existing_dropdown = OptionButton.new()
	_existing_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_existing_dropdown.item_selected.connect(_on_existing_selected)
	vbox.add_child(_existing_dropdown)
	_refresh_existing_dropdown()

	# Inline error (dialog stays open on validation/launch failure)
	_error_label = Label.new()
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	_error_label.visible = false
	vbox.add_child(_error_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	# Buttons
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)

	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(hide)
	buttons.add_child(_cancel_button)

	_start_button = Button.new()
	_start_button.text = "Start"
	_start_button.pressed.connect(_on_start_pressed)
	buttons.add_child(_start_button)


## Open the dialog: refresh the existing-terminal list and center it.
func popup_launch() -> void:
	_set_error("")
	_refresh_existing_dropdown()
	popup_centered()
	if _name_edit:
		_name_edit.grab_focus()


func _refresh_existing_dropdown() -> void:
	if _existing_dropdown == null:
		return
	var prev_id: String = ""
	if _existing_dropdown.selected > 0 and _existing_dropdown.selected < _existing_ids.size():
		prev_id = _existing_ids[_existing_dropdown.selected]
	_existing_dropdown.clear()
	_existing_ids.clear()
	_existing_dropdown.add_item("New background terminal")
	_existing_ids.append("")
	var registry = _get_session_registry()
	if registry != null:
		for session in registry.list_sessions():
			if not session.is_alive():
				continue  # dead shells can't host an agent
			_existing_dropdown.add_item("%s (id %s)" % [session.session_name, session.terminal_id])
			_existing_ids.append(str(session.terminal_id))
	var idx: int = _existing_ids.find(prev_id)
	_existing_dropdown.select(idx if idx >= 0 else 0)
	_on_existing_selected(_existing_dropdown.selected)


func _on_existing_selected(idx: int) -> void:
	# Binding to an existing terminal disables the command/cwd fields — the
	# agent is presumed already running (or the user drives it by hand).
	var bind_existing: bool = idx > 0
	if _command_edit:
		_command_edit.editable = not bind_existing
	if _cwd_edit:
		_cwd_edit.editable = not bind_existing
	if _cwd_browse_button:
		_cwd_browse_button.disabled = bind_existing


## Open the directory chooser for the working-directory field. Uses the core
## directory-picker idiom (menuMain/PreferencesPopup): Godot's own FileDialog
## with ACCESS_FILESYSTEM — engine-rendered, so it behaves identically on
## Linux/macOS/Windows. The pick only fills the LineEdit; Start still
## validates the text like a typed path.
func _on_cwd_browse_pressed() -> void:
	if _cwd_dialog == null:
		_cwd_dialog = FileDialog.new()
		_cwd_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_cwd_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_cwd_dialog.title = "Choose Working Directory"
		_cwd_dialog.min_size = Vector2i(600, 400)
		_cwd_dialog.transient = true
		_cwd_dialog.dir_selected.connect(func(path: String) -> void:
			if _cwd_edit:
				_cwd_edit.text = path)
		add_child(_cwd_dialog)
	# Start browsing from the typed path when it points at a real directory.
	var typed: String = _cwd_edit.text.strip_edges() if _cwd_edit else ""
	if not typed.is_empty() and DirAccess.dir_exists_absolute(typed):
		_cwd_dialog.current_dir = typed
	_cwd_dialog.popup_centered()


func _on_command_changed(text: String) -> void:
	if _profile_overridden or _profile_dropdown == null:
		return
	var inferred := infer_profile(text)
	var idx: int = PROFILES.find(inferred)
	if idx >= 0:
		_profile_dropdown.select(idx)


func selected_profile() -> String:
	if _profile_dropdown == null or _profile_dropdown.selected < 0:
		return "claude"
	return _profile_dropdown.get_item_text(_profile_dropdown.selected)


func _set_error(msg: String) -> void:
	if _error_label == null:
		return
	_error_label.text = msg
	_error_label.visible = not msg.is_empty()


func current_error() -> String:
	return _error_label.text if _error_label != null and _error_label.visible else ""


# ---------------------------------------------------------------------------
# Launch flow
# ---------------------------------------------------------------------------

func _get_session_registry():
	if SingletonObject.has_method("get_terminal_session_registry"):
		return SingletonObject.get_terminal_session_registry()
	return null


func _on_start_pressed() -> void:
	if _launching:
		return
	_set_error("")

	# --- validation (inline errors; dialog stays open) ---
	var session_name: String = _name_edit.text.strip_edges()
	if session_name.is_empty():
		_set_error("Session name is required.")
		return

	var bind_existing: bool = _existing_dropdown.selected > 0
	var command: String = _command_edit.text.strip_edges()
	var cwd: String = _cwd_edit.text.strip_edges()
	if not bind_existing and not cwd.is_empty() \
			and not DirAccess.dir_exists_absolute(cwd):
		_set_error("Working directory does not exist: %s" % cwd)
		return

	var registry = _get_session_registry()
	if registry == null:
		_set_error("Terminal session registry unavailable.")
		return

	_launching = true
	if _start_button:
		_start_button.disabled = true
		_start_button.text = "Starting…"
	await _do_launch(session_name, bind_existing, command, cwd, registry)
	_launching = false
	if _start_button:
		_start_button.disabled = false
		_start_button.text = "Start"


func _do_launch(session_name: String, bind_existing: bool, command: String,
		cwd: String, registry) -> void:
	var terminal_id: String = ""
	var created_session := false

	if bind_existing:
		var sel: int = _existing_dropdown.selected
		if sel <= 0 or sel >= _existing_ids.size():
			_set_error("Select a terminal to bind to.")
			return
		terminal_id = _existing_ids[sel]
		if not registry.has_session(terminal_id):
			_set_error("That terminal no longer exists — refresh and retry.")
			_refresh_existing_dropdown()
			return
		command = ""  # bind path stores no relaunch command (we didn't start it)
		cwd = ""
	else:
		# --- create the background session (T2 registry path) ---
		var session = registry.create_session(session_name, 80, 24)
		if session == null or not session.terminal_available or not session.started:
			if session != null:
				registry.close_session(session.terminal_id)
			_set_error("Failed to start a background terminal (extension unavailable or forkpty failed).")
			return
		terminal_id = str(session.terminal_id)
		created_session = true

		# cd first (quoted), then exec the agent under a login-shell env.
		if not cwd.is_empty():
			session.write_input(build_cd_line(cwd))
		if not command.is_empty():
			session.write_input(build_launch_line(command))

	# --- watch seam ---
	var watch_result: Dictionary = await _call_watch_starter(terminal_id)
	if not watch_result.get("ok", false):
		if created_session:
			registry.close_session(terminal_id)  # no orphans
		_set_error("Agent watch failed — is the agent-relay plugin running? (%s)"
				% str(watch_result.get("error", "unknown error")))
		return

	# --- await the provider entry the watch registers ---
	var entry_key := entry_key_for_terminal(terminal_id)
	var appeared: bool = await _await_provider_entry(entry_key, entry_wait_timeout_sec)
	if not appeared:
		if created_session:
			registry.close_session(terminal_id)  # no orphans
		_set_error("Watch started but no chat provider appeared for terminal %s — is the agent-relay plugin running?"
				% terminal_id)
		return

	# --- bind the chat ---
	if not chat_starter.is_valid():
		if created_session:
			registry.close_session(terminal_id)
		_set_error("Internal error: no chat starter wired.")
		return
	# (await on a non-coroutine value is a no-op in Godot 4 — safe either way)
	var history = await chat_starter.call(entry_key, session_name, terminal_id, command, cwd)
	if history == null:
		if created_session:
			registry.close_session(terminal_id)
		_set_error("Could not create the passthrough chat (provider entry vanished?).")
		return

	hide()


## Dispatch the watch seam. Injected Callable receives {terminal_id, profile}
## and returns a Dictionary; {ok: false} / {error: ...} / {isError: true} all
## count as failure.
func _call_watch_starter(terminal_id: String) -> Dictionary:
	var args := {"terminal_id": terminal_id, "profile": selected_profile()}
	var raw
	if watch_starter.is_valid():
		# (await on a non-coroutine value is a no-op in Godot 4)
		raw = await watch_starter.call(args)
	else:
		raw = await _default_watch_start(args)
	if raw is Dictionary:
		return _classify_watch_result(raw)
	return {"ok": false, "error": "watch seam returned %s" % str(raw)}


## Default watch implementation: call the agent-relay plugin tool by name
## through PluginToolRegistry.handle_tool_call — the same internal path MCP
## dispatch uses (plugin-running check, policy, connection, envelope
## normalization, audit log).
func _default_watch_start(args: Dictionary) -> Dictionary:
	var reg = SingletonObject.plugin_tool_registry if "plugin_tool_registry" in SingletonObject else null
	if reg == null or not reg.has_method("handle_tool_call"):
		return {"ok": false, "error": "plugin tool registry unavailable"}
	var raw: Dictionary = await reg.handle_tool_call(AGENT_RELAY_WATCH_TOOL, args)
	return _classify_watch_result(raw)


## Unwrap/classify a tool result. handle_tool_call normally returns the
## already-normalized payload (MCPServerConnection._normalize_mcp_tool_result
## strips the {content:[{type:"text",text:...}]} envelope), but unwrap
## defensively in case a raw envelope leaks through, and treat
## {error}/{isError}/{success:false} as failure.
static func _classify_watch_result(raw: Dictionary) -> Dictionary:
	var result: Dictionary = raw
	if result.has("content") and result["content"] is Array:
		var content: Array = result["content"]
		if content.size() > 0 and content[0] is Dictionary \
				and content[0].get("type", "") == "text":
			var parsed = JSON.parse_string(str(content[0].get("text", "{}")))
			if parsed is Dictionary:
				var merged: Dictionary = parsed
				if bool(result.get("isError", false)):
					merged["isError"] = true
				result = merged
	if bool(result.get("isError", false)):
		return {"ok": false, "error": str(result.get("error", result))}
	if result.has("error") and result["error"]:
		return {"ok": false, "error": str(result["error"])}
	if result.has("success") and not bool(result["success"]):
		return {"ok": false, "error": str(result.get("message", result))}
	return {"ok": true, "result": result}


## Poll the W1 registry until the entry appears or the timeout lapses.
## (chat_providers_changed has no payload, so a frame-poll is the simplest
## race-free await — at most ~600 cheap has_entry checks for the 10s default.)
func _await_provider_entry(entry_key: String, timeout_sec: float) -> bool:
	var cpr = SingletonObject.plugin_chat_provider_registry if "plugin_chat_provider_registry" in SingletonObject else null
	if cpr == null or not cpr.has_method("has_entry"):
		return false
	if cpr.has_entry(entry_key):
		return true
	var loop := Engine.get_main_loop()
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await loop.process_frame
		if cpr.has_entry(entry_key):
			return true
	return false
