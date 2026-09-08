extends SceneTree

const Tracker = preload("res://Scripts/Services/MCP/MCPLoopTracker.gd")
var passed := 0
var failed := 0

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)

func _init() -> void:
	var tracker = Tracker.new()
	var reply: Dictionary
	for i in range(6):
		reply = tracker.check("export", {"path": str(i)}, {"error": "bad path"})
	check("distinct failing requests are not counted as identical", tracker._consecutive_error_count == 1 and not reply.has("blocked") and not reply.has("warning"))
	check("same-tool error loop still recognizes identical errors across arguments", reply.has("retry_hint"))
	tracker = Tracker.new()
	for i in range(5):
		reply = tracker.check("export", {}, {"ok": false, "error": "bad source"})
		if i == 2:
			check("third identical failure warns", str(reply.get("warning")).begins_with("STOP:"))
	check("fifth identical failure blocks", reply.get("blocked", false))
	tracker.check("export", {}, {"success": true})
	tracker.check("export", {}, {"error": "bad source"})
	check("success resets error streak", tracker._consecutive_error_count == 1)
	for pending in [
		{"status": "pending", "job_id": "export-1"},
		{"success": true, "result": {"status": "running", "ticket": "design-1"}},
		{"ok": false, "error": {"kind": "running"}},
	]:
		tracker = Tracker.new()
		var clean := true
		for i in range(6):
			reply = tracker.check("minerva_cad_cad_export", {}, pending.duplicate(true))
			clean = clean and not reply.has("warning") and not reply.has("blocked") and not reply.has("retry_hint")
		reply = tracker.check("minerva_cad_cad_export", {}, {"ok": true})
		check("polling through completion carries no loop warning", clean and not reply.has("warning"))
	tracker.check("export", {}, {"status": "pending", "job_id": "a"})
	reply = tracker.check("export", {}, {"error": "disk full"})
	check("pending to terminal failure starts a fresh error streak", tracker._consecutive_error_count == 1 and not reply.has("warning"))
	tracker = Tracker.new()
	for i in range(5):
		reply = tracker.check("unrelated", {}, {"ok": false, "error": {"kind": "running"}})
	check("legacy exemption is scoped to CAD export", reply.get("blocked", false))
	tracker = Tracker.new()
	for i in range(5):
		reply = tracker.check("export", {}, {"status": "pending", "job_id": "a", "error": "terminal error"})
	check("pending label never hides an explicit terminal error", reply.get("blocked", false))
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
