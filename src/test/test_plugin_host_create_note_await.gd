extends SceneTree
## The host awaits a panel's create-note hook.
##
## A panel that renders its note preview off-screen has to yield a frame before
## it can hand the note back, so its `_on_panel_create_note_request` is a
## coroutine. A host that called it without awaiting would receive the
## coroutine's handle in place of the Dictionary, treat that as an unusable
## payload, and fall back to a screenshot — every such panel would lose its
## note silently. This pins that PluginScenePanelHost.invoke_create_note hands
## back the Dictionary for a coroutine hook AND for a plain synchronous one,
## and null for a panel with no hook at all.
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script test/test_plugin_host_create_note_await.gd

var _pass: int = 0
var _fail: int = 0


class SyncPanel extends Node:
	func _on_panel_create_note_request(ctx: Dictionary) -> Dictionary:
		return {"kind": "text", "text": "sync:" + str(ctx.get("tab_title", ""))}


class CoroutinePanel extends Node:
	func _on_panel_create_note_request(ctx: Dictionary) -> Dictionary:
		await get_tree().process_frame
		return {"kind": "text", "text": "async:" + str(ctx.get("tab_title", ""))}


class HooklessPanel extends Node:
	pass


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	print("=== PluginScenePanelHost.invoke_create_note awaits the hook ===\n")
	var host: Script = load("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
	var ctx := {"plugin_id": "stub", "panel_name": "stub_panel", "tab_title": "T"}

	var sync_panel := SyncPanel.new()
	root.add_child(sync_panel)
	var sync_result: Variant = await host.invoke_create_note(sync_panel, ctx)
	check("a synchronous hook's Dictionary comes back unchanged",
		sync_result is Dictionary and str((sync_result as Dictionary).get("text", "")) == "sync:T")

	var coroutine_panel := CoroutinePanel.new()
	root.add_child(coroutine_panel)
	var async_result: Variant = await host.invoke_create_note(coroutine_panel, ctx)
	check("a coroutine hook's Dictionary comes back after its yield — not a coroutine handle",
		async_result is Dictionary and str((async_result as Dictionary).get("text", "")) == "async:T")

	var hookless := HooklessPanel.new()
	root.add_child(hookless)
	var none: Variant = await host.invoke_create_note(hookless, ctx)
	check("a panel without the hook yields null (the screenshot fallback's cue)", none == null)

	sync_panel.queue_free()
	coroutine_panel.queue_free()
	hookless.queue_free()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)
