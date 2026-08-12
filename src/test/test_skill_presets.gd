extends SceneTree
## Regression guard for the core/profile boundary (docket 019ff2b218a1).
## Domain plugins own their skills and prompts; core presets stay domain-neutral.
##
## Run: godot --headless --path src --script test/test_skill_presets.gd

const SkillPresetsScript := preload("res://Scripts/Services/Skills/SkillPresets.gd")
const PluginEditorRegistryScript := preload("res://Scripts/Services/Plugins/PluginEditorRegistry.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Core skill preset boundary tests ===\n")
	test_generic_presets_remain_available()
	test_no_pcb_profile_or_prompt_ships_in_core()
	test_legacy_pcb_extension_is_not_reserved_by_core()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func test_generic_presets_remain_available() -> void:
	var expected_ids := [
		"general_assistant",
		"web_research",
		"code_assistant",
		"data_analysis",
		"project_management",
		"full_access",
	]
	for preset_id in expected_ids:
		check("generic preset remains available: %s" % preset_id,
			SkillPresetsScript.get_preset(preset_id) != null)


func test_no_pcb_profile_or_prompt_ships_in_core() -> void:
	check("legacy pcb_design preset is absent",
		SkillPresetsScript.get_preset("pcb_design") == null)

	for preset in SkillPresetsScript.get_all():
		var exposed_text := " ".join([
			preset.id,
			preset.name,
			preset.description,
			" ".join(preset.prompt_fragments),
		]).to_lower()
		check("%s has no PCB-specific identity or prompt" % preset.id,
			not exposed_text.contains("pcb")
			and not exposed_text.contains("electronics design"))
		check("%s has no PCB-specific tool-set binding" % preset.id,
			"pcb" not in preset.tool_sets)


func test_legacy_pcb_extension_is_not_reserved_by_core() -> void:
	check("legacy .minpcb extension is available for plugin ownership",
		".minpcb" not in PluginEditorRegistryScript.CORE_EXTENSIONS)
