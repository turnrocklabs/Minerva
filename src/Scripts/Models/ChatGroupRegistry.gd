class_name ChatGroupRegistry
extends RefCounted
## Registry of chat groups for the chats pane (DCR 01a017494904).
##
## A group is an **id plus a display name**, never a bare string. Chats store
## only the id (`ServiceHistory.ChatGroupId`), so a rename is ONE write here
## instead of an N-chat migration that can half-fail.
##
## Lifecycle: explicit creation (the dock's "+" card), implicit destruction
## (`prune_empty` drops a group once its last chat leaves).
##
## The registry is per-project state: it serialises into the `.minproj` under
## "ChatGroups" and is cleared/reloaded alongside `SingletonObject.ChatList`.

## Sentinel ids used by the dock's *view* selector. These are NOT storable on a
## chat — `ServiceHistory.ChatGroupId` only ever holds a real group id or "".
const VIEW_ALL := "__all__"
const VIEW_UNGROUPED := "__ungrouped__"
const VIEW_DELETED := "__deleted__"

## The id a chat carries when it belongs to no group.
const UNGROUPED := ""

const DEFAULT_GROUP_NAME := "Untitled group"

## Card bar colours, cycled by creation order. First four match the Option C
## prototype (Docs/prototypes/option-c-top-dock.html).
const GROUP_COLORS: Array[Color] = [
	Color("#2f7fd8"),
	Color("#d9922b"),
	Color("#2fa85a"),
	Color("#8a6bd1"),
	Color("#d85f5f"),
	Color("#2fb0a8"),
	Color("#c25fb0"),
	Color("#8a9a2f"),
]

## Colour used for the Ungrouped and All pseudo-cards.
const NEUTRAL_COLOR := Color("#5f7f8a")

signal groups_changed()

## Ordered list of {id: String, name: String, color_index: int}. Order is
## creation order and is what the dock renders left-to-right.
var _groups: Array[Dictionary] = []

## Monotonic counter feeding minted ids. Serialised so ids stay unique across
## save/load even after groups are pruned.
var _next_ordinal: int = 1


## Create a group and return its id. `name` is deduplicated against existing
## group names ("Untitled group" -> "Untitled group 2" -> ...), so the "+" card
## can always create without prompting first.
func create_group(name: String = DEFAULT_GROUP_NAME, forced_id: String = "") -> String:
	var final_name := _unique_name(name if not name.strip_edges().is_empty() else DEFAULT_GROUP_NAME)
	var id := forced_id
	if id.is_empty() or has_group(id) or _is_view_sentinel(id):
		id = _mint_id()
	_groups.append({
		"id": id,
		"name": final_name,
		"color_index": (_groups.size()) % GROUP_COLORS.size(),
		# A group only becomes prunable once a chat has actually joined it.
		# Without this, creating an empty group and then dragging chats in is
		# impossible: the very next prune sweep would delete it first.
		"populated": false,
	})
	groups_changed.emit()
	return id


func rename_group(id: String, name: String) -> bool:
	var trimmed := name.strip_edges()
	if trimmed.is_empty():
		return false
	for g in _groups:
		if g["id"] == id:
			if g["name"] == trimmed:
				return true
			g["name"] = _unique_name(trimmed, id)
			groups_changed.emit()
			return true
	return false


func remove_group(id: String) -> bool:
	for i in range(_groups.size()):
		if _groups[i]["id"] == id:
			_groups.remove_at(i)
			groups_changed.emit()
			return true
	return false


## Record that a chat has joined this group, arming it for implicit destruction.
## Until this is called the group is brand new and empty on purpose, and prune
## sweeps leave it alone.
func mark_populated(id: String) -> bool:
	for g in _groups:
		if g["id"] == id:
			if bool(g.get("populated", false)):
				return true
			g["populated"] = true
			return true
	return false


func is_populated(id: String) -> bool:
	for g in _groups:
		if g["id"] == id:
			return bool(g.get("populated", false))
	return false


func has_group(id: String) -> bool:
	for g in _groups:
		if g["id"] == id:
			return true
	return false


## Display name for a group id. Returns "" for an unknown id — callers treat
## that as ungrouped rather than rendering a dangling label.
func get_name(id: String) -> String:
	for g in _groups:
		if g["id"] == id:
			return str(g["name"])
	return ""


## First group whose display name matches (case-insensitively), or "" —
## the lookup MCP verbs and the rename dedupe both need it.
func find_by_name(name: String) -> String:
	var needle := name.strip_edges().to_lower()
	for g in _groups:
		if str(g["name"]).to_lower() == needle:
			return str(g["id"])
	return ""


func color_for(id: String) -> Color:
	for g in _groups:
		if g["id"] == id:
			return GROUP_COLORS[int(g["color_index"]) % GROUP_COLORS.size()]
	return NEUTRAL_COLOR


## Copy of the ordered group list. Callers must not mutate the registry
## through the returned dictionaries.
func list_groups() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for g in _groups:
		out.append({
			"id": str(g["id"]),
			"name": str(g["name"]),
			"color": color_for(str(g["id"])),
			"populated": bool(g.get("populated", false)),
		})
	return out


func size() -> int:
	return _groups.size()


func clear() -> void:
	_groups.clear()
	_next_ordinal = 1
	groups_changed.emit()


## Drop every group not present in `used_ids`. Returns the ids removed.
##
## This is the "implicit destruction" half of the lifecycle: the caller passes
## the set of group ids still referenced by LIVE (non-deleted) chats, so a group
## disappears the moment its last chat leaves it. Deleted chats park their group
## in `PreDeleteGroupId` and therefore do NOT keep a group alive — restoring a
## chat whose group has since been pruned returns it to Ungrouped.
func prune_empty(used_ids: Array) -> Array[String]:
	var removed: Array[String] = []
	var keep: Array[Dictionary] = []
	for g in _groups:
		# A never-populated group is one the user just created and has not filled
		# yet — dropping it here would make "create a group, then drag chats in"
		# impossible. Those are removed explicitly (delete_group) instead.
		if used_ids.has(str(g["id"])) or not bool(g.get("populated", false)):
			keep.append(g)
		else:
			removed.append(str(g["id"]))
	if removed.is_empty():
		return removed
	_groups = keep
	groups_changed.emit()
	return removed


func serialize() -> Dictionary:
	var items: Array[Dictionary] = []
	for g in _groups:
		items.append({
			"id": str(g["id"]),
			"name": str(g["name"]),
			"color_index": int(g["color_index"]),
			"populated": bool(g.get("populated", false)),
		})
	return {"version": 1, "next_ordinal": _next_ordinal, "groups": items}


## Restore from `.minproj` data. Tolerates the field being absent (projects
## saved before this DCR) and any per-entry shape drift; a malformed entry is
## skipped rather than aborting the load.
func deserialize(data: Variant) -> void:
	_groups.clear()
	_next_ordinal = 1
	if not (data is Dictionary):
		groups_changed.emit()
		return
	var dict: Dictionary = data
	# GDScript's JSON parser returns every number as a float; int() the ordinal
	# rather than trusting the stored type.
	_next_ordinal = max(1, int(dict.get("next_ordinal", 1)))
	for raw in dict.get("groups", []):
		if not (raw is Dictionary):
			continue
		var entry: Dictionary = raw
		var id := str(entry.get("id", ""))
		if id.is_empty() or _is_view_sentinel(id) or has_group(id):
			continue
		var name := str(entry.get("name", DEFAULT_GROUP_NAME))
		if name.strip_edges().is_empty():
			name = DEFAULT_GROUP_NAME
		_groups.append({
			"id": id,
			"name": name,
			"color_index": int(entry.get("color_index", _groups.size())) % GROUP_COLORS.size(),
			# Projects saved before this field existed predate empty groups, so
			# every restored group was populated by definition.
			"populated": bool(entry.get("populated", true)),
		})
	groups_changed.emit()


## The whole visibility decision, as a pure function of the three axes.
##
## Deliberately static and dependency-free so the group x archived x deleted
## matrix can be tested without booting SingletonObject or a TabContainer — and
## so there is exactly ONE place the axes are combined. Two separate passes over
## the tab strip would let whichever ran last win, which is the defect this
## function exists to make impossible.
##
## `effective_group_id` must already be resolved: "" for ungrouped, including
## the case where the chat names a group that no longer exists.
static func should_show(
	active_view: String,
	effective_group_id: String,
	archived: bool,
	deleted: bool,
	showing_archived: bool
) -> bool:
	# The Deleted view shows deleted chats and nothing else. It ignores the
	# archived axis on purpose: a chat that is both archived and deleted must
	# still be reachable somewhere, and this is that somewhere.
	if active_view == VIEW_DELETED:
		return deleted
	if deleted:
		return false
	if archived and not showing_archived:
		return false
	if active_view == VIEW_ALL:
		return true
	if active_view == VIEW_UNGROUPED:
		return effective_group_id == UNGROUPED
	return effective_group_id == active_view


static func is_view_sentinel(id: String) -> bool:
	return id == VIEW_ALL or id == VIEW_UNGROUPED or id == VIEW_DELETED


func _is_view_sentinel(id: String) -> bool:
	return ChatGroupRegistry.is_view_sentinel(id)


func _mint_id() -> String:
	var id := "grp_%d" % _next_ordinal
	_next_ordinal += 1
	while has_group(id):
		id = "grp_%d" % _next_ordinal
		_next_ordinal += 1
	return id


## Append " 2", " 3", ... until the name is unique. `skip_id` lets a rename keep
## its own current name without colliding with itself.
func _unique_name(name: String, skip_id: String = "") -> String:
	var base := name.strip_edges()
	var candidate := base
	var n := 1
	while true:
		var clash := false
		for g in _groups:
			if str(g["id"]) == skip_id:
				continue
			if str(g["name"]).to_lower() == candidate.to_lower():
				clash = true
				break
		if not clash:
			return candidate
		n += 1
		candidate = "%s %d" % [base, n]
	return candidate
