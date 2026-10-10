class_name PluginEndpointDiscovery
extends RefCounted
## The profile-local Docket registration is the sole attach discovery source.
## It is read only: Docket owns its publication and stale-record cleanup.
var profile_directory: String = ""
var pid_alive: Callable = MCPServerRunner._is_process_running

func discover() -> Dictionary:
	var directory := profile_directory if not profile_directory.is_empty() else OS.get_user_data_dir().get_base_dir().path_join("Docket")
	var path := directory.path_join("instance.json")
	if not FileAccess.file_exists(path):
		return {"note": "No Docket registration record; using Minerva's pinned backend"}
	var record = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not record is Dictionary or not _integer(record.get("pid"), 1, 4294967295):
		return {"error": "Docket registration has no valid process ID"}
	if not pid_alive.call(int(record.pid)):
		return {"note": "Docket registration is stale; using Minerva's pinned backend"}
	var endpoint = record.get("endpoint")
	if not endpoint is Dictionary or endpoint.get("host") != "127.0.0.1" \
			or not _integer(endpoint.get("port"), 1, 65535):
		return {"error": "Docket registration must name a loopback endpoint"}
	if not record.get("profile") is String or not record.profile.is_absolute_path() \
			or not record.get("version") is String or not record.get("started_at") is String:
		return {"error": "Docket registration is incomplete"}
	return {"attached": true, "record": record, "url": "http://127.0.0.1:%d" % int(endpoint.port)}

static func _integer(value: Variant, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and value == floor(float(value)) and value >= low and value <= high
