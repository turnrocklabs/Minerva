class_name AnnotationResolveCache
extends RefCounted
## Per-host cache for v2 anchor resolution.

const MAX_ENTRIES := 5000

var _cache: Dictionary = {}
var _host_revision: int = 0
var _access_counter: int = 0
var _hits: int = 0
var _misses: int = 0
var _evictions: int = 0


func resolve(anchor: Dictionary, host: Object, view_context: String) -> Dictionary:
	var key := _anchor_key(anchor, view_context)
	var entry: Variant = _cache.get(key, null)
	if entry is Dictionary and entry.get("revision", -1) == _host_revision:
		_hits += 1
		_access_counter += 1
		entry["last_access"] = _access_counter
		return (entry["resolved"] as Dictionary).duplicate(true)

	_misses += 1
	var resolved := _call_host_resolve(anchor, host)
	_access_counter += 1
	_cache[key] = {
		"anchor_type": str(anchor.get("type", "")),
		"resolved": resolved.duplicate(true),
		"revision": _host_revision,
		"last_access": _access_counter,
	}
	_evict_if_needed()
	return resolved


func invalidate(anchor_type: String = "") -> void:
	if anchor_type.is_empty():
		_cache.clear()
		return

	var to_remove: Array = []
	for key in _cache.keys():
		var entry: Variant = _cache[key]
		if entry is Dictionary and str(entry.get("anchor_type", "")) == anchor_type:
			to_remove.append(key)
	for key in to_remove:
		_cache.erase(key)


func bump_revision() -> void:
	_host_revision += 1


func revision() -> int:
	return _host_revision


func stats() -> Dictionary:
	return {
		"hits": _hits,
		"misses": _misses,
		"evictions": _evictions,
		"size": _cache.size(),
		"revision": _host_revision,
	}


func _anchor_key(anchor: Dictionary, view_context: String) -> String:
	return "%s/%s:%s/%s" % [
		str(anchor.get("plugin", "")),
		str(anchor.get("type", "")),
		_encode_id(anchor.get("id", null)),
		view_context,
	]


func _call_host_resolve(anchor: Dictionary, host: Object) -> Dictionary:
	if host != null and host.has_method("resolve_anchor"):
		var value: Variant = host.call("resolve_anchor", anchor)
		return _normalise_resolve_result(value, anchor)
	var pos := _snapshot_position_2d(anchor.get("snapshot", {}))
	return {"position": pos, "bounds": Rect2(pos, Vector2.ZERO), "stale": true, "view_metadata": {}}


func _normalise_resolve_result(value: Variant, anchor: Dictionary) -> Dictionary:
	if not value is Dictionary:
		var fallback_pos := _snapshot_position_2d(anchor.get("snapshot", {}))
		return {"position": fallback_pos, "bounds": Rect2(fallback_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	var result: Dictionary = (value as Dictionary).duplicate(true)
	var pos: Variant = result.get("position", _snapshot_position_2d(anchor.get("snapshot", {})))
	if not pos is Vector2:
		pos = _to_vec2(pos)
	result["position"] = pos

	var bounds: Variant = result.get("bounds", Rect2(pos, Vector2.ZERO))
	if not bounds is Rect2:
		bounds = Rect2(pos, Vector2.ZERO)
	result["bounds"] = bounds
	result["stale"] = bool(result.get("stale", false))

	var meta: Variant = result.get("view_metadata", {})
	result["view_metadata"] = meta if meta is Dictionary else {}
	return result


func _evict_if_needed() -> void:
	while _cache.size() > MAX_ENTRIES:
		var oldest_key: Variant = null
		var oldest_access := INF
		for key in _cache.keys():
			var entry: Variant = _cache[key]
			var access := INF
			if entry is Dictionary:
				access = float(entry.get("last_access", INF))
			if access < oldest_access:
				oldest_access = access
				oldest_key = key
		if oldest_key == null:
			break
		_cache.erase(oldest_key)
		_evictions += 1


func _encode_id(id_value: Variant) -> String:
	if id_value is Dictionary or id_value is Array:
		return JSON.stringify(id_value)
	return str(id_value)


func _snapshot_position_2d(snapshot: Variant) -> Vector2:
	if not snapshot is Dictionary:
		return Vector2.ZERO
	return _to_vec2((snapshot as Dictionary).get("position", Vector2.ZERO))


func _to_vec2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector3:
		return Vector2(value.x, value.y)
	if value is Array and (value as Array).size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO
