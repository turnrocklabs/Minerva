extends Node
## An explicit test scene replaces MainScene; autoloads still start normally.
const SUITES := ["policy_owner", "skill_owner", "trigger_feed", "prompt_and_session"]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in SUITES:
		push_error("Docket owner scene requires exactly one supported suite")
		get_tree().quit(2)
		return
	var profile := OS.get_environment("MINERVA_TEST_PROFILE_ROOT")
	if not profile.is_absolute_path() or not OS.get_user_data_dir().begins_with(profile.trim_suffix("/") + "/"):
		push_error("Docket owner scene requires an isolated absolute test profile")
		get_tree().quit(2)
		return
	var script := load("res://test/test_docket_%s.gd" % args[0]) as GDScript
	if script == null or not script.can_instantiate():
		push_error("Docket owner suite could not be loaded")
		get_tree().quit(2)
		return
	add_child(script.new())
