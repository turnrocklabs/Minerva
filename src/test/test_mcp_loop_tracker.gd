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
	for status in [{"running": true}, ["pending"], null, 2]:
		check("structured domain status is not an operation continuation",
			not Tracker._is_pending("inspect", {"success": true, "status": status, "ticket": "domain-id"}))
	for i in range(6):
		reply = tracker.check("export", {"path": str(i)}, {"error": "bad path"})
	check("distinct failing requests are not counted as identical", tracker._streaks["export"].consecutive_error_count == 1 and not reply.has("blocked") and not reply.has("warning"))
	check("same-tool error loop still recognizes identical errors across arguments", reply.has("retry_hint"))
	tracker = Tracker.new()
	for i in range(5):
		reply = tracker.check("export", {}, {"ok": false, "error": "bad source"})
		if i == 2:
			check("third identical failure warns", str(reply.get("warning")).begins_with("STOP:"))
	check("fifth identical failure blocks", reply.get("blocked", false))
	tracker.check("export", {}, {"success": true})
	tracker.check("export", {}, {"error": "bad source"})
	check("success resets error streak", tracker._streaks["export"].consecutive_error_count == 1)
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
	check("pending to terminal failure starts a fresh error streak", tracker._streaks["export"].consecutive_error_count == 1 and not reply.has("warning"))
	tracker = Tracker.new()
	for i in range(5):
		reply = tracker.check("unrelated", {}, {"ok": false, "error": {"kind": "running"}})
	check("legacy exemption is scoped to CAD export", reply.get("blocked", false))
	tracker = Tracker.new()
	for i in range(5):
		reply = tracker.check("export", {}, {"status": "pending", "job_id": "a", "error": "terminal error"})
	check("pending label never hides an explicit terminal error", reply.get("blocked", false))
	# A wait that expired with the work still unfinished: the caller was told to
	# ask again, so the identical follow-up is a continuation, not a loop.
	tracker = Tracker.new()
	var awaiting := {"success": true, "timed_out": true, "waited_ms": 30000,
		"timeout_ms": 30000, "stale": true, "evaluation_status": "pending"}
	var clean_await := true
	for i in range(3):
		reply = tracker.check("panel_await", {"editor_name": "shape"}, awaiting.duplicate(true))
		clean_await = clean_await and not reply.has("warning") and not reply.has("retry_hint")
	reply = tracker.check("panel_await", {"editor_name": "shape"},
		{"success": true, "timed_out": false, "evaluation_status": "ok"})
	check("an expired wait resumed to completion carries no loop warning",
		clean_await and not reply.has("warning") and tracker._streaks["panel_await"].consecutive_error_count == 0)
	# Suppression is opt-in: the result must say BOTH that its wait expired and
	# that the work is unfinished.
	tracker = Tracker.new()
	for i in range(2):
		reply = tracker.check("panel_await", {}, {"success": true, "timed_out": true})
		if i == 1:
			check("an expired wait alone is still a repeated call", reply.has("warning"))
	tracker = Tracker.new()
	for i in range(2):
		reply = tracker.check("panel_await", {}, {"success": true, "item_status": "closed"})
		if i == 1:
			check("a terminal status is still a repeated call", reply.has("warning"))
	# The plain `status` field, with no handle beside it.
	tracker = Tracker.new()
	var clean_plain := true
	for i in range(3):
		reply = tracker.check("panel_await", {}, {"success": true, "timed_out": true, "status": "pending"})
		clean_plain = clean_plain and not reply.has("warning")
	check("an expired wait with a plain pending status needs no handle", clean_plain)
	tracker = Tracker.new()
	for i in range(2):
		reply = tracker.check("panel_await", {}, {"timed_out": true, "status": "completed", "item_status": "pending"})
	check("terminal operation status takes precedence over domain status", reply.has("warning"))
	tracker = Tracker.new()
	for i in range(2):
		reply = tracker.check("panel_await", {}, {"evaluation_status": "pending"})
	check("domain status alone is not a continuation", reply.has("warning"))
	# A status outside the non-terminal set is accounted for as before, handle
	# or no handle.
	tracker = Tracker.new()
	for i in range(2):
		reply = tracker.check("export", {}, {"status": "queued", "job_id": "a"})
	check("the handle path still accepts only pending and running", reply.has("warning"))
	# The pending exemption is scoped to the tool it came from.
	tracker = Tracker.new()
	tracker.check("alpha", {"a": 1}, {"error": "boom"})
	tracker.check("panel_await", {}, {"success": true, "timed_out": true, "evaluation_status": "pending"})
	reply = tracker.check("alpha", {"a": 2}, {"error": "boom"})
	check("a pending reply elsewhere leaves another tool's error streak intact", reply.has("retry_hint"))
	# Interleaving another tool neither resets nor advances this tool's streak.
	for other_result in [{"status": "pending", "job_id": "other"}, {"ok": true}, {"error": "other failure"}]:
		tracker = Tracker.new()
		for i in range(5):
			tracker.check("beta", {}, other_result.duplicate(true))
			reply = tracker.check("alpha", {}, {"error": "boom"})
			if i == 2:
				check("third alpha failure warns despite interleaving", str(reply.get("warning", "")).begins_with("STOP:"))
		check("fifth alpha failure blocks despite interleaving", reply.get("blocked", false))
		tracker.check("alpha", {}, {"status": "pending", "job_id": "alpha-job"})
		reply = tracker.check("alpha", {}, {"error": "boom"})
		check("alpha continuation resets only alpha's counters", not reply.has("warning") and not reply.has("retry_hint"))
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)
