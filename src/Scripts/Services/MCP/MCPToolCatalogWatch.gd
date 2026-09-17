class_name MCPToolCatalogWatch
extends RefCounted
## Transport-neutral ownership and protocol state for one modern tools catalog
## subscription. Transport adapters own bytes and reconnection; this object
## admits only correlated, acknowledged notifications for the live generation.

const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")

signal refresh_requested(generation: int)
signal acknowledged(generation: int)
signal stopped(generation: int, retry: bool)

const ACK_DEADLINE_MS := 10 * 1000
const MAX_RETRY_ATTEMPTS := 5
const RETRY_BASE_MS := 250
const RETRY_MAX_MS := 4000
const COALESCE_MS := 100

var generation := 0
var attempt := 0
var request_id: Variant = null
var waiting_ack := false
var active := false
var ack_deadline_ms := 0
var _dirty := false
var _coalesce_token := 0


func begin(owner_generation: int, typed_request_id: Variant) -> void:
	generation = owner_generation
	attempt += 1
	request_id = typed_request_id
	waiting_ack = true
	active = false
	_dirty = false
	ack_deadline_ms = Time.get_ticks_msec() + ACK_DEADLINE_MS


func reset(owner_generation: int) -> void:
	generation = owner_generation
	attempt = 0
	request_id = null
	waiting_ack = false
	active = false
	_dirty = false
	ack_deadline_ms = 0


func accepts(message: Dictionary, owner_generation: int) -> bool:
	if owner_generation != generation:
		return false
	var method: Variant = message.get("method")
	if method is String:
		if message.has("id"):
			return false
		var params: Variant = message.get("params")
		if not params is Dictionary:
			return false
		var metadata: Variant = params.get("_meta")
		if not metadata is Dictionary:
			return false
		var subscription_id: Variant = metadata.get(
			"io.modelcontextprotocol/subscriptionId")
		if Protocol.request_id_key(subscription_id) != Protocol.request_id_key(request_id):
			return false
		if method == "notifications/subscriptions/acknowledged" and waiting_ack:
			var accepted: Variant = params.get("notifications")
			if not accepted is Dictionary or accepted.size() != 1 \
					or accepted.get("toolsListChanged") != true:
				stop(false)
				return true
			waiting_ack = false
			active = true
			acknowledged.emit(generation)
			request_refresh(true)
			return true
		if method == "notifications/tools/list_changed":
			if active:
				request_refresh()
			return true
		return false
	if message.has("id") and Protocol.request_id_key(message.id) \
			== Protocol.request_id_key(request_id):
		stop(is_valid_completion(message, request_id))
		return true
	return false


static func is_valid_completion(message: Dictionary,
		expected_request_id: Variant) -> bool:
	if Protocol.request_id_key(message.get("id")) \
			!= Protocol.request_id_key(expected_request_id):
		return false
	var result: Variant = message.get("result")
	if not result is Dictionary or result.get("resultType") != "complete":
		return false
	var metadata: Variant = result.get("_meta")
	return metadata is Dictionary and Protocol.request_id_key(metadata.get(
		"io.modelcontextprotocol/subscriptionId")) \
		== Protocol.request_id_key(expected_request_id)


func request_refresh(immediate: bool = false) -> void:
	if not active:
		return
	if _dirty:
		return
	_dirty = true
	if immediate:
		refresh_requested.emit(generation)
		return
	_coalesce_token += 1
	_emit_coalesced(_coalesce_token, generation)


func _emit_coalesced(token: int, owner: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	await tree.create_timer(float(COALESCE_MS) / 1000.0).timeout
	if token == _coalesce_token and owner == generation and active and _dirty:
		refresh_requested.emit(owner)


func take_dirty(owner_generation: int) -> bool:
	if owner_generation != generation or not _dirty:
		return false
	_dirty = false
	return true


func ack_expired(now_ms: int = -1) -> bool:
	var now := Time.get_ticks_msec() if now_ms < 0 else now_ms
	return waiting_ack and now >= ack_deadline_ms


func retry_delay_ms() -> int:
	if attempt >= MAX_RETRY_ATTEMPTS:
		return -1
	return mini(RETRY_BASE_MS * (1 << maxi(0, attempt - 1)), RETRY_MAX_MS)


func stop(retry: bool) -> void:
	var was_live := waiting_ack or active
	waiting_ack = false
	active = false
	_dirty = false
	_coalesce_token += 1
	if was_live:
		stopped.emit(generation, retry)
