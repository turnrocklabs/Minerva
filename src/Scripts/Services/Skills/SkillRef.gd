class_name SkillRef
extends RefCounted
## A qualified reference to one skill, as a string that fits wherever skill
## names are stored (Array[String] fields): "local:<id>" for a SkillManager
## skill, "docket:<project path>/<id>" for a Docket one. Both parts are
## percent-encoded, so a path or id holding ":" or "/" still round-trips.
## Any other string is a legacy name, resolved by id or title.

const LOCAL := "local"
const DOCKET := "docket"


static func local(id: String) -> String:
	return "%s:%s" % [LOCAL, id.uri_encode()]


static func docket(project_path: String, id: String) -> String:
	return "%s:%s/%s" % [DOCKET, project_path.uri_encode(), id.uri_encode()]


## Whether `ref` is written as a qualified reference (it may still be
## malformed: parse() then gives {}).
static func is_qualified(ref: String) -> bool:
	return ref.begins_with(LOCAL + ":") or ref.begins_with(DOCKET + ":")


## {origin: "local", id} or {origin: "docket", project_path, id} for a
## qualified reference; {} for a legacy name or a malformed reference.
static func parse(ref: String) -> Dictionary:
	if ref.begins_with(LOCAL + ":"):
		var id := ref.substr(LOCAL.length() + 1).uri_decode()
		return {} if id.is_empty() else {"origin": LOCAL, "id": id}
	if ref.begins_with(DOCKET + ":"):
		var parts := ref.substr(DOCKET.length() + 1).split("/")
		if parts.size() != 2 or parts[0].is_empty() or parts[1].is_empty():
			return {}
		return {"origin": DOCKET, "project_path": parts[0].uri_decode(), "id": parts[1].uri_decode()}
	return {}
