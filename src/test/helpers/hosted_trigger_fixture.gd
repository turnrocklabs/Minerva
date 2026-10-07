extends RefCounted
## Reuses the trigger-feed suite's plugin connection; delivery still runs
## through the real broker, DocketHost and DocketTriggerFeed.
var _so: Node
var _previous := {}
var _wire
var _host
var _plugins
var _broker
var _sequence := 0

func install(so: Node) -> void:
	_so = so
	for key in ["docket_host", "plugin_manager", "plugin_event_broker"]:
		_previous[key] = so.get(key)
	var suite = load("res://test/test_docket_trigger_feed.gd")
	_wire = _make(suite.WIRE_SRC)
	_plugins = _make(suite.PLUGINS_SRC)
	_host = load("res://Scripts/Services/DocketHost/DocketHost.gd").new()
	_broker = load(suite.BROKER_PATH).new()
	_wire.plugin_id = "docket"
	_wire.event_broker = _broker
	_wire._subprocess = _make(suite.PIPE_SRC)
	_wire.protocol_profile = load(suite.PROFILE_PATH).legacy("2025-03-26", {}, _wire.process_generation())
	for name in ["master", "t10project", "t17project"]:
		_wire.listed.append({"name": name, "display_name": name, "path": "/harness-test/%s.dct" % name, "open_generation": "1"})
	_plugins.connection = _wire
	_host._plugin_manager = _plugins
	_host._connection = _wire
	_host._generation = _wire.process_generation()
	_host.projects = _wire.listed
	_host.master_path = _wire.listed[0].path
	_host.state = "ready"
	so.docket_host = _host
	so.plugin_manager = _plugins
	so.plugin_event_broker = _broker

func emit_created(project_name: String, id: String, feed: RefCounted) -> void:
	var project: Dictionary = _wire.listed.filter(func(p): return p.name == project_name)[0]
	_wire.items[project_name + "/" + id] = {"id": id, "type": "bug", "title": id, "status": "new"}
	_sequence += 1
	_broker.plugin_event.emit("docket", "item_changed", {"project": project.name, "project_path": project.path,
		"open_generation": project.open_generation, "id": id, "event": "created", "change": "created",
		"cause": "mutation", "origin": "", "operation_id": "", "stream": "harness-test", "sequence": _sequence,
		"baseline": {"kind": "created", "item_type": "bug"}})

	for frame in 300:
		if not feed._working and feed._queue.is_empty():
			return
		await Engine.get_main_loop().process_frame
	assert(false, "hosted trigger feed did not settle")

func restore() -> void:
	for key in _previous:
		_so.set(key, _previous[key])
	_wire._subprocess = null
	for node in [_plugins, _host]:
		node.free()
	_wire = null

func _make(source: String):
	var script := GDScript.new()
	script.source_code = source
	assert(script.reload() == OK)
	return script.new()
