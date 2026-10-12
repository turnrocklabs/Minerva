class_name CodexClientVersion
extends RefCounted
## Resolve the catalog's client-version filter independently of model selection.

const FALLBACK := "0.160.0"
const CACHE_SECONDS := 24 * 60 * 60
const LATEST_URL := "https://registry.npmjs.org/@openai%2Fcodex/latest"

var cache_path: String
var latest_url: String


func _init(path: String = "user://codex_client_version.json", url: String = LATEST_URL) -> void:
	cache_path = path
	latest_url = url


static func stable_version(value: Variant) -> String:
	if not value is String:
		return ""
	var pattern := RegEx.new()
	pattern.compile("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")
	var found := pattern.search(value)
	return value if found != null and found.get_string() == value else ""


func resolve(tree: SceneTree, override: String = "", now: int = -1) -> Dictionary:
	if now < 0:
		now = int(Time.get_unix_time_from_system())
	if not override.strip_edges().is_empty():
		return {"version": override.strip_edges(), "source": "override"}
	var cache: Dictionary = {}
	if FileAccess.file_exists(cache_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(cache_path))
		if parsed is Dictionary:
			cache = parsed
	var cached := stable_version(cache.get("version"))
	var fetched: Variant = cache.get("fetched_at", 0)
	var fresh := (fetched is int or fetched is float) and float(fetched) <= now and now - float(fetched) < CACHE_SECONDS
	if not cached.is_empty() and fresh:
		return {"version": cached, "source": "cache"}
	var http := HTTPRequest.new()
	http.timeout = 5.0
	tree.root.add_child(http)
	var version := ""
	var err := http.request(latest_url)
	if err == OK:
		var result: Array = await http.request_completed
		if int(result[0]) == HTTPRequest.RESULT_SUCCESS and int(result[1]) == 200:
			var body: PackedByteArray = result[3]
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			if parsed is Dictionary and parsed.get("name") == "@openai/codex":
				version = stable_version(parsed.get("version"))
	http.queue_free()
	if not version.is_empty():
		var file := FileAccess.open(cache_path + ".tmp", FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({"version": version, "fetched_at": now}))
			file.close()
			var write_error := DirAccess.rename_absolute(cache_path + ".tmp", cache_path)
			if write_error != OK:
				push_warning("Codex version cache could not be saved: %s" % error_string(write_error))
		return {"version": version, "source": "registry"}
	return {"version": cached if not cached.is_empty() else FALLBACK,
		"source": "stale_cache" if not cached.is_empty() else "bundled_default"}
