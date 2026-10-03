extends SceneTree
## Off-tree contract fixture; GPU pixel truth is a separate HITL check.
var failures: int = 0

class ProbeEditor extends Control:
	var tab_title: String = "Duplicate"
	var plugin_scene_root: Control

class ServicesRoot extends Node:
	var plugin_scene_panel_broker: Object

class FallbackHost extends AnnotationHost:
	var panel: Control
	func get_panel() -> Control:
		return panel

func close_before_draw(node: Node) -> void:
	node.free()
	RenderingServer.frame_post_draw.emit()

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
	var hidden_parent := Control.new()
	root.add_child(hidden_parent)
	panel.reparent(hidden_parent)
	hidden_parent.hide()
	for slot in ["active", "detail"]:
		var hidden: Dictionary = services.capture_target(resolved, slot)
		check(not hidden.ok and hidden.error.contains("not visible") and panel.visible and not hidden_parent.visible,
			"hidden active/named panel refuses without selecting it")
	panel.reparent(root)
	hidden_parent.free()
	for close_surface in [false, true]:
		var doomed: Node = Control.new() if close_surface else SubViewport.new()
		root.add_child(doomed)
		var lifetime := {"ok": true, "viewport": root if close_surface else doomed,
			"surface": doomed if close_surface else null}
		close_before_draw.call_deferred(doomed)
		var closed_image: Image = await services.capture(lifetime)
		check(closed_image == null, "freed surface/viewport readback refuses")
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
	var replacement = load("res://test/fixtures/panel_probe/PanelProbe.gd").new()
	replacement.plugin_id = "other"
	root.add_child(replacement)
	first.tab_title = "Probe"
	first.plugin_scene_root = replacement
	second.free()
	var exact: Dictionary = services.resolve("Probe", broker, [second, first])
	check(exact.panel == replacement and not exact.broker_bound and exact.plugin_id == "other",
		"final exact panel owns resolution; dead editor is skipped in both loops")
	first.free()
	replacement.free()
	var fallback := FallbackHost.new()
	var singleton = root.get_node_or_null("SingletonObject")
	var created_singleton := singleton == null
	if created_singleton:
		singleton = ServicesRoot.new()
		singleton.name = "SingletonObject"
		root.add_child(singleton)
	var prior_broker = singleton.get("plugin_scene_panel_broker")
	singleton.set("plugin_scene_panel_broker", broker)
	AnnotationHostRegistry.register("Probe", fallback)
	check(services.resolve_cad_host("Probe") == panel.host,
		"explicit panel-host fallback precedes registry host with no live panel")
	AnnotationHostRegistry.deregister("Probe", fallback)
	singleton.set("plugin_scene_panel_broker", prior_broker)
	if created_singleton:
		singleton.free()
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
