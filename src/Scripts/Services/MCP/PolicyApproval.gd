class_name PolicyApproval
extends RefCounted
## When an agent's change to a Docket item needs a person's approval, and the
## dialog that asks for it. Policy items gate asymmetrically: raising
## enforcement is free; lowering it (suspending or archiving a policy,
## editing its rule, deleting it) needs a person. Used by the embedded
## Docket's tools (MCPDocketTools) and by the Docket plugin's host
## (DocketHost), so both ask the same thing.

## The Docket tools that can lower a policy's enforcement.
const TOOLS := ["docket_transition", "docket_update", "docket_delete"]


## Whether `tool` with `arguments` would lower the enforcement of `item`
## (the item as the tool would find it).
static func lowers_enforcement(tool: String, arguments: Dictionary, item: Dictionary) -> bool:
	if not tool in TOOLS or str(item.get("type", "")) != "policy":
		return false
	match tool:
		"docket_transition":
			# draft → proposed → active raise enforcement; anything else lowers it.
			return not str(arguments.get("to", "")) in ["proposed", "active"]
		"docket_update":
			return arguments.has("description")
		_:
			return true


## Shows a person what an agent asks to do to the policy titled `title` and
## waits for their answer: true only when they approve. Without a display
## (headless) or a scene tree the answer is no.
static func request(tool: String, arguments: Dictionary, title: String) -> bool:
	var action_desc: String
	match tool:
		"docket_transition":
			action_desc = "transition policy to '%s'" % str(arguments.get("to", "?"))
		"docket_update":
			action_desc = "modify policy rule content"
		"docket_delete":
			action_desc = "permanently delete policy"
		_:
			action_desc = "modify policy"

	var tree := Engine.get_main_loop()
	if DisplayServer.get_name() == "headless" or tree == null or not tree is SceneTree:
		return false
	var dialog := ConfirmationDialog.new()
	dialog.title = "Policy Modification — Human Approval Required"
	dialog.dialog_text = "An agent is requesting to %s:\n\n\"%s\"\n\nThis will decrease policy enforcement.\nOnly approve if you intended this change." % [action_desc, title]
	dialog.ok_button_text = "Approve"
	dialog.cancel_button_text = "Deny"
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_PRIMARY_SCREEN
	dialog.size = Vector2i(500, 200)

	(tree as SceneTree).root.add_child(dialog)
	dialog.popup_centered()

	var result := [false]
	var done := [false]
	dialog.confirmed.connect(func():
		result[0] = true
		done[0] = true
	)
	dialog.canceled.connect(func():
		result[0] = false
		done[0] = true
	)
	while not done[0]:
		await (tree as SceneTree).process_frame

	dialog.queue_free()
	return result[0]
