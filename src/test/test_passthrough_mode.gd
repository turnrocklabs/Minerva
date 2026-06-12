extends SceneTree
## W2 (chat-passthrough): passthrough chat-mode plumbing.
##
## Run: timeout 120 godot --headless --path src --script test/test_passthrough_mode.gd
##
## Acceptance (W2 contract):
##   1. ServiceHistory round-trip preserves PassthroughMode, BoundTerminalId,
##      PassthroughName (including a JSON stringify/parse cycle).
##   2. start_passthrough_chat (model core: _build_passthrough_history) with a
##      registered fake entry → flags set, provider is a PluginProvider for the
##      right entry; unknown entry → null (no fallback — binding is contractual).
##   3. Chooser lock: set_locked(true) → disabled; registry entry removed →
##      locked chooser keeps showing the bound name with " (offline)" and does
##      NOT fall back; entry returns → live name re-pinned; unlocked chooser
##      keeps W1 fallback behavior.
##   4. Badge: ChatHeader with a passthrough history shows "[Passthrough: <name>]".
##   5. Old saved chats (no new fields) deserialize with defaults false/empty.
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type.

const REGISTRY_PATH := "res://Scripts/Services/Plugins/PluginChatProviderRegistry.gd"
const PROVIDER_PATH := "res://Scripts/Services/Providers/PluginProvider.gd"
const PROVIDER_OPTION_BUTTON_PATH := "res://Scripts/UI/Controls/ProviderOptionButton.gd"
const SERVICE_HISTORY_PATH := "res://Scripts/Models/ServiceHistory.gd"
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const CHAT_HEADER_PATH := "res://Scripts/UI/Controls/ChatHeader.gd"
const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"

const PLUGIN_ID := "chatprovider"
const ENTRY_KEY := "plugin:chatprovider:main"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== W2 passthrough chat-mode test ===\n")
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


func _register_main_entry(reg, display_name: String = "Probe PT") -> Dictionary:
	return reg.register_entry(PLUGIN_ID, {
		"entry_id": "main", "display_name": display_name,
		"generate_tool": "minerva_chatprovider_generate",
		"history_mode": "newest_only"})


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return

	await _test_service_history_roundtrip(so)
	await _test_old_save_defaults(so)
	await _test_build_passthrough_history(so)
	await _test_chooser_lock(so)
	await _test_chooser_unlocked_keeps_fallback(so)
	await _test_header_badge(so)
	await _test_set_chat_model_guard(so)


# --- Acceptance 1 + JSON cycle ---------------------------------------------
func _test_service_history_roundtrip(so) -> void:
	print("\n-- ServiceHistory: passthrough fields round-trip --")
	var CH = load(CHAT_HISTORY_PATH)
	var sh = CH.new(null, "hist-pt-rt")
	sh.PassthroughMode = true
	sh.BoundTerminalId = "term-42"
	sh.PassthroughName = "Claude via relay"

	var serialized: Dictionary = sh.Serialize()
	check("Serialize writes PassthroughMode", serialized.get("PassthroughMode", false) == true)
	check("Serialize writes BoundTerminalId", str(serialized.get("BoundTerminalId", "")) == "term-42")
	check("Serialize writes PassthroughName", str(serialized.get("PassthroughName", "")) == "Claude via relay")

	# JSON cycle (ints arrive as floats; bools stay bools).
	var json_data = JSON.parse_string(JSON.stringify(serialized))
	check("JSON cycle yields Dictionary", json_data is Dictionary)
	var SH = load(SERVICE_HISTORY_PATH)
	var restored = SH.Deserialize(json_data)
	check("round-trip preserves PassthroughMode", restored.PassthroughMode == true)
	check("round-trip preserves BoundTerminalId", restored.BoundTerminalId == "term-42",
		restored.BoundTerminalId)
	check("round-trip preserves PassthroughName", restored.PassthroughName == "Claude via relay",
		restored.PassthroughName)

	# SERIALIZER_FIELDS contains the new fields (serialize-for-free contract).
	var fields: Array = SH.SERIALIZER_FIELDS
	for f in ["PassthroughMode", "BoundTerminalId", "PassthroughName"]:
		check("SERIALIZER_FIELDS has %s" % f, fields.has(f))


# --- Acceptance 5 -----------------------------------------------------------
func _test_old_save_defaults(so) -> void:
	print("\n-- ServiceHistory: old saves (no new fields) get defaults --")
	var CH = load(CHAT_HISTORY_PATH)
	var old_sh = CH.new(null, "hist-old")
	var old_dict: Dictionary = old_sh.Serialize()
	old_dict.erase("PassthroughMode")
	old_dict.erase("BoundTerminalId")
	old_dict.erase("PassthroughName")

	var SH = load(SERVICE_HISTORY_PATH)
	var restored = SH.Deserialize(old_dict)
	check("old save: PassthroughMode defaults false", restored.PassthroughMode == false)
	check("old save: BoundTerminalId defaults empty", restored.BoundTerminalId == "")
	check("old save: PassthroughName defaults empty", restored.PassthroughName == "")


# --- Acceptance 2 -----------------------------------------------------------
func _test_build_passthrough_history(so) -> void:
	print("\n-- ChatPane: _build_passthrough_history / start_passthrough_chat --")
	var R = load(REGISTRY_PATH)
	var reg = R.new()
	_register_main_entry(reg, "Term Provider")
	so.plugin_chat_provider_registry = reg

	var ChatPaneScript = load(CHATPANE_PATH)
	check("ChatPane.gd loads", ChatPaneScript != null)
	# start_passthrough_chat exists with the W3-facing signature.
	var has_api := false
	for m: Dictionary in ChatPaneScript.get_script_method_list():
		if m.get("name", "") == "start_passthrough_chat":
			has_api = m.get("args", []).size() == 3
	check("start_passthrough_chat(entry_key, display_name, bound_terminal_id) declared", has_api)

	# Model core on a bare (out-of-tree) instance — _ready never runs, no UI.
	var pane = ChatPaneScript.new()
	var history = pane._build_passthrough_history(ENTRY_KEY, "Claude CLI", "term-7")
	check("history created", history != null)
	if history != null:
		check("PassthroughMode set", history.PassthroughMode == true)
		check("BoundTerminalId set", history.BoundTerminalId == "term-7", history.BoundTerminalId)
		check("PassthroughName set", history.PassthroughName == "Claude CLI", history.PassthroughName)
		check("chat tab named after the session name", history.HistoryName == "Claude CLI",
			history.HistoryName)
		check("provider is a PluginProvider for the right entry",
			history.provider != null and "entry_key" in history.provider
				and history.provider.entry_key == ENTRY_KEY,
			str(history.provider))

	# Display name falls back to the entry's display_name when empty.
	var history2 = pane._build_passthrough_history(ENTRY_KEY, "", "")
	check("empty display_name falls back to entry display_name",
		history2 != null and history2.PassthroughName == "Term Provider",
		history2.PassthroughName if history2 != null else "<null>")
	check("empty display_name keeps the generic Chat-N tab name",
		history2 != null and history2.HistoryName.begins_with("Chat"),
		history2.HistoryName if history2 != null else "<null>")

	# Unknown entry → null, NO fallback provider (contractual binding).
	var missing = pane._build_passthrough_history("plugin:nope:none", "X", "")
	check("unknown entry → null (no fallback)", missing == null)

	pane.free()
	so.plugin_chat_provider_registry = null


# --- Acceptance 3: locked chooser -------------------------------------------
func _test_chooser_lock(so) -> void:
	print("\n-- Chooser: lock mechanism --")
	var R = load(REGISTRY_PATH)
	var reg = R.new()
	_register_main_entry(reg, "Probe PT")
	so.plugin_chat_provider_registry = reg

	var OB = load(PROVIDER_OPTION_BUTTON_PATH)
	var btn = OB.new()
	root.add_child(btn)
	await process_frame

	# Select the plugin entry, then lock.
	var idx := -1
	for i in range(btn.get_item_count()):
		if btn.get_item_text(i) == "Probe PT":
			idx = i
			break
	check("lock: plugin entry present pre-lock", idx != -1)
	if idx == -1:
		btn.queue_free()
		so.plugin_chat_provider_registry = null
		return
	btn.select(idx)
	btn.set_locked(true, "Passthrough chat — provider is fixed")
	check("lock: button disabled", btn.disabled == true)
	check("lock: tooltip set", btn.tooltip_text == "Passthrough chat — provider is fixed",
		btn.tooltip_text)
	check("lock: is_locked()", btn.is_locked())

	# Registry entry vanishes → locked chooser keeps the name + (offline); no fallback.
	reg.drop_plugin(PLUGIN_ID)
	await process_frame
	var sel_text: String = btn.get_item_text(btn.selected) if btn.selected >= 0 else "<none>"
	check("lock: entry vanished → shows '<name> (offline)'", sel_text == "Probe PT (offline)", sel_text)
	check("lock: still disabled after vanish", btn.disabled == true)

	# Entry returns → live name re-pinned (no offline suffix).
	_register_main_entry(reg, "Probe PT")
	await process_frame
	sel_text = btn.get_item_text(btn.selected) if btn.selected >= 0 else "<none>"
	check("lock: entry returned → live name re-pinned", sel_text == "Probe PT", sel_text)
	check("lock: still locked after return", btn.is_locked() and btn.disabled)

	# lock_to_entry with an already-gone entry (tab-switch into an offline
	# passthrough chat) → offline placeholder immediately.
	reg.drop_plugin(PLUGIN_ID)
	await process_frame
	btn.lock_to_entry(ENTRY_KEY, "Probe PT", "tip")
	sel_text = btn.get_item_text(btn.selected) if btn.selected >= 0 else "<none>"
	check("lock_to_entry (gone): shows offline placeholder", sel_text == "Probe PT (offline)", sel_text)

	# Unlock restores interactivity.
	btn.set_locked(false)
	check("unlock: enabled again", btn.disabled == false)
	check("unlock: is_locked() false", not btn.is_locked())

	btn.queue_free()
	so.plugin_chat_provider_registry = null


# --- Acceptance 3 (other half): unlocked chooser keeps W1 fallback ----------
func _test_chooser_unlocked_keeps_fallback(so) -> void:
	print("\n-- Chooser: unlocked keeps W1 fallback on entry vanish --")
	var R = load(REGISTRY_PATH)
	var reg = R.new()
	_register_main_entry(reg, "Probe PT")
	so.plugin_chat_provider_registry = reg

	var OB = load(PROVIDER_OPTION_BUTTON_PATH)
	var btn = OB.new()
	root.add_child(btn)
	await process_frame

	var idx := -1
	for i in range(btn.get_item_count()):
		if btn.get_item_text(i) == "Probe PT":
			idx = i
			break
	check("fallback: plugin entry present", idx != -1)
	if idx == -1:
		btn.queue_free()
		so.plugin_chat_provider_registry = null
		return
	btn.select(idx)

	var emitted := [0]
	var sig := func(_p): emitted[0] += 1
	btn.provider_selected.connect(sig)

	reg.drop_plugin(PLUGIN_ID)
	await process_frame
	check("fallback: unlocked chooser fell back to default selection",
		btn.selected == 0 and btn.get_item_text(0) != "Probe PT (offline)",
		"selected=%d text=%s" % [btn.selected, btn.get_item_text(btn.selected) if btn.selected >= 0 else "<none>"])
	check("fallback: provider_selected emitted on fallback", emitted[0] >= 1, str(emitted[0]))
	check("fallback: chooser stays enabled", btn.disabled == false)

	btn.provider_selected.disconnect(sig)
	btn.queue_free()
	so.plugin_chat_provider_registry = null


# --- Acceptance 4: header badge ---------------------------------------------
func _test_header_badge(so) -> void:
	print("\n-- ChatHeader: [Passthrough: <name>] badge --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-badge")
	history.PassthroughMode = true
	history.PassthroughName = "Claude via relay"

	var Header = load(CHAT_HEADER_PATH)
	var header = Header.new()
	header.setup(history)

	var badge_text := ""
	for child in header.get_children():
		if child is Label and str(child.text).begins_with("[Passthrough:"):
			badge_text = child.text
	check("badge present with name", badge_text == "[Passthrough: Claude via relay]", badge_text)

	# Negative: a normal chat shows no passthrough badge.
	var plain = CH.new(null, "hist-plain")
	var header2 = Header.new()
	header2.setup(plain)
	var found := false
	for child in header2.get_children():
		if child is Label and str(child.text).begins_with("[Passthrough:"):
			found = true
	check("no badge on non-passthrough chat", not found)

	header.free()
	header2.free()


# --- Lock backstop: MCP route may not switch a passthrough chat's provider ---
func _test_set_chat_model_guard(so) -> void:
	print("\n-- MCPChatTools: minerva_set_chat_model rejects passthrough chats --")
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, "hist-pt-guard")
	history.PassthroughMode = true
	history.PassthroughName = "Claude via relay"
	so.ChatList.append(history)

	var Module = load("res://Scripts/Services/MCP/Modules/MCPChatTools.gd")
	var module = Module.new(null)
	var result: Dictionary = await module.handle("minerva_set_chat_model",
		{"chat_id": "hist-pt-guard", "provider": "openai", "model": "gpt-4o"})
	check("set_chat_model on passthrough chat returns error", result.has("error"), str(result))
	check("error names the passthrough lock",
		str(result.get("error", "")).to_lower().contains("passthrough"), str(result))
	check("provider unchanged by rejected call", history.provider == null)

	so.ChatList.erase(history)
