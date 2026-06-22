extends SceneTree
## Integration-boundary test for the plugin-preferences DCR (task C6.1).
##
## Run: godot --headless --path src --script test/test_preferences_summarize_integration.gd
##
## Exercises the REAL chain end to end: the MCP set_preference tool writes the
## "core" summarization model + prompt into PluginSettingsStore, then a real
## ChatPane.summarize_passthrough_to_note reads those prefs, builds the prompt,
## and stamps provenance into the note. Only the persistence backend (in-memory)
## and the chat provider (a capturing stub) are substituted — every other
## component is the production object.

const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const CHAT_HISTORY_ITEM_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const STORE_PATH := "res://Scripts/Services/Plugins/PluginSettingsStore.gd"
const MCP_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPPreferenceTools.gd"

const STUB_SRC := """
extends \"res://Scripts/Services/Providers/BaseProvider.gd\"

var calls := 0
var last_prompt = null

func Format(chat) -> Variant:
	return {\"text\": chat.Message}

func generate_content(prompt, _additional_params = {}):
	calls += 1
	last_prompt = prompt
	var r = load(\"res://Scripts/Models/BotResponse.gd\").new()
	r.text = \"DISTILLED SUMMARY\"
	return r
"""

var _pass: int = 0
var _fail: int = 0


class MemPersist:
	var mem: Dictionary = {}

	func read(section: String, key: String) -> Variant:
		return (mem.get(section, {}) as Dictionary).get(key, null)

	func write(section: String, key: String, value: Variant) -> void:
		if not mem.has(section):
			mem[section] = {}
		(mem[section] as Dictionary)[key] = value


class FakeDB:
	func get_by_id(_plugin_id: String):
		return null

	func get_all() -> Array:
		return []


func _init() -> void:
	print("=== Preferences→Summarize Integration Test (C6.1) ===\n")
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


func _make_stub():
	var script := GDScript.new()
	script.source_code = STUB_SRC
	assert(script.reload() == OK)
	return script.new()


func _make_passthrough_history(hist_id: String):
	var CH = load(CHAT_HISTORY_PATH)
	var history = CH.new(null, hist_id)
	history.PassthroughMode = true
	history.PassthroughName = "Claude CLI"
	var CHI = load(CHAT_HISTORY_ITEM_PATH)
	var u = CHI.new()
	u.Role = 0  # USER
	u.Message = "hello from the human"
	history.HistoryItemList.append(u)
	var a = CHI.new()
	a.Role = 1  # ASSISTANT
	a.Message = "hi, this is the CLI replying"
	history.HistoryItemList.append(a)
	return history


func _run() -> void:
	await process_frame
	await process_frame

	var so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", so != null)
	if so == null:
		return

	# Swap in a controlled store so the real config file is untouched.
	var store = load(STORE_PATH).new(FakeDB.new(), MemPersist.new())
	var saved_store = so.plugin_settings_store
	so.plugin_settings_store = store

	# Configure the summarization model + prompt through the real MCP tool, which
	# resolves the live (swapped) store from SingletonObject.
	var tools = load(MCP_TOOLS_PATH).new(null)
	var set_model: Dictionary = tools.handle("minerva_set_preference",
		{"scope": "core", "key": "model", "value": "integration-model"})
	check("MCP set model ok", set_model.get("success", false), str(set_model))
	var set_prompt: Dictionary = tools.handle("minerva_set_preference",
		{"scope": "core", "key": "prompt", "value": "INTEGRATION PROMPT"})
	check("MCP set prompt ok", set_prompt.get("success", false), str(set_prompt))
	var got_model: Dictionary = tools.handle("minerva_get_preference",
		{"scope": "core", "key": "model"})
	check("MCP get reflects model", got_model.get("value") == "integration-model", str(got_model))

	# Run a real summarize over a passthrough chat with the capturing stub provider.
	var pane = load(CHATPANE_PATH).new()
	var history = _make_passthrough_history("hist-c61")
	var stub = _make_stub()
	var result: Dictionary = await pane.summarize_passthrough_to_note(history, stub)
	check("summarize ok", result.get("ok", false), str(result))
	check("exactly one provider call", stub.calls == 1, str(stub.calls))

	# The prompt sent to the provider must START with the configured prompt and
	# then carry the appended transcript (proving the store value + append path).
	var sent_prompt := ""
	if stub.last_prompt is Array and (stub.last_prompt as Array).size() > 0:
		sent_prompt = str((stub.last_prompt[0] as Dictionary).get("text", ""))
	check("prompt uses the configured text", sent_prompt.begins_with("INTEGRATION PROMPT"), sent_prompt)
	check("transcript appended after the prompt", sent_prompt.find("You: hello from the human") != -1, sent_prompt)
	check("no %-format leakage", sent_prompt.find("%d") == -1 and sent_prompt.find("%s") == -1)

	# The note records provenance: the configured model + that the prompt was custom.
	var note = so.get_registered_object(str(result.get("note_id", "")))
	check("note created + findable", note != null)
	if note != null:
		var controls = note.get_controls_container()
		var body := str(controls.content) if controls != null else ""
		check("note stamps the configured model",
			body.find("Summary model: integration-model") != -1, body)
		check("note marks the prompt as custom", body.find("prompt: custom") != -1, body)
		check("note keeps the distilled text", body.begins_with("DISTILLED SUMMARY"), body)
		note.free()

	pane.free()
	stub.free()
	so.plugin_settings_store = saved_store
