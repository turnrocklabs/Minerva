class_name PluginEndpointDiscovery
extends RefCounted
## The profile-local Docket registration is the sole attach discovery source.
## It is read only: Docket owns its publication and stale-record cleanup.
const PROTOCOL_FLOOR := "2025-03-26"
const ATTACH_CHOICES := ["Update docket.app", "Quit docket.app and let Minerva start its own"]
var profile_directory: String = ""
var pid_alive: Callable = _pid_is_running

func discover() -> Dictionary:
	var directory := profile_directory if not profile_directory.is_empty() else OS.get_user_data_dir().get_base_dir().path_join("Docket")
	var path := directory.path_join("instance.json")
	if not FileAccess.file_exists(path):
		return {"note": "No Docket registration record; using Minerva's pinned backend"}
	var record = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not record is Dictionary or not _integer(record.get("pid"), 1, 4294967295):
		return _refusal(path, "invalid process ID")
	if not pid_alive.call(int(record.pid)):
		return {"note": "Docket registration is stale; using Minerva's pinned backend"}
	var endpoint = record.get("endpoint")
	if not endpoint is Dictionary or endpoint.get("host") != "127.0.0.1" \
			or not _integer(endpoint.get("port"), 1, 65535):
		return _refusal(path, "endpoint is not loopback", record)
	if not record.get("profile") is String or not record.profile.is_absolute_path() \
			or not record.get("version") is String or not record.get("started_at") is String:
		return _refusal(path, "incomplete registration", record)
	if not _same_profile(record.profile, directory):
		return _refusal(path, "profile directory mismatch", record)
	var protocol = record.get("protocol_version", "")
	var date := RegEx.new()
	date.compile("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
	if not protocol is String or date.search(protocol) == null or protocol < PROTOCOL_FLOOR:
		return _refusal(path, "requires MCP protocol %s or newer" % PROTOCOL_FLOOR, record)
	return {"attached": true, "record": record, "url": "http://127.0.0.1:%d" % int(endpoint.port)}

static func _integer(value: Variant, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and value == floor(float(value)) and value >= low and value <= high

static func _same_profile(a: String, b: String) -> bool:
	var left := a.replace("\\", "/").simplify_path().trim_suffix("/")
	var right := b.replace("\\", "/").simplify_path().trim_suffix("/")
	return left.nocasecmp_to(right) == 0 if OS.get_name() == "Windows" else left == right

static func _refusal(path: String, reason: String, record: Dictionary = {}) -> Dictionary:
	return {"error": "Docket registration record unreadable or mismatched at %s: %s" % [path, reason], "record": record}

static func _pid_is_running(pid: int) -> bool:
	return load("res://Scripts/Services/MCP/MCPServerRunner.gd")._is_process_running(pid)
