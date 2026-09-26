extends SceneTree
## DocketWakeups: Docket changes addressed to a registered harness session
## become wake-up pointers through the real notify path.
##
## Real here: DocketWakeups, HarnessSessionRegistry and NotifyDeliveryLedger
## (fresh instances installed as the shared ones, the registry writing to a
## throwaway store), and MCPTerminalTools with its terminal listing and relay
## send scripted (test/helpers/notify_world.gd).
##
## THE ORACLE: the relay send log (module.relay_calls) — every line that would
## have been typed into the harness, in order — and the ledger's records for
## them. Five routine changes inside one window are ONE pointer; a control:*
## change is its own urgent pointer, sent at once; a change already taken is
## never sent to the same identity again, even when the item names that
## identity twice (assigned_to and directed_to).
##
## A docket.app subscription event (DocketSubscriptionFeed, against a scripted
## Docket whose call log is the oracle) for a change the embedded path already
## gave is not sent again; a feed-only change in the same page joins the same
## pointer; docket_ack goes out for each event only after the ledger has the
## pointer handed_to_harness, and nothing is acked while the window is open.
## A feed event for a change whose embedded pointer ended unconfirmed is
## never acked. A feed event arriving after the embedded pointer was already
## handed over is acked once and not sent again.
##
## Run: godot --headless --path src --script test/test_docket_wakeups.gd

const World := preload("res://test/helpers/notify_world.gd")
const WAKEUPS_PATH := "res://Scripts/Services/Agents/DocketWakeups.gd"
const TRIGGER_PATH := "res://Scripts/Services/Agents/TriggerDefinition.gd"
const REGISTRY_PATH := "res://Scripts/Services/Terminal/HarnessSessionRegistry.gd"
const LEDGER_PATH := "res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd"
const TEST_STORE := "user://test_docket_wakeups_sessions.json"
const FEED_PATH := "res://Scripts/Services/Agents/DocketSubscriptionFeed.gd"
const TEST_FEED_STATE := "user://test_docket_wakeups_feed.json"

var _pass := 0
var _fail := 0
var _so: Node = null


func _init() -> void:
	print("=== Docket wake-ups ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		print("FAIL: %s%s" % [label, ("  — " + detail) if detail else ""])


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("/root/SingletonObject")
	check("S0: the SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	var registry_script: GDScript = load(REGISTRY_PATH)
	var ledger_script: GDScript = load(LEDGER_PATH)
	var saved_registry = registry_script._shared
	var saved_ledger = ledger_script._shared
	var registry = registry_script.new()
	registry.store_path = TEST_STORE
	registry_script._shared = registry
	ledger_script._shared = ledger_script.new()
	await _test_wakeups(registry)
	await _test_subscription_dedup(registry)
	registry_script._shared = saved_registry
	ledger_script._shared = saved_ledger
	if FileAccess.file_exists(TEST_STORE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_STORE))
	if FileAccess.file_exists(TEST_FEED_STATE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_FEED_STATE))


func _test_wakeups(registry) -> void:
	var module = World.make_module([
		{"id": "505", "name": "Worker A", "harness": "codex", "foreground_process": "codex",
			"foreground_pid": 5050, "alive": true},
	], {})
	var registered: Dictionary = registry.register("worker-a", "builder", "505", "", "codex", module.terminals)
	check("W0: worker-a is registered at terminal 505", bool(registered.get("success", false)), str(registered))

	var wakeups = load(WAKEUPS_PATH).new()
	wakeups.tools = module
	var trig = load(TRIGGER_PATH).new()
	trig.name = "wake"
	trig.docket_poll_interval = 1.0

	# Five routine changes inside one window, on three items. item-2 names the
	# session twice (identity and role): still one change for it.
	var changes: Array = [
		["item-1", "g/s/1", {"assigned_to": "worker-a"}],
		["item-1", "g/s/2", {"assigned_to": "worker-a"}],
		["item-2", "g/s/3", {"assigned_to": "worker-a", "directed_to": "builder"}],
		["item-3", "g/s/4", {"directed_to": "builder"}],
		["item-3", "g/s/5", {"directed_to": "builder"}],
	]
	for change: Array in changes:
		var item: Dictionary = (change[2] as Dictionary).merged({"title": "Task %s" % change[0], "tags": []})
		wakeups.take(trig, "minerva", str(change[0]), "updated", "", "", item, str(change[1]))
	check("W1: nothing is sent while the window is open", module.relay_calls.is_empty(), str(module.relay_calls))
	await _wait_for(func() -> bool: return module.relay_calls.size() >= 1, 4000)
	await _settle(1500)
	check("W2: five routine changes in one window are ONE pointer to the session's terminal",
		module.relay_calls.size() == 1 and str(module.relay_calls[0].get("terminal_id")) == "505",
		str(module.relay_calls))
	var routine_text: String = str(module.relay_calls[0].get("text", "")) if not module.relay_calls.is_empty() else ""
	check("W3: the pointer counts every change exactly once and names every item",
		routine_text.contains("5 changes") and routine_text.contains("minerva:item-1")
			and routine_text.contains("minerva:item-2") and routine_text.contains("minerva:item-3"),
		routine_text)

	# A control directive goes out at once, as its own urgent pointer.
	var before_control: int = module.relay_calls.size()
	var directive: Dictionary = {"assigned_to": "worker-a", "title": "Task item-1", "tags": ["control:stop"]}
	wakeups.take(trig, "minerva", "item-1", "updated", "", "", directive, "g/s/6")
	await _wait_for(func() -> bool: return module.relay_calls.size() > before_control, 800)
	var control_text: String = str(module.relay_calls[-1].get("text", "")) if module.relay_calls.size() > before_control else ""
	check("W4: a control:* change is its own pointer, sent before any window closes",
		module.relay_calls.size() == before_control + 1 and control_text.contains("Docket CONTROL control:stop"),
		str(module.relay_calls))
	var control_record: Dictionary = {}
	for record: Dictionary in load(LEDGER_PATH).shared().list():
		if str(record.get("text", "")).contains("Docket CONTROL"):
			control_record = record
	check("W5: the directive is recorded urgent in the ledger, the routine pointer routine",
		str(control_record.get("class", "")) == "urgent"
			and _ledger_classes().count("routine") == 1, str(load(LEDGER_PATH).shared().list()))

	# The same changes again: each was already taken by this identity.
	var before_replay: int = module.relay_calls.size()
	for change: Array in changes:
		var item: Dictionary = (change[2] as Dictionary).merged({"title": "Task %s" % change[0], "tags": []})
		wakeups.take(trig, "minerva", str(change[0]), "updated", "", "", item, str(change[1]))
	wakeups.take(trig, "minerva", "item-1", "updated", "", "", directive, "g/s/6")
	await _settle(2500)
	check("W6: a change already taken never wakes the same identity again",
		module.relay_calls.size() == before_replay, str(module.relay_calls.slice(before_replay)))


func _test_subscription_dedup(registry) -> void:
	var module = World.make_module([
		{"id": "606", "name": "Worker B", "harness": "codex", "foreground_process": "codex",
			"foreground_pid": 6060, "alive": true},
	], {})
	var registered: Dictionary = registry.register("worker-b", "reviewer", "606", "", "codex", module.terminals)
	check("D0: worker-b is registered at terminal 606", bool(registered.get("success", false)), str(registered))
	var wakeups = load(WAKEUPS_PATH).new()
	wakeups.tools = module
	var trig = load(TRIGGER_PATH).new()
	trig.name = "wake-sub"
	trig.enabled = true
	trig.trigger_type = TriggerDefinition.TriggerType.DOCKET_POLL
	trig.docket_wake_sessions = true
	trig.docket_poll_interval = 1.0

	# One transition of item-9, seen first by the embedded path.
	var stamp := "2026-09-26T10:00:00"
	var item: Dictionary = {"id": "item-9", "title": "Task item-9", "type": "work_item", "status": "in_progress",
		"assigned_to": "worker-b", "tags": [], "updated_at": stamp,
		"events": [{"event_type": "transition", "timestamp": stamp, "note": "open → in_progress", "actor": "a"}]}
	wakeups.take(trig, "minerva", "item-9", "transitioned", "open", "in_progress", item, "")
	# item-10 changes only in docket.app, so only the feed delivers it. item-11
	# is seen by the embedded path first, and its pointer ends unconfirmed.
	var stamp_10 := "2026-09-26T10:00:01"
	var item_10: Dictionary = {"id": "item-10", "title": "Task item-10", "type": "work_item", "status": "open",
		"assigned_to": "worker-b", "tags": [], "updated_at": stamp_10, "events": []}
	var stamp_11 := "2026-09-26T10:05:00"
	var item_11: Dictionary = {"id": "item-11", "title": "Task item-11", "type": "work_item", "status": "open",
		"assigned_to": "worker-b", "tags": [], "updated_at": stamp_11, "events": []}
	var items: Dictionary = {"item-9": item, "item-10": item_10, "item-11": item_11}

	# The same changes from docket.app's feed, one page per poll. The scripted
	# Docket logs each call with the relay sends made before it.
	var pages: Array = [
		[{"project": "minerva", "eid": 7, "item_id": "item-9", "kind": "transition",
			"actor": "a", "timestamp": stamp, "fields": ["status"], "possible_duplicate": false},
		{"project": "minerva", "eid": 8, "item_id": "item-10", "kind": "typed_update",
			"actor": "a", "timestamp": stamp_10, "fields": ["title"], "possible_duplicate": false}],
		[{"project": "minerva", "eid": 9, "item_id": "item-11", "kind": "typed_update",
			"actor": "a", "timestamp": stamp_11, "fields": ["title"], "possible_duplicate": false}],
	]
	var calls: Array = []
	var served: Array[TriggerDefinition] = [trig]
	var feed = load(FEED_PATH).new(wakeups, func() -> Array[TriggerDefinition]: return served)
	feed.state_path = TEST_FEED_STATE
	feed.caller = func(tool: String, arguments: Dictionary) -> Dictionary:
		calls.append({"tool": tool, "arguments": arguments, "relayed": module.relay_calls.size()})
		match tool:
			"docket_subscribe":
				return {"subscriber": "sub-1", "name": arguments.get("name", ""), "cursor": "c0"}
			"docket_changes_since":
				var events: Array = pages.pop_front() if not pages.is_empty() else []
				return {"events": events, "next_cursor": "c%d" % (2 - pages.size()), "more": false, "expired": false}
			"docket_get":
				return items.get(str(arguments.get("id", "")), {"error": "no such item"})
			"docket_ack":
				return {"subscriber": "sub-1", "acked": arguments.get("event_ids", []), "already_acked": [], "pending_count": 0}
		return {"error": "unexpected %s" % tool}
	await feed.poll_once()
	var tools: Array = calls.map(func(entry: Dictionary) -> String: return str(entry.tool))
	check("D1: the feed subscribes under the installation identity, reads, and has not acked while the pointer waits",
		tools == ["docket_subscribe", "docket_changes_since", "docket_get", "docket_get"]
			and str(calls[0].arguments.name).begins_with("minerva@install-") and module.relay_calls.is_empty(),
		str(calls))

	await _wait_for(func() -> bool: return _acks(calls).size() >= 2, 6000)
	await _settle(1500)
	var sent: Array = module.relay_calls.filter(func(relayed: Dictionary) -> bool: return str(relayed.get("text", "")).contains("item-9"))
	check("D2: the embedded change and the feed-only change are ONE pointer; the feed's copy of item-9 is not counted again",
		module.relay_calls.size() == 1 and sent.size() == 1 and str(sent[0].get("text", "")).contains("2 changes on")
			and str(sent[0].get("text", "")).contains("minerva:item-10"), str(module.relay_calls))
	var acked: Array = []
	var after_delivery: bool = true
	for ack: Dictionary in _acks(calls):
		acked.append_array(ack.arguments.get("event_ids", []))
		after_delivery = after_delivery and int(ack.get("relayed", 0)) >= 1 and str(ack.arguments.get("subscriber", "")) == "sub-1"
	check("D3: docket_ack follows the pointer's delivery and names each event of the page once",
		after_delivery and acked.size() == 2 and acked.has({"project": "minerva", "eid": 7})
			and acked.has({"project": "minerva", "eid": 8}) and str(calls[-1].get("tool", "")) == "docket_ack",
		str(calls))
	check("D4: the feed saved the cursor after the page", feed.cursor == "c1", feed.cursor)

	# item-11: the embedded path's pointer is typed but never confirmed.
	module.relay_reply = {"ok": true, "submit": {"state": "typed", "evidence": ""}}
	var relayed_before: int = module.relay_calls.size()
	wakeups.take(trig, "minerva", "item-11", "updated", "", "", item_11, "")
	await _wait_for(func() -> bool: return module.relay_calls.size() > relayed_before, 4000)
	await _settle(1000)
	var unconfirmed: Array = load(LEDGER_PATH).shared().list().filter(func(record: Dictionary) -> bool: return str(record.get("text", "")).contains("item-11") and str(record.get("state", "")) == "unconfirmed")
	check("D5: the embedded pointer for item-11 settled unconfirmed", unconfirmed.size() == 1,
		str(load(LEDGER_PATH).shared().list()))
	var calls_before: int = calls.size()
	await feed.poll_once()
	await _settle(1500)
	var late: Array = calls.slice(calls_before)
	check("D6: the feed's copy of a change whose pointer was never handed over is not acked, nor sent again",
		_acks(late).is_empty() and late.map(func(entry: Dictionary) -> String: return str(entry.tool)) == ["docket_changes_since", "docket_get"]
			and module.relay_calls.size() == relayed_before + 1, str(late))

	# item-12: the embedded pointer is handed over first; the feed's copy of
	# the same change arrives afterwards and is acked without a second send.
	module.relay_reply = {"ok": true, "submit": {"state": "submitted", "evidence": "echo"}}
	var stamp_12 := "2026-09-26T10:10:00"
	var item_12: Dictionary = {"id": "item-12", "title": "Task item-12", "type": "work_item", "status": "open",
		"assigned_to": "worker-b", "tags": [], "updated_at": stamp_12, "events": []}
	items["item-12"] = item_12
	var relayed_12: int = module.relay_calls.size()
	wakeups.take(trig, "minerva", "item-12", "updated", "", "", item_12, "")
	var handed_12 := func() -> bool:
		for record: Dictionary in load(LEDGER_PATH).shared().list():
			if str(record.get("text", "")).contains("item-12") and str(record.get("state", "")) == "handed_to_harness":
				return true
		return false
	await _wait_for(handed_12, 4000)
	check("D7: the embedded pointer for item-12 reached handed_to_harness before the feed read it",
		handed_12.call() and module.relay_calls.size() == relayed_12 + 1, str(load(LEDGER_PATH).shared().list()))
	# The ledger reaching handed is not enough: the feed's copy must meet the
	# key DocketWakeups._settle marked handed, not the still-pending pointer.
	var key_12: String = "worker-b|" + load(WAKEUPS_PATH).change_key_of("minerva", "item-12", "updated", stamp_12, "", "")
	await _wait_for(func() -> bool: return str(wakeups._woken.get(key_12, "")) == wakeups.KEY_HANDED, 4000)
	check("D7b: DocketWakeups settled item-12's change as handed before the feed polls",
		str(wakeups._woken.get(key_12, "")) == wakeups.KEY_HANDED and not wakeups._pending.has(key_12),
		"%s %s" % [wakeups._woken.get(key_12, "<absent>"), wakeups._pending.keys()])
	pages.append([{"project": "minerva", "eid": 10, "item_id": "item-12", "kind": "typed_update",
		"actor": "a", "timestamp": stamp_12, "fields": ["title"], "possible_duplicate": false}])
	var calls_12: int = calls.size()
	await feed.poll_once()
	await _settle(1500)
	var acks_12: Array = _acks(calls.slice(calls_12))
	check("D8: the feed's copy of a change already handed over is acked once and not sent again",
		acks_12.size() == 1 and acks_12[0].arguments.get("event_ids", []) == [{"project": "minerva", "eid": 10}]
			and module.relay_calls.size() == relayed_12 + 1, str(calls.slice(calls_12)))

	# item-13 reaches Minerva only through the feed, so its receipt waits on
	# the pointer; that pointer is typed but never confirmed, so the receipt is
	# abandoned when it settles, never released into a docket_ack.
	module.relay_reply = {"ok": true, "submit": {"state": "typed", "evidence": ""}}
	var stamp_13 := "2026-09-26T10:15:00"
	items["item-13"] = {"id": "item-13", "title": "Task item-13", "type": "work_item", "status": "open",
		"assigned_to": "worker-b", "tags": [], "updated_at": stamp_13, "events": []}
	pages.append([{"project": "minerva", "eid": 11, "item_id": "item-13", "kind": "typed_update",
		"actor": "a", "timestamp": stamp_13, "fields": ["title"], "possible_duplicate": false}])
	var calls_13: int = calls.size()
	var relayed_13: int = module.relay_calls.size()
	await feed.poll_once()
	var unconfirmed_13 := func() -> bool:
		for record: Dictionary in load(LEDGER_PATH).shared().list():
			if str(record.get("text", "")).contains("item-13") and str(record.get("state", "")) == "unconfirmed":
				return true
		return false
	await _wait_for(unconfirmed_13, 6000)
	await _settle(1500)
	check("D9: a feed-only change whose pointer settles unconfirmed is sent once and not acked",
		unconfirmed_13.call() and module.relay_calls.size() == relayed_13 + 1
			and _acks(calls.slice(calls_13)).is_empty(), str(calls.slice(calls_13)))


# The docket_ack calls in a scripted Docket call log.
func _acks(calls: Array) -> Array:
	return calls.filter(func(entry: Dictionary) -> bool: return str(entry.tool) == "docket_ack")


func _ledger_classes() -> Array:
	var classes: Array = []
	for record: Dictionary in load(LEDGER_PATH).shared().list():
		classes.append(str(record.get("class", "")))
	return classes


func _wait_for(ready: Callable, budget_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + budget_ms
	while Time.get_ticks_msec() < deadline and not ready.call():
		await process_frame


func _settle(ms: int) -> void:
	await create_timer(ms / 1000.0).timeout
