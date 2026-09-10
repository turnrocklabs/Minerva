extends SceneTree
## Wide test for the ONE Core-action enumerator (CoreActionCatalog) and its
## consumers: the provider chooser's spec builder, the MCP model_spec resolver,
## and host.models.list_models("turnrock").
##
## Run: godot --headless --path src --script test/test_core_action_catalog.gd
##
## Method: the real Core autoload's `services` array is swapped for a stub of
## two services / three actions (real Service and Action objects — no mocks of
## the host's own types), then restored. Oracles are named at each check.

const BROKER_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== Core Action Catalog Test ===\n")
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


func _stub_services() -> Array[Service]:
	var chat := Service.new({
		"name": "Model Chat",
		"description": "chat models",
		"client_id": "model-chat",
		"actions": [
			{"name": "qwen3", "description": "qwen", "topic": "chat/qwen3"},
			{"name": "llama4", "description": "llama", "topic": "chat/llama4"},
		],
	})
	var notes := Service.new({
		"name": "Notes",
		"description": "notes",
		"client_id": "etsu-notes",
		# Deliberately reuses a Model Chat action name: model_name alone collides,
		# so the spec (service_client_id + action_name) is what disambiguates.
		"actions": [
			{"name": "qwen3", "description": "notes qwen", "topic": "notes/qwen3"},
		],
	})
	var out: Array[Service] = [chat, notes]
	return out


func _run() -> void:
	await process_frame
	await process_frame

	var singleton = root.get_node_or_null("SingletonObject")
	var core = root.get_node_or_null("Core")
	check("SingletonObject autoload present", singleton != null)
	check("Core autoload present", core != null)
	if singleton == null or core == null:
		return

	var turnrock: int = singleton.provider_from_key("turnrock")
	check("turnrock is a known provider key", turnrock != -1)
	if turnrock == -1:
		return

	# --- install the stub, remembering what to restore -----------------------
	var saved_services: Array[Service] = core.services.duplicate()
	var had_enabled: bool = singleton._enabled_providers.has(turnrock)
	var was_enabled: bool = singleton._enabled_providers.get(turnrock, false)
	singleton._enabled_providers[turnrock] = true
	var stub := _stub_services()
	core.services = stub

	# --- 1. the enumerator lists exactly the stub, and nothing else ----------
	# Oracle: the stub Service/Action objects built above.
	var entries: Array = CoreActionCatalog.list_actions()
	check("catalog lists exactly the stub's three actions", entries.size() == 3,
		"got %d" % entries.size())
	if entries.size() == 3:
		var names: Array = []
		for e in entries:
			names.append("%s/%s" % [str(e.get("service_client_id", "")), str(e.get("action_name", ""))])
		check("catalog lists them in service order",
			names == ["model-chat/qwen3", "model-chat/llama4", "etsu-notes/qwen3"],
			str(names))
		check("entry carries the service display name",
			str(entries[0].get("service_name", "")) == "Model Chat")

	# --- 2. display string matches what a live CoreProvider calls itself -----
	# Oracle: CoreProvider.model_name for the same (service, action).
	var display_ok := true
	for i in range(stub.size()):
		for action in stub[i].actions:
			var probe := CoreProvider.new(stub[i], action)
			var want: String = str(probe.model_name)
			probe.free()
			var found := false
			for e in entries:
				if str(e.get("action_name", "")) == action.name \
						and str(e.get("service_client_id", "")) == stub[i].client_id:
					found = str(e.get("display", "")) == want
					break
			if not found:
				display_ok = false
	check("every entry's display equals CoreProvider.model_name", display_ok)

	# --- 3. the spec is byte-identical to the chooser's ----------------------
	# Oracle: ProviderOptionButton.get_item_provider_spec on a dropdown item
	# carrying the same [Service, Action] metadata the chooser stores. Since the
	# chooser now delegates to spec_for(), this is the enumerator compared with
	# itself THROUGH the chooser: it pins the chooser's delegation and the
	# metadata contract, not the spec's field set. The independent check on the
	# field set is the hand-mirrored broker validation further down, which
	# spells out what host.providers.chat requires.
	var chooser := ProviderOptionButton.new()
	chooser.add_item("qwen3", 1000)
	chooser.set_item_metadata(0, [stub[0], stub[0].actions[0]])
	var chooser_spec: Dictionary = chooser.get_item_provider_spec(0)
	var catalog_spec: Dictionary = entries[0].get("model_spec", {}) if entries.size() > 0 else {}
	check("catalog spec equals the chooser's spec for the same action",
		chooser_spec == catalog_spec, "%s vs %s" % [str(chooser_spec), str(catalog_spec)])

	# --- 4. host.models.list_models("turnrock") returns those entries --------
	# Oracle: the catalog listing from (1) — the capability must not invent,
	# drop or rename anything, and must never emit the "Unknown" placeholder.
	var broker = load(BROKER_PATH).new(null, null)
	var reply: Dictionary = broker._handle_host_models_list_models("tester", {"provider": "turnrock"})
	var models: Array = (reply.get("result", {}) as Dictionary).get("models", [])
	check("capability lists three turnrock models",
		reply.get("success", false) and models.size() == 3, "got %d" % models.size())
	if models.size() == 3:
		var shape_ok := true
		for i in range(3):
			var m: Dictionary = models[i]
			var e: Dictionary = entries[i]
			if m.keys().size() != 3 \
					or str(m.get("model_name", "")) != str(e.get("action_name", "")) \
					or str(m.get("display", "")) != str(e.get("display", "")) \
					or m.get("model_spec", {}) != e.get("model_spec", {}):
				shape_ok = false
		check("each model is {model_name=action, display, model_spec}", shape_ok, str(models))
		var placeholder := false
		for m in models:
			if str((m as Dictionary).get("model_name", "")) == "Unknown":
				placeholder = true
		check("no 'Unknown' placeholder among the models", not placeholder)
		# Oracle: the stub's duplicated action name — same model_name, different
		# service, so only the spec can tell the two apart.
		check("same-named actions on different services stay distinct",
			str((models[0] as Dictionary).get("model_name", "")) == str((models[2] as Dictionary).get("model_name", "")) \
				and (models[0] as Dictionary).get("model_spec", {}) != (models[2] as Dictionary).get("model_spec", {}))

	# --- 4b. the provider listing carries turnrock so list_providers ->
	# list_models reaches Core ------------------------------------------------
	# Oracle: the stub has actions, so the key must be present; step 7 asserts
	# the empty case.
	var providers_reply: Dictionary = broker._handle_host_models_list_providers("tester", {})
	var providers: Array = (providers_reply.get("result", {}) as Dictionary).get("providers", [])
	var has_turnrock := false
	for p in providers:
		if str((p as Dictionary).get("key", "")) == "turnrock":
			has_turnrock = true
			check("turnrock is listed with its display name",
				str((p as Dictionary).get("display", "")) == "TurnRock")
	check("list_providers includes turnrock when Core has actions", has_turnrock, str(providers))

	# --- 5. a returned spec resolves to the provider the chooser builds ------
	# Oracle: ProviderOptionButton._get_provider_from_id — the chooser's own
	# construction path for the selected dropdown item.
	var chooser_provider = chooser._get_provider_from_id(1000)
	var tools := MCPChatTools.new(null)
	var resolved: Dictionary = tools._resolve_provider_from_model_spec(catalog_spec)
	var resolved_provider = resolved.get("provider", null)
	check("model_spec resolves to a provider", resolved_provider != null,
		str(resolved.get("error", "")))
	if resolved_provider != null and chooser_provider != null:
		check("resolved provider is a CoreProvider on the same service/action",
			resolved_provider is CoreProvider \
				and resolved_provider.service == chooser_provider.service \
				and resolved_provider.action == chooser_provider.action)
		check("resolved provider reports the listed display name",
			str(resolved_provider.model_name) == str(entries[0].get("display", "")))
	# host.providers.chat is not DISPATCHED here — past resolution it issues a
	# live Core request with a 30-minute timeout. Its core_action branch now
	# resolves through exactly this call (CapabilityBroker.gd, model_spec
	# kind="core_action"), so asserting it here covers the same resolution.
	# Oracle: the chooser's provider, built from the dropdown metadata.
	var broker_match: Dictionary = CoreActionCatalog.find_action(
		str(catalog_spec.get("service_client_id", "")),
		str(catalog_spec.get("action_name", "")))
	if chooser_provider != null:
		check("host.providers.chat resolves the spec to the chooser's service/action",
			not broker_match.is_empty() \
				and broker_match.get("service", null) == chooser_provider.service \
				and broker_match.get("action", null) == chooser_provider.action)
	check("spec satisfies host.providers.chat's core_action validation",
		str(catalog_spec.get("kind", "")) == "core_action" \
			and not str(catalog_spec.get("service_client_id", "")).is_empty() \
			and not str(catalog_spec.get("action_name", "")).is_empty())

	# The plugin-settings path stores only a model_name (PreferencesPopup's
	# picker), so create_provider_for must resolve a Core action by name too —
	# otherwise a turnrock selection silently falls back to a ChatGPT provider
	# in ChatPane._create_passthrough_distill_provider.
	# Oracle: the stub's own Service/Action objects.
	var by_name = singleton.create_provider_for("turnrock", "llama4")
	check("create_provider_for resolves a Core action by name",
		by_name != null and by_name is CoreProvider \
			and by_name.service == stub[0] and by_name.action == stub[0].actions[1])
	if by_name != null:
		by_name.free()
	# A duplicated name resolves to the first match in service order — the order
	# the chooser lists them in.
	var dupe = singleton.create_provider_for("turnrock", "qwen3")
	check("a name on two services resolves to the first in service order",
		dupe != null and dupe.service == stub[0])
	if dupe != null:
		dupe.free()
	check("a name no service has resolves to null",
		singleton.create_provider_for("turnrock", "no-such-action") == null)

	if resolved_provider != null:
		resolved_provider.free()
	if chooser_provider != null:
		chooser_provider.free()

	# --- 6. an unrelated provider's listing is unchanged ---------------------
	# Oracle: the pre-change entry shape — exactly {model_name, display}. Read
	# from whichever manager already holds models, so nothing is injected and
	# nothing needs restoring; skipped (with a note) on a machine that has none.
	var other_models: Array = []
	var other_key := ""
	for id_base in singleton._dynamic_provider_map:
		var entry_d: Dictionary = singleton._dynamic_provider_map[id_base]
		var mgr = entry_d.get("manager", null)
		if mgr == null or mgr.models.is_empty():
			continue
		var p_enum: int = int(entry_d.get("provider", -2))
		var had_p: bool = singleton._enabled_providers.has(p_enum)
		var was_p: bool = singleton._enabled_providers.get(p_enum, false)
		singleton._enabled_providers[p_enum] = true
		other_key = singleton.provider_key(p_enum)
		other_models = singleton.list_enabled_models(other_key)
		if had_p:
			singleton._enabled_providers[p_enum] = was_p
		else:
			singleton._enabled_providers.erase(p_enum)
		if not other_models.is_empty():
			break
	if other_models.is_empty():
		print("NOTE: no configured models on this machine — non-turnrock shape not asserted")
	else:
		var cg_ok := true
		for m in other_models:
			var keys: Array = (m as Dictionary).keys()
			keys.sort()
			if keys != ["display", "model_name"]:
				cg_ok = false
		check("non-turnrock models (%s) keep the {model_name, display} shape" % other_key,
			cg_ok, str(other_models))

	# --- 7. Core with no services yields nothing, not a placeholder ---------
	# Oracle: the empty stub — a plugin must see an empty list, never "Unknown".
	var empty_services: Array[Service] = []
	core.services = empty_services
	check("no services -> empty catalog", CoreActionCatalog.list_actions().is_empty())
	check("no services -> empty turnrock model list",
		singleton.list_enabled_models("turnrock").is_empty())
	var empty_listed := false
	for p in singleton.list_enabled_providers():
		if str((p as Dictionary).get("key", "")) == "turnrock":
			empty_listed = true
	check("no services -> turnrock absent from list_providers", not empty_listed)
	# A node without a `services` property stands in for Core being absent.
	var bare := Node.new()
	check("node without services -> empty catalog",
		CoreActionCatalog.list_actions(bare).is_empty())
	bare.free()

	# --- restore -------------------------------------------------------------
	core.services = saved_services
	if had_enabled:
		singleton._enabled_providers[turnrock] = was_enabled
	else:
		singleton._enabled_providers.erase(turnrock)
	chooser.free()
