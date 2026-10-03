extends SceneTree
## Off-tree contract fixture; GPU pixel truth is a separate HITL check.
var failures: int = 0

class ProbeEditor extends Control:
	var tab_title: String = "Duplicate"

class FallbackHost extends AnnotationHost:
	var panel: Control
	func get_panel() -> Control:
		return panel

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: " + label)

func _init() -> void:
	await process_frame
	var services = load("res://Scripts/Services/Plugins/PanelServices.gd")
	var panel = load("res://test/fixtures/panel_probe/PanelProbe.gd").new()
	root.add_child(panel)
	var broker = load("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd").new()
	broker.register_panel(panel, "probe", "Probe", PackedStringArray())
	var resolved: Dictionary = services.resolve("Probe", broker, [], true)
	check(resolved.ok and resolved.panel == panel and resolved.host == panel.host,
		"panel and annotation host resolve together")
	check(resolved.plugin_id == "probe" and resolved.broker_bound, "broker owns panel")
	check(services.views(panel) == ["active", "detail"], "named slots listed")
	var target: Dictionary = services.capture_target(resolved, "detail")
	check(target.ok and target.viewport == panel.slot and target.surface == null,
		"named capture selects its SubViewport without main-window crop")
	var active: Dictionary = services.capture_target(resolved)
	check(active.ok and active.viewport == root and active.surface == panel,
		"active capture selects visible panel crop on main viewport")
	var missing: Dictionary = services.capture_target(resolved, "missing")
	check(not missing.ok and missing.views.has("detail"), "unknown view lists slots")
	check(not services.resolve("missing", broker, [], true).ok, "unknown editor refuses")
	# Exercise the production dispatcher preparation without the unavailable
	# schema validator: the routing oracle must not depend on that baseline gap.
	var registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new()
	registry.scene_panel_broker = broker
	var call: Dictionary = registry._prepare_panel_call("probe", "echo", {"editor_name": "Probe"})
	check(call.ok and call.panel == panel, "panel dispatcher uses shared resolution")
	var reply: Dictionary = call.panel.handle_tool("echo", call.args)
	check(reply == {"tool": "echo", "editor_name": "Probe"}, "routed fixture executes")
	check(not registry._prepare_panel_call("other", "echo", {"editor_name": "Probe"}).ok,
		"cross-plugin panel access fails closed")
	var first := ProbeEditor.new()
	var second := ProbeEditor.new()
	check(not services.resolve("Duplicate", broker, [first, second]).ok,
		"duplicate exact editor titles refuse")
	first.free()
	second.free()
	var fallback := FallbackHost.new()
	fallback.panel = panel
	AnnotationHostRegistry.register("Fallback", fallback)
	check(registry._prepare_panel_call("probe", "echo", {"editor_name": "Fallback"}).ok,
		"annotation-host fallback preserves duck-typed ownership")
	var unowned := Control.new()
	fallback.panel = unowned
	check(not registry._prepare_panel_call("probe", "echo", {"editor_name": "Fallback"}).ok,
		"unknown ownership fails closed")
	AnnotationHostRegistry.deregister("Fallback", fallback)
	unowned.free()
	panel.free()
	check(not services.resolve("Probe", broker, [], true).ok, "freed panel refuses")
	print("PanelServices: %d failures" % failures)
	quit(1 if failures else 0)
