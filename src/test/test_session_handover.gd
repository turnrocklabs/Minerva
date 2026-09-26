extends SceneTree
## SessionHandover: a role moves to a replacement session, and with it the
## notifications waiting for the old holder and the Docket claims it held.
##
## Real here: SessionHandover, HarnessSessionRegistry and NotifyDeliveryLedger
## (fresh instances installed as the shared ones, the registry writing to a
## throwaway store), and MCPTerminalTools with its terminal listing and relay
## send scripted (test/helpers/notify_world.gd). Docket is a DocketHost whose
## open_projects and call_tool answer from a table and record every call.
##
## THE ORACLE: the relay send log (module.relay_calls: which terminal each line
## was typed into), the ledger's record targets, and the fake Docket's call
## record. A pointer waiting for the old holder is delivered to the
## replacement; nothing is ever typed into the superseded session's terminal;
## docket_reassign is issued once, for the one claim the old holder held, with
## reason "handover: ..."; a pointer kept for an identity that reconnects is
## delivered exactly once; a pointer whose recipient never returns is given
## up as failed_unavailable after the bound, with backed-off retries.
##
## Run: godot --headless --path src --script test/test_session_handover.gd

const World := preload("res://test/helpers/notify_world.gd")
const HANDOVER_PATH := "res://Scripts/Services/Terminal/SessionHandover.gd"
const REGISTRY_PATH := "res://Scripts/Services/Terminal/HarnessSessionRegistry.gd"
const LEDGER_PATH := "res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd"
const TEST_STORE := "user://test_session_handover_sessions.json"

## Docket as SessionHandover reads it: one open project, two items assigned to
## the role, only T-1's claim held by the outgoing session.
const FAKE_HOST_SRC := """
extends "res://Scripts/Services/DocketHost/DocketHost.gd"
var calls: Array = []
var holders := {"T-1": "worker-a", "T-2": "someone-else"}

func open_projects() -> Dictionary:
	return {"projects": [{"name": "minerva"}]}

func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	calls.append({"tool": tool, "arguments": arguments.duplicate(true)})
	match tool:
		"docket_query":
			return {"value": {"items": [{"id": "T-1"}, {"id": "T-2"}]}}
		"docket_get":
			return {"value": {"id": arguments.id, "claim_holder": holders.get(arguments.id, "")}}
		"docket_reassign":
			return {"value": {"id": arguments.id}}
	return {"error": "unexpected tool " + tool}
"""

var _pass := 0
var _fail := 0
var _so: Node = null


func _init() -> void:
	print("=== session handover ===\n")
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
	var saved_host = _so.docket_host
	var registry = registry_script.new()
	registry.store_path = TEST_STORE
	registry_script._shared = registry
	ledger_script._shared = ledger_script.new()
	var host = World.make_script(FAKE_HOST_SRC).new()
	host.state = "ready"
	_so.docket_host = host
	await _test_handover(registry, host)
	_so.docket_host = saved_host
	host.free()
	registry_script._shared = saved_registry
	ledger_script._shared = saved_ledger
	if FileAccess.file_exists(TEST_STORE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_STORE))


func _test_handover(registry, host) -> void:
	var module = World.make_module([
		{"id": "505", "name": "Worker A", "harness": "codex", "foreground_process": "codex",
			"foreground_pid": 5050, "alive": true},
		{"id": "606", "name": "Worker B", "harness": "codex", "foreground_process": "codex",
			"foreground_pid": 6060, "alive": true},
	], {})
	registry.register("worker-a", "builder", "505", "", "codex", module.terminals)
	registry.register("worker-b", "", "606", "", "codex", module.terminals)
	var ledger = load(LEDGER_PATH).shared()

	# The old holder's terminal exits: a pointer for it waits.
	module.terminals[0]["alive"] = false
	var waiting: Dictionary = await module.notify_retained(
		{"to": "worker-a", "from": "codex@lead", "text": "H1 look at T-1"})
	check("H0: a pointer for an unreachable identity is kept awaiting its recipient",
		str(waiting.get("status", "")) == "awaiting_recipient" and module.relay_calls.is_empty(),
		str(waiting))

	var moved: Dictionary = await load(HANDOVER_PATH).run("builder", "worker-b", "codex@lead")
	check("H1: the role moves and the old holder is superseded",
		bool(moved.get("success", false)) and Array(moved.get("superseded", [])) == ["worker-a"], str(moved))
	await _wait_for(func() -> bool: return module.relay_calls.size() >= 1, 2000)
	var record: Dictionary = ledger.get_record(str(waiting.get("delivery_id", "")))
	check("H2: the waiting pointer is re-targeted to the replacement and typed into ITS terminal",
		str(record.get("target", {}).get("identity", "")) == "worker-b"
			and str(record.get("target", {}).get("retargeted_from", "")) == "worker-a"
			and str(record.get("state", "")) == "handed_to_harness"
			and _texts_to(module, "606").has("[MINERVA NOTIFY from codex@lead] H1 look at T-1"),
		"%s %s" % [record, module.relay_calls])

	# docket_reassign: once, for the claim worker-a held, with a handover reason.
	var reassigns: Array = host.calls.filter(func(c: Dictionary) -> bool: return c.tool == "docket_reassign")
	var args: Dictionary = reassigns[0].arguments if reassigns.size() == 1 else {}
	check("H3: docket_reassign is issued once, for the one claim the old holder held",
		reassigns.size() == 1 and str(args.get("id", "")) == "T-1" and str(args.get("to", "")) == "worker-b"
			and bool(args.get("override", false)) and str(args.get("actor", "")) == "codex@lead",
		str(host.calls))
	check("H4: its reason says it is a handover",
		str(args.get("reason", "")).begins_with("handover: role builder from worker-a to worker-b"),
		str(args))

	# The old terminal comes back: its identity and the role still route to
	# the replacement, never to it.
	module.terminals[0]["alive"] = true
	await module.notify_retained({"to": "worker-a", "from": "codex@lead", "text": "H5 by old identity"})
	await module.notify_retained({"to": "builder", "from": "codex@lead", "text": "H5 by role"})
	await _settle(1200)
	check("H5: the superseded session is never dispatched to; its identity and role reach the replacement",
		_texts_to(module, "505").is_empty()
			and _texts_to(module, "606").has("[MINERVA NOTIFY from codex@lead] H5 by old identity")
			and _texts_to(module, "606").has("[MINERVA NOTIFY from codex@lead] H5 by role"),
		str(module.relay_calls))

	# The replacement drops out, a pointer waits for it, and it reconnects.
	module.terminals[1]["alive"] = false
	var kept: Dictionary = await module.notify_retained(
		{"to": "worker-b", "from": "codex@lead", "text": "H6 while away"})
	var line: String = "[MINERVA NOTIFY from codex@lead] H6 while away"
	check("H6: a pointer for the replacement while it is away is kept",
		str(kept.get("status", "")) == "awaiting_recipient" and not _texts_to(module, "606").has(line), str(kept))
	module.terminals[1]["alive"] = true
	registry.register("worker-b", "builder", "606", "", "codex", module.terminals)
	await _wait_for(func() -> bool: return _texts_to(module, "606").has(line), 2000)
	# A second registration change must not deliver the same pointer again.
	registry.register("worker-b", "builder", "606", "", "codex", module.terminals)
	await _settle(1500)
	check("H7: on reconnect the kept pointer is delivered exactly once",
		_texts_to(module, "606").count(line) == 1, str(module.relay_calls))
	check("H8: and nothing was ever typed into the superseded session's terminal",
		_texts_to(module, "505").is_empty(), str(module.relay_calls))

	# A recipient that never comes back: the pointer is retried on a doubling
	# gap and given up as failed_unavailable once it has waited past the bound.
	ledger.await_recheck_s = 0.1
	ledger.await_max_age_s = 1.0
	module.terminals[1]["alive"] = false
	var stranded: Dictionary = await module.notify_retained(
		{"to": "worker-b", "from": "codex@lead", "text": "H9 never delivered"})
	var stranded_id: String = str(stranded.get("delivery_id", ""))
	await _wait_for(func() -> bool:
		return str(ledger.get_record(stranded_id).get("state", "")) == "failed_unavailable", 4000)
	var given_up: Dictionary = ledger.get_record(stranded_id)
	check("H9: a pointer awaiting past the bound ends failed_unavailable, counted apart from pending",
		str(given_up.get("state", "")) == "failed_unavailable"
			and int(ledger.unavailable_by_address().get("worker-b", 0)) == 1
			and int(ledger.pending_by_address().get("worker-b", 0)) == 0
			and not _texts_to(module, "606").has("[MINERVA NOTIFY from codex@lead] H9 never delivered"),
		str(given_up))
	# Gaps 0.1, 0.2, 0.4, 0.8 s fit in the 1 s bound; a fixed 0.1 s gap would try ~10 times.
	check("H10: retries back off: few attempts before the bound",
		int(given_up.get("attempts", 0)) <= 5, str(given_up.get("attempts", 0)))


## The lines the relay was asked to type into `terminal_id`, in order.
func _texts_to(module, terminal_id: String) -> Array:
	var texts: Array = []
	for call_args: Dictionary in module.relay_calls:
		if str(call_args.get("terminal_id", "")) == terminal_id:
			texts.append(str(call_args.get("text", "")))
	return texts


func _wait_for(ready: Callable, budget_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + budget_ms
	while Time.get_ticks_msec() < deadline and not ready.call():
		await process_frame


func _settle(ms: int) -> void:
	await create_timer(ms / 1000.0).timeout
