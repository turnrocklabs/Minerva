extends SceneTree
## Unit tests for the host.project.* capabilities (open + current).
##
## Run: godot --headless --path src --script test/test_host_project_capability.gd
##
## Booting the SceneTree loads the SingletonObject autoload, so this also proves
## the edited core files (CapabilityBroker, singleton_object, ProjectMenuActions,
## PluginDefinition) still parse and load. Handlers are called directly, like the
## other CapabilityBroker tests, to bypass the policy gate.

const BROKER_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== host.project.* capability tests ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _tmp_minproj(tag: String) -> String:
	var p := "/tmp/drive-cap-%s-%d.minproj" % [tag, Time.get_ticks_usec()]
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	return p


func _run() -> void:
	await process_frame
	await process_frame

	# The autoload global isn't resolvable from a --script entry at its compile
	# time; reach it through the tree instead (the broker resolves it at load()).
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return

	var broker = load(BROKER_PATH).new(null, null)
	var saved: bool = so.saved_state
	var saved_path: String = so.current_project_path

	# current: defaults (no project loaded, clean state).
	so.current_project_path = ""
	so.saved_state = true
	var cur: Dictionary = broker._handle_host_project_current("tester", {})
	check("current ok", cur.get("success", false), str(cur))
	var cres: Dictionary = cur.get("result", {})
	check("current path empty by default", str(cres.get("path", "x")) == "")
	check("current not dirty when saved", cres.get("dirty", true) == false)

	# open: input validation.
	check("open empty path errors",
		not broker._handle_host_project_open("tester", {}).get("success", true))
	check("open non-minproj errors",
		not broker._handle_host_project_open("tester", {"path": "/tmp/foo.txt"}).get("success", true))
	check("open missing file errors",
		not broker._handle_host_project_open("tester", {"path": "/tmp/nope-xyz.minproj"}).get("success", true))

	# open: a real .minproj with clean state succeeds (emit is a no-op headless).
	var p := _tmp_minproj("ok")
	var ok: Dictionary = broker._handle_host_project_open("tester", {"path": p})
	check("open valid minproj succeeds", ok.get("success", false), str(ok))
	check("open echoes opened path", str((ok.get("result", {}) as Dictionary).get("opened", "")) == p)
	DirAccess.remove_absolute(p)

	# open: refuses when dirty, unless discard_unsaved.
	so.saved_state = false
	var p2 := _tmp_minproj("dirty")
	var refused: Dictionary = broker._handle_host_project_open("tester", {"path": p2})
	check("open refuses when dirty",
		not refused.get("success", true) and refused.get("needs_save", false), str(refused))
	var forced: Dictionary = broker._handle_host_project_open("tester", {"path": p2, "discard_unsaved": true})
	check("open with discard_unsaved succeeds", forced.get("success", false), str(forced))
	DirAccess.remove_absolute(p2)

	# dirty is reflected by current.
	var cur2: Dictionary = broker._handle_host_project_current("tester", {})
	check("current reports dirty", (cur2.get("result", {}) as Dictionary).get("dirty", false) == true)

	# Restore.
	so.saved_state = saved
	so.current_project_path = saved_path
