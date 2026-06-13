extends SceneTree
## Test: v1 restart semantics of background terminal sessions
## (chat-passthrough DCR, T3).
##
## Run: godot --headless --path src --script test/test_terminal_restart_semantics.gd
##
## Locks the deliberate v1 contract (Docs/Plugin-platform-policy.md,
## "Lifecycle & restart semantics"):
##   1. Sessions are in-memory only — creating + using background sessions
##      writes NO new file anywhere under user:// (behavioral check), and the
##      registry exposes NO persistence API (no save/serialize/restore methods).
##   2. Code-level statement of the same: TerminalSessionRegistry.gd and
##      TerminalSession.gd contain no FileAccess/ConfigFile/store_/user://
##      tokens (a grep assertion, kept here as living documentation).
##   3. Fresh-boot emptiness: a second registry instance (simulating a fresh
##      boot — the registry is process-local state, nothing rehydrates it)
##      lists ZERO sessions while the first registry's sessions still run.
##
## Same harness hygiene as test_background_terminals.gd: scripts that name the
## SingletonObject autoload are load()ed at runtime; sessions are duck-typed.

const REGISTRY_SCRIPT_PATH := "res://Scripts/Services/Terminal/TerminalSessionRegistry.gd"
const SESSION_SCRIPT_PATH := "res://Scripts/Services/Terminal/TerminalSession.gd"

## Methods a persistence-bearing registry would expose. The registry must have
## NONE of these — persistence is deliberately absent in v1.
const PERSISTENCE_METHODS := [
	"save", "save_state", "save_sessions", "serialize", "to_dict", "to_json",
	"persist", "write_state", "restore", "load_state", "load_sessions",
	"deserialize", "rehydrate",
]

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Terminal Restart Semantics Tests (T3) ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		printerr(msg)


## Recursive file listing under an absolute directory path → {path: true}.
func _snapshot_files(path: String, acc: Dictionary) -> void:
	var da := DirAccess.open(path)
	if da == null:
		return
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if f != "." and f != "..":
			var full := path.path_join(f)
			if da.current_is_dir():
				_snapshot_files(full, acc)
			else:
				acc[full] = true
		f = da.get_next()
	da.list_dir_end()


func _run() -> void:
	await process_frame
	await process_frame

	# ── 2. Code-level no-persistence grep (no PTY needed — always runs) ──
	print("-- code-level: registry/session sources have no persistence calls --")
	for script_path in [REGISTRY_SCRIPT_PATH, SESSION_SCRIPT_PATH]:
		var src := FileAccess.get_file_as_string(script_path)
		check("%s is readable" % script_path, not src.is_empty())
		for token in ["FileAccess", "ConfigFile", "store_", "user://"]:
			check("%s contains no '%s'" % [script_path.get_file(), token],
				src.find(token) == -1)

	if not ClassDB.class_exists("Terminal"):
		print("  SKIP: Terminal GDExtension not available — live PTY tests skipped")
		return

	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		print("  SKIP: SingletonObject autoload not available under this invocation")
		return

	var registry = so.get_terminal_session_registry()
	check("registry available off SingletonObject", registry != null)
	if registry == null:
		return

	# ── 1a. Registry exposes NO persistence API ──────────────────────────
	print("\n-- registry exposes no persistence API --")
	for m in PERSISTENCE_METHODS:
		check("registry has no '%s()' method" % m, not registry.has_method(m))

	# ── 1b. Behavioral: creating + using sessions writes NO new user:// file ─
	print("\n-- background sessions write no files under user:// --")
	var user_dir: String = ProjectSettings.globalize_path("user://")
	print("  (user:// = %s)" % user_dir)
	var before: Dictionary = {}
	_snapshot_files(user_dir, before)

	var session_a = registry.create_session("restart-sem-a", 80, 24)
	var session_b = registry.create_session("restart-sem-b", 80, 24)
	check("two background sessions created",
		session_a != null and session_b != null)
	if session_a == null or session_b == null:
		return
	if not session_a.terminal_available:
		print("  SKIP: terminal extension instantiated but forkpty unavailable")
		registry.close_session(session_a.terminal_id)
		registry.close_session(session_b.terminal_id)
		return

	# Exercise them — output flows, scrollback accumulates, still no disk.
	session_a.write_input("echo restart_sem_marker\r")
	var start: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 10000:
		if session_a.get_plain_text().find("restart_sem_marker") != -1:
			break
		await process_frame
	check("session A round-trips a command (sessions are live)",
		session_a.get_plain_text().find("restart_sem_marker") != -1)
	await process_frame
	await process_frame

	var after: Dictionary = {}
	_snapshot_files(user_dir, after)
	var new_files: Array = []
	for path in after.keys():
		if not before.has(path):
			new_files.append(path)
	check("no new file appeared under user://", new_files.is_empty(),
		"new files: %s" % str(new_files))

	# ── 3. Fresh-boot emptiness ──────────────────────────────────────────
	print("\n-- fresh registry instance (simulated fresh boot) is empty --")
	var RegistryScript = load(REGISTRY_SCRIPT_PATH)
	var fresh = RegistryScript.new()
	root.add_child(fresh)
	await process_frame
	check("fresh registry lists zero sessions",
		fresh.list_sessions().is_empty() and fresh.session_count() == 0,
		"count=%d" % fresh.session_count())
	check("fresh registry does not know session A (ids are per-process state)",
		not fresh.has_session(session_a.terminal_id))
	check("first registry's session A still alive (process-local, not shared)",
		session_a.is_alive())
	check("first registry still holds both sessions",
		registry.has_session(session_a.terminal_id)
		and registry.has_session(session_b.terminal_id))
	fresh.queue_free()

	# ── cleanup ──────────────────────────────────────────────────────────
	registry.close_session(session_a.terminal_id)
	registry.close_session(session_b.terminal_id)
	await process_frame
	await process_frame
	check("cleanup: sessions closed", not registry.has_session(session_a.terminal_id)
		and not registry.has_session(session_b.terminal_id))
