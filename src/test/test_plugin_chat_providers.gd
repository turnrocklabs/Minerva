extends SceneTree
## W1 (chat-passthrough): plugin chat-provider registration seam.
##
## Run: timeout 120 godot --headless --path src --script test/test_plugin_chat_providers.gd
##
## Acceptance (see W1 contract):
##   1. Fake plugin registers an entry via the broker capability path →
##      list_entries has it; a ProviderItem appears in a ProviderOptionButton.
##   2. generate round-trip: {kind:"answer",text:"pong-7"} → BotResponse.text
##      == "pong-7", zero token counts.
##   3. question round-trip: hcp_data["passthrough_question_options"] intact.
##   4. history_mode honored: newest_only → no messages arg; full → messages.
##   5. unregister → entry gone; re-register same entry_id → update not dup.
##   6. plugin stop mid-chat: entry vanishes via lifecycle signal; in-flight
##      generate resolves to BotResponse.error; no crash; history intact.
##   7. ServiceHistory round-trip: PluginProvider restored when entry present;
##      default-provider fallback when entry absent (no error dialog).
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type.
## SingletonObject autoload registers lazily; resolve at runtime.

const REGISTRY_PATH := "res://Scripts/Services/Plugins/PluginChatProviderRegistry.gd"
const PROVIDER_PATH := "res://Scripts/Services/Providers/PluginProvider.gd"
const BROKER_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const POLICY_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const PM_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PROVIDER_OPTION_BUTTON_PATH := "res://Scripts/UI/Controls/ProviderOptionButton.gd"
const SERVICE_HISTORY_PATH := "res://Scripts/Models/ServiceHistory.gd"

const FIXTURE_DIR_REL := "/test/fixtures/chat_provider_probe"
const PLUGIN_ID := "chatprovider"
const S_RUNNING := 2
const S_STOPPED := 3

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== W1 plugin chat-provider seam test ===\n")
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
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


# ---------------------------------------------------------------------------
# Stubs (duck-typed; class_name globals invisible to --script)
# ---------------------------------------------------------------------------

## Stub MCPServerConnection: returns a scripted result for call_tool, records
## the args it was called with so history_mode can be asserted.
class StubConnection extends RefCounted:
	var scripted_result = {}
	var last_args: Dictionary = {}
	var last_tool: String = ""
	var cancel_calls: Array = []
	var die_after_call: bool = false  # simulate connection death mid-call

	# When > 0, delay the generate reply by this many seconds (await a timer) to
	# simulate a slow plugin so cancellation can be exercised mid-flight.
	var reply_delay_sec: float = 0.0
	var tree: SceneTree = null   # needed to create timers for the delay
	var generate_calls: int = 0  # count of non-cancel dispatches issued

	func call_tool(tool_name: String, args: Dictionary, _timeout_sec: float = 120.0):
		last_tool = tool_name
		last_args = args.duplicate(true)
		if tool_name.ends_with("_cancel") or tool_name.find("cancel") != -1:
			cancel_calls.append(args)
			return {"content": [{"type": "text", "text": "{}"}]}
		generate_calls += 1
		if reply_delay_sec > 0.0 and tree != null:
			await tree.create_timer(reply_delay_sec).timeout
		if die_after_call:
			return {"error": "connection closed"}
		return scripted_result


## Stub PluginManager exposing get_connection(id).
class StubManager extends RefCounted:
	var conn = null
	func get_connection(_id: String):
		return conn


func _make_provider(entry: Dictionary, conn, manager) -> Object:
	var P = load(PROVIDER_PATH)
	var prov = P.new()
	prov.configure_from_entry(entry)
	prov._test_plugin_manager = manager
	manager.conn = conn
	# Add to tree so _ready() wires the stop signal (cancellation path).
	root.add_child(prov)
	return prov


func _answer_envelope(text: String) -> Dictionary:
	return {"content": [{"type": "text",
		"text": JSON.stringify({"kind": "answer", "text": text})}]}


# ---------------------------------------------------------------------------
# Test driver
# ---------------------------------------------------------------------------

func _run() -> void:
	# Wait a frame for autoloads.
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return

	_test_registry_unit()
	await _test_provider_generate(so)
	await _test_provider_question(so)
	await _test_history_mode(so)
	await _test_provider_errors(so)
	await _test_chooser_population(so)
	await _test_cancel_mid_flight(so)
	await _test_stale_reply_after_regenerate(so)
	await _test_saved_selection_key_restore(so)
	_test_service_history_roundtrip(so)
	await _test_integration_capability_path(so)


# --- Acceptance 5 (registry) + idempotent update --------------------------
func _test_registry_unit() -> void:
	print("\n-- Registry: register/update/unregister --")
	var R = load(REGISTRY_PATH)
	var reg = R.new()
	var changed := [0]
	reg.chat_providers_changed.connect(func(): changed[0] += 1)

	var e = reg.register_entry(PLUGIN_ID, {
		"entry_id": "main", "display_name": "Probe", "generate_tool": "minerva_chatprovider_generate",
		"history_mode": "newest_only"})
	check("register_entry returns entry", not e.is_empty())
	check("entry key is plugin:<id>:<entry_id>", e.get("key", "") == "plugin:chatprovider:main",
		e.get("key", ""))
	check("default timeout applied", int(e.get("timeout_sec", 0)) == 600,
		str(e.get("timeout_sec")))
	check("list_entries has 1", reg.list_entries().size() == 1)

	# Idempotent update — same entry_id, new display_name → no duplicate.
	reg.register_entry(PLUGIN_ID, {
		"entry_id": "main", "display_name": "Probe v2", "generate_tool": "minerva_chatprovider_generate",
		"history_mode": "full"})
	check("re-register updates not duplicates", reg.list_entries().size() == 1)
	check("update changed display_name",
		reg.get_entry("plugin:chatprovider:main").get("display_name", "") == "Probe v2")
	check("changed signal fired per op", changed[0] >= 2, str(changed[0]))

	# Invalid history_mode rejected.
	var bad = reg.register_entry(PLUGIN_ID, {
		"entry_id": "x", "display_name": "X", "generate_tool": "minerva_chatprovider_x",
		"history_mode": "bogus"})
	check("invalid history_mode rejected", bad.is_empty())

	# Unregister.
	check("unregister removes", reg.unregister_entry(PLUGIN_ID, "main"))
	check("list empty after unregister", reg.list_entries().is_empty())
	check("unregister missing returns false", not reg.unregister_entry(PLUGIN_ID, "nope"))

	# drop_plugin.
	reg.register_entry(PLUGIN_ID, {"entry_id": "a", "display_name": "A",
		"generate_tool": "minerva_chatprovider_a", "history_mode": "newest_only"})
	reg.register_entry("other", {"entry_id": "b", "display_name": "B",
		"generate_tool": "minerva_other_b", "history_mode": "newest_only"})
	check("drop_plugin removes only owner's", reg.drop_plugin(PLUGIN_ID) == 1)
	check("other plugin entry survives", reg.list_entries().size() == 1)


# --- Acceptance 2 ----------------------------------------------------------
func _test_provider_generate(_so) -> void:
	print("\n-- Provider: answer round-trip --")
	var entry = {"key": "plugin:chatprovider:main", "plugin_id": PLUGIN_ID, "entry_id": "main",
		"display_name": "Probe", "generate_tool": "minerva_chatprovider_generate",
		"history_mode": "newest_only", "timeout_sec": 600, "cancel_tool": "", "metadata": {}}
	var conn = StubConnection.new()
	conn.scripted_result = _answer_envelope("pong-7")
	var prov = _make_provider(entry, conn, StubManager.new())
	prov.owner_history_id = "hist-1"

	var bot = await prov.generate_content([{"text": "pong"}])
	check("answer text == pong-7", bot.text == "pong-7", bot.text)
	check("answer no error", bot.error == "", bot.error)
	check("answer zero prompt tokens", bot.prompt_tokens == 0)
	check("answer zero completion tokens", bot.completion_tokens == 0)
	prov.queue_free()


# --- Acceptance 3 ----------------------------------------------------------
func _test_provider_question(_so) -> void:
	print("\n-- Provider: question round-trip --")
	var entry = {"key": "plugin:chatprovider:q", "plugin_id": PLUGIN_ID, "entry_id": "q",
		"display_name": "Probe", "generate_tool": "minerva_chatprovider_generate",
		"history_mode": "newest_only", "timeout_sec": 600, "cancel_tool": "", "metadata": {}}
	var conn = StubConnection.new()
	conn.scripted_result = {"content": [{"type": "text", "text": JSON.stringify({
		"kind": "question", "text": "Pick one",
		"options": [{"label": "Yes", "keystroke": "y"}, {"label": "No", "keystroke": "n"}]})}]}
	var prov = _make_provider(entry, conn, StubManager.new())

	var bot = await prov.generate_content([{"text": "ask"}])
	check("question text set", bot.text == "Pick one", bot.text)
	check("hcp_data has options key", bot.hcp_data.has("passthrough_question_options"))
	var opts = bot.hcp_data.get("passthrough_question_options", [])
	check("two options preserved", opts.size() == 2, str(opts.size()))
	check("option label/keystroke intact",
		opts.size() == 2 and opts[0].get("label", "") == "Yes" and opts[0].get("keystroke", "") == "y",
		str(opts))
	prov.queue_free()


# --- Acceptance 4 ----------------------------------------------------------
func _test_history_mode(_so) -> void:
	print("\n-- Provider: history_mode honored --")
	# newest_only — no messages arg.
	var e1 = {"key": "k1", "plugin_id": PLUGIN_ID, "entry_id": "n", "display_name": "N",
		"generate_tool": "minerva_chatprovider_generate", "history_mode": "newest_only",
		"timeout_sec": 600, "cancel_tool": "", "metadata": {}}
	var c1 = StubConnection.new()
	c1.scripted_result = _answer_envelope("ok")
	var p1 = _make_provider(e1, c1, StubManager.new())
	await p1.generate_content([{"text": "a"}, {"text": "b"}])
	check("newest_only: no messages arg", not c1.last_args.has("messages"), str(c1.last_args.keys()))
	check("newest_only: text is newest", c1.last_args.get("text", "") == "b", str(c1.last_args))
	p1.queue_free()

	# full — messages present.
	var e2 = {"key": "k2", "plugin_id": PLUGIN_ID, "entry_id": "f", "display_name": "F",
		"generate_tool": "minerva_chatprovider_generate", "history_mode": "full",
		"timeout_sec": 600, "cancel_tool": "", "metadata": {}}
	var c2 = StubConnection.new()
	c2.scripted_result = _answer_envelope("ok")
	var p2 = _make_provider(e2, c2, StubManager.new())
	await p2.generate_content([{"text": "a"}, {"text": "b"}])
	check("full: messages arg present", c2.last_args.has("messages"))
	check("full: messages has 2 items", (c2.last_args.get("messages", []) as Array).size() == 2)
	p2.queue_free()


# --- Acceptance 6 (transport error / plugin death) + error kind ----------
func _test_provider_errors(_so) -> void:
	print("\n-- Provider: error kind + plugin death --")
	# error kind.
	var e = {"key": "ke", "plugin_id": PLUGIN_ID, "entry_id": "e", "display_name": "E",
		"generate_tool": "minerva_chatprovider_generate", "history_mode": "newest_only",
		"timeout_sec": 600, "cancel_tool": "", "metadata": {}}
	var c = StubConnection.new()
	c.scripted_result = {"content": [{"type": "text", "text": JSON.stringify(
		{"kind": "error", "text": "deliberate failure"})}]}
	var p = _make_provider(e, c, StubManager.new())
	var bot = await p.generate_content([{"text": "boom"}])
	check("error kind → BotResponse.error", bot.error == "deliberate failure", bot.error)
	p.queue_free()

	# Plugin death: connection returns {error:...}.
	var c2 = StubConnection.new()
	c2.die_after_call = true
	var p2 = _make_provider(e, c2, StubManager.new())
	var bot2 = await p2.generate_content([{"text": "x"}])
	check("dead connection → BotResponse.error", not bot2.error.is_empty(), bot2.error)
	check("dead connection → no text", bot2.text == "")
	p2.queue_free()

	# Plugin not running (get_connection null).
	var mgr3 = StubManager.new()  # conn stays null
	var P = load(PROVIDER_PATH)
	var p3 = P.new()
	p3.configure_from_entry(e)
	p3._test_plugin_manager = mgr3
	root.add_child(p3)
	var bot3 = await p3.generate_content([{"text": "x"}])
	check("no connection → BotResponse.error", not bot3.error.is_empty(), bot3.error)
	p3.queue_free()


# --- Acceptance 1 (chooser) ------------------------------------------------
func _test_chooser_population(so) -> void:
	print("\n-- Chooser: ProviderItem appears + vanish on drop --")
	var R = load(REGISTRY_PATH)
	var reg = R.new()
	reg.register_entry(PLUGIN_ID, {"entry_id": "main", "display_name": "Probe Passthrough",
		"generate_tool": "minerva_chatprovider_generate", "history_mode": "newest_only"})
	# Inject the registry so ProviderOptionButton._setup_default_provider_set sees it.
	so.plugin_chat_provider_registry = reg

	var OB = load(PROVIDER_OPTION_BUTTON_PATH)
	var btn = OB.new()
	root.add_child(btn)
	await process_frame

	var found := false
	for i in range(btn.get_item_count()):
		if btn.get_item_text(i) == "Probe Passthrough":
			found = true
			break
	check("ProviderItem for plugin entry appears in chooser", found,
		"items: %d" % btn.get_item_count())

	# Selecting it yields a PluginProvider.
	var idx := -1
	for i in range(btn.get_item_count()):
		if btn.get_item_text(i) == "Probe Passthrough":
			idx = i
			break
	if idx >= 0:
		var prov = btn._get_provider_from_id(btn.get_item_id(idx))
		check("selecting plugin entry yields a provider", prov != null)
		check("provider is configured from entry", prov != null and prov.entry_key == "plugin:chatprovider:main",
			prov.entry_key if prov != null else "<null>")

	# Drop → entry vanishes from chooser on repopulate.
	reg.drop_plugin(PLUGIN_ID)
	await process_frame
	var still_found := false
	for i in range(btn.get_item_count()):
		if btn.get_item_text(i) == "Probe Passthrough":
			still_found = true
	check("entry vanishes from chooser after drop", not still_found)
	btn.queue_free()
	so.plugin_chat_provider_registry = null


# --- Cancellation: cancel mid-flight (generation token) -------------------
func _test_cancel_mid_flight(so) -> void:
	print("\n-- Cancellation: cancel mid-flight returns promptly --")
	var entry = {"key": "plugin:chatprovider:cm", "plugin_id": PLUGIN_ID, "entry_id": "cm",
		"display_name": "CM", "generate_tool": "minerva_chatprovider_generate",
		"history_mode": "newest_only", "timeout_sec": 600, "cancel_tool": "", "metadata": {}}
	var conn = StubConnection.new()
	conn.tree = self
	conn.reply_delay_sec = 2.0  # slow plugin
	conn.scripted_result = _answer_envelope("late-answer")
	var prov = _make_provider(entry, conn, StubManager.new())
	prov.owner_history_id = "hist-cm"

	# Track chat_completed emissions for this run.
	var emissions := [0]
	var sig := func(_b): emissions[0] += 1
	so.chat_completed.connect(sig)

	var t0 := Time.get_ticks_msec()
	# Start generate but DON'T await yet — fire cancel mid-flight.
	var gen_done := [false]
	var captured := [null]
	var runner := func():
		var b = await prov.generate_content([{"text": "hi"}])
		captured[0] = b
		gen_done[0] = true
	runner.call()
	# Let the dispatch start, then cancel before the 2s delay elapses.
	await create_timer(0.1).timeout
	prov.cancel_active_resquests()
	# Wait briefly for generate_content to resolve — must be WELL under 2s.
	var deadline := Time.get_ticks_msec() + 600
	while not gen_done[0] and Time.get_ticks_msec() < deadline:
		await process_frame
	var elapsed := Time.get_ticks_msec() - t0
	check("cancel: generate returned promptly (<1s, delay=2s)", gen_done[0] and elapsed < 1000,
		"done=%s elapsed=%dms" % [gen_done[0], elapsed])
	check("cancel: BotResponse marked cancelled",
		captured[0] != null and not str(captured[0].error).is_empty()
			and str(captured[0].error).to_lower().find("cancel") != -1,
		str(captured[0].error) if captured[0] != null else "<null>")
	var emissions_at_cancel: int = emissions[0]

	# Now let the LATE reply arrive (past the 2s delay) — it must NOT produce a
	# second emission/result (generation token neutralises it).
	await create_timer(2.2).timeout
	check("cancel: late reply produced NO second emission",
		emissions[0] == emissions_at_cancel, "before=%d after=%d" % [emissions_at_cancel, emissions[0]])
	so.chat_completed.disconnect(sig)
	prov.queue_free()


# --- Cancellation: stale-reply after re-generate (only B lands) -----------
func _test_stale_reply_after_regenerate(_so) -> void:
	print("\n-- Cancellation: cancel A, start B, only B lands --")
	var entry = {"key": "plugin:chatprovider:sr", "plugin_id": PLUGIN_ID, "entry_id": "sr",
		"display_name": "SR", "generate_tool": "minerva_chatprovider_generate",
		"history_mode": "newest_only", "timeout_sec": 600, "cancel_tool": "", "metadata": {}}
	var conn = StubConnection.new()
	conn.tree = self
	# A is slow; we'll cancel it. B uses the same conn but a short delay.
	conn.reply_delay_sec = 1.5
	conn.scripted_result = _answer_envelope("reply-A")
	var prov = _make_provider(entry, conn, StubManager.new())
	prov.owner_history_id = "hist-sr"

	var results := []
	# Start call A.
	var run_a := func():
		var b = await prov.generate_content([{"text": "A"}])
		results.append({"who": "A", "bot": b})
	run_a.call()
	await create_timer(0.1).timeout
	# Cancel A.
	prov.cancel_active_resquests()
	# Wait for A's generate_content to resolve (cancelled).
	var d1 := Time.get_ticks_msec() + 800
	while results.size() < 1 and Time.get_ticks_msec() < d1:
		await process_frame
	check("stale: call A resolved (cancelled) before its reply", results.size() == 1,
		"results=%d" % results.size())

	# Start call B with a NEW scripted result + short delay.
	conn.reply_delay_sec = 0.2
	conn.scripted_result = _answer_envelope("reply-B")
	var run_b := func():
		var b = await prov.generate_content([{"text": "B"}])
		results.append({"who": "B", "bot": b})
	run_b.call()

	# Let BOTH A's late reply (~1.5s from its start) and B's reply (~0.2s) land.
	await create_timer(2.0).timeout
	# Exactly two generate_content returns total: A(cancelled) + B(answer).
	check("stale: exactly A + B resolved (no extra from A's late reply)", results.size() == 2,
		"results=%d" % results.size())
	var b_entry = null
	for r in results:
		if r["who"] == "B":
			b_entry = r
	check("stale: B's result is reply-B", b_entry != null and b_entry["bot"].text == "reply-B",
		b_entry["bot"].text if b_entry != null else "<missing>")
	# A's entry must be the cancelled one, never carrying reply-A text.
	var a_entry = null
	for r in results:
		if r["who"] == "A":
			a_entry = r
	check("stale: A's result is cancelled, never reply-A",
		a_entry != null and a_entry["bot"].text != "reply-A" and not str(a_entry["bot"].error).is_empty(),
		"%s / %s" % [a_entry["bot"].text, a_entry["bot"].error] if a_entry != null else "<missing>")
	prov.queue_free()


# --- FIX 2: saved-selection key restore survives reorder ------------------
func _test_saved_selection_key_restore(so) -> void:
	print("\n-- Saved selection: key restore survives registration reorder --")
	var R = load(REGISTRY_PATH)
	var reg = R.new()
	# Register two entries in order: alpha then beta.
	reg.register_entry(PLUGIN_ID, {"entry_id": "alpha", "display_name": "Alpha PT",
		"generate_tool": "minerva_chatprovider_alpha", "history_mode": "newest_only"})
	reg.register_entry(PLUGIN_ID, {"entry_id": "beta", "display_name": "Beta PT",
		"generate_tool": "minerva_chatprovider_beta", "history_mode": "newest_only"})
	so.plugin_chat_provider_registry = reg

	var OB = load(PROVIDER_OPTION_BUTTON_PATH)
	var btn = OB.new()
	root.add_child(btn)
	await process_frame

	# Find beta's ordinal id and simulate selecting it (persists key).
	var beta_idx := -1
	for i in range(btn.get_item_count()):
		if btn.get_item_text(i) == "Beta PT":
			beta_idx = i
			break
	check("key-restore: beta present in first ordering", beta_idx != -1)
	if beta_idx == -1:
		btn.queue_free(); so.plugin_chat_provider_registry = null
		return
	btn.select(beta_idx)
	var beta_ordinal: int = btn.get_item_id(beta_idx)
	# Persist via the selection handler (saves DefaultProviderId + key).
	so.save_to_config_file("Providers", "DefaultProviderId", beta_ordinal)
	btn._on_provider_option_button_item_selected(beta_idx)
	var saved_key = so.get_config_file_value("Providers", "DefaultProviderKey")
	check("key-restore: persisted plugin entry key", str(saved_key) == "plugin:chatprovider:beta",
		str(saved_key))

	# Now REVERSE registration order: drop + re-register beta-first.
	reg.drop_plugin(PLUGIN_ID)
	reg.register_entry(PLUGIN_ID, {"entry_id": "beta", "display_name": "Beta PT",
		"generate_tool": "minerva_chatprovider_beta", "history_mode": "newest_only"})
	reg.register_entry(PLUGIN_ID, {"entry_id": "alpha", "display_name": "Alpha PT",
		"generate_tool": "minerva_chatprovider_alpha", "history_mode": "newest_only"})

	# Fresh button (simulates a reboot): _load_saved_provider should restore beta
	# by KEY, even though beta's ordinal is now different.
	var btn2 = OB.new()
	root.add_child(btn2)
	await process_frame
	# Sanity: beta's ordinal moved (it's now first).
	var beta_idx2 := -1
	for i in range(btn2.get_item_count()):
		if btn2.get_item_text(i) == "Beta PT":
			beta_idx2 = i
			break
	check("key-restore: restored selection is Beta PT (by key, not ordinal)",
		btn2.get_item_text(btn2.selected) == "Beta PT" if btn2.selected >= 0 else false,
		"selected_text=%s ordinal_changed=%s" % [
			btn2.get_item_text(btn2.selected) if btn2.selected >= 0 else "<none>",
			str(beta_ordinal != btn2.get_item_id(beta_idx2)) if beta_idx2 != -1 else "?"])

	btn.queue_free()
	btn2.queue_free()
	# Clean up persisted config so it doesn't leak into other suites.
	so.save_to_config_file("Providers", "DefaultProviderKey", "")
	so.plugin_chat_provider_registry = null


# --- Acceptance 7 ----------------------------------------------------------
func _test_service_history_roundtrip(so) -> void:
	print("\n-- ServiceHistory: plugin provider round-trip --")
	var R = load(REGISTRY_PATH)
	var reg = R.new()
	var entry = reg.register_entry(PLUGIN_ID, {"entry_id": "main", "display_name": "Probe",
		"generate_tool": "minerva_chatprovider_generate", "history_mode": "newest_only"})
	so.plugin_chat_provider_registry = reg

	var P = load(PROVIDER_PATH)
	var prov = P.new()
	prov.configure_from_entry(entry)

	var SH = load(SERVICE_HISTORY_PATH)
	var sh_obj = _new_service_history(prov, "hist-roundtrip")
	var serialized = sh_obj.Serialize()
	check("Serialize writes PluginProviderKey", serialized.get("PluginProviderKey", "") == "plugin:chatprovider:main",
		str(serialized.get("PluginProviderKey")))
	check("Serialize sets Provider to sentinel -1", int(serialized.get("Provider", 0)) == -1,
		str(serialized.get("Provider")))

	# Deserialize WITH entry present → PluginProvider restored.
	var restored = SH.Deserialize(serialized)
	check("Deserialize (entry present) restores PluginProvider",
		restored.provider != null and "entry_key" in restored.provider
			and restored.provider.entry_key == "plugin:chatprovider:main",
		str(restored.provider.get_script().resource_path) if restored.provider else "<null>")

	# Deserialize WITHOUT entry → default-provider fallback, no error.
	reg.drop_plugin(PLUGIN_ID)
	var restored2 = SH.Deserialize(serialized)
	check("Deserialize (entry absent) falls back to a non-null provider", restored2.provider != null)
	check("fallback provider is NOT a PluginProvider",
		restored2.provider != null and not ("entry_key" in restored2.provider
			and not str(restored2.provider.entry_key).is_empty()),
		restored2.provider.get_script().resource_path if restored2.provider else "<null>")
	so.plugin_chat_provider_registry = null


func _new_service_history(prov, hid):
	# ServiceHistory subclasses; use ChatHistory which is the CHAT service_type.
	var CH = load("res://Scripts/Models/ChatHistory.gd")
	return CH.new(prov, hid)


# --- Acceptance 1 + 6 (integration: real fixture via capability path) ------
func _test_integration_capability_path(so) -> void:
	print("\n-- Integration: register via broker capability path (real fixture) --")
	var py_check := OS.execute("python3", ["--version"], [], true)
	if py_check != OK:
		print("SKIP: python3 not available — integration test skipped")
		return

	var fixture_dir: String = ProjectSettings.globalize_path("res://" + FIXTURE_DIR_REL)
	var manifest_path: String = fixture_dir + "/manifest.json"
	if not FileAccess.file_exists(manifest_path):
		check("fixture manifest exists", false, manifest_path)
		return

	# Wait for plugin_tool_registry to be ready.
	var deadline := Time.get_ticks_msec() + 10000
	while so.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout

	var PM = load(PM_PATH)
	var pm = PM.new()
	root.add_child(pm)
	await process_frame

	var db = pm._db
	var def = db.get_by_id(PLUGIN_ID)
	if def == null:
		var res = await pm.install_plugin(manifest_path, true)
		check("install_plugin ok", res.get("ok", false), str(res))
		def = db.get_by_id(PLUGIN_ID)
	check("fixture definition loaded", def != null)
	if def == null:
		return

	# Wire the real registry on the broker so the capability handler reaches it.
	var registry = pm.get_chat_provider_registry()
	check("PluginManager exposes chat-provider registry", registry != null)
	var broker = so.get("plugin_capability_broker")
	if broker != null:
		broker.chat_provider_registry = registry
	# Grant the capability.
	var policy = pm.get_policy()
	if policy == null and "plugin_policy" in so:
		policy = so.get("plugin_policy")
	if policy != null:
		policy.grant_capability(PLUGIN_ID, "host.chat_providers.register")

	if def.state == S_RUNNING:
		await pm.stop_plugin(PLUGIN_ID)
	var start_res = await pm.start_plugin(PLUGIN_ID)
	check("start_plugin ok", start_res.get("ok", false), str(start_res))

	var conn = pm.get_connection(PLUGIN_ID)
	check("connection exists", conn != null)
	if conn == null:
		return

	# Drive register_self → plugin calls host.chat_providers.register.
	var reg_call = await conn.call_tool("register_self", {"history_mode": "newest_only"})
	check("register_self completed", reg_call is Dictionary and reg_call.get("success", false),
		str(reg_call))
	# The capability channel wraps a successful broker result as
	# {success:true, result:{...}}; the handler's payload (with key) is under .result.
	var broker_result = reg_call.get("register_result", {}) if reg_call is Dictionary else {}
	var broker_payload = broker_result.get("result", broker_result) if broker_result is Dictionary else {}
	check("broker returned a key",
		broker_payload is Dictionary and str(broker_payload.get("key", "")) == "plugin:chatprovider:main",
		str(broker_result))
	check("registry now has the entry (via capability path)",
		registry != null and registry.has_entry("plugin:chatprovider:main"))

	# Generate round-trip through the live fixture.
	var entry = registry.get_entry("plugin:chatprovider:main")
	var P = load(PROVIDER_PATH)
	var prov = P.new()
	prov.configure_from_entry(entry)
	prov._test_plugin_manager = pm
	root.add_child(prov)
	prov.owner_history_id = "hist-int"
	var bot = await prov.generate_content([{"text": "pong"}])
	check("live generate → pong-7", bot.text == "pong-7", "%s / err=%s" % [bot.text, bot.error])
	prov.queue_free()

	# Acceptance 6: stop plugin mid-chat → entry vanishes via lifecycle signal.
	await pm.stop_plugin(PLUGIN_ID)
	await process_frame
	check("entry vanishes on plugin stop (lifecycle signal)",
		registry != null and not registry.has_entry("plugin:chatprovider:main"))

	# In-flight generate after death resolves to error, no crash.
	var prov2 = P.new()
	prov2.configure_from_entry(entry)
	prov2._test_plugin_manager = pm
	root.add_child(prov2)
	var bot2 = await prov2.generate_content([{"text": "pong"}])
	check("generate after stop → BotResponse.error (no crash)", not bot2.error.is_empty(), bot2.error)
	prov2.queue_free()
