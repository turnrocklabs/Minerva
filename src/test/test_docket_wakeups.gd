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
## Run: godot --headless --path src --script test/test_docket_wakeups.gd

const World := preload("res://test/helpers/notify_world.gd")
const WAKEUPS_PATH := "res://Scripts/Services/Agents/DocketWakeups.gd"
const TRIGGER_PATH := "res://Scripts/Services/Agents/TriggerDefinition.gd"
const REGISTRY_PATH := "res://Scripts/Services/Terminal/HarnessSessionRegistry.gd"
const LEDGER_PATH := "res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd"
const TEST_STORE := "user://test_docket_wakeups_sessions.json"

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
	registry_script._shared = saved_registry
	ledger_script._shared = saved_ledger
	if FileAccess.file_exists(TEST_STORE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_STORE))


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
