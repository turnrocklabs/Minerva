class_name WorkerStatusPanel
extends VBoxContainer
## Live tree view of supervisor-worker relationships and status.
## Builds all UI programmatically — no .tscn required.

var _tree: Tree
var _root: TreeItem
var _worker_items: Dictionary = {}  # worker_id -> TreeItem
var _parent_items: Dictionary = {}  # parent_chat_id -> TreeItem

const _STATUS_COLORS := {
	"running":         Color(0.3, 0.7, 1.0),     # blue
	"completed":       Color(0.3, 0.8, 0.3),     # green
	"error":           Color(0.9, 0.3, 0.3),     # red
	"quota_exhausted": Color(0.9, 0.7, 0.2),     # orange
	"rate_limited":    Color(0.9, 0.9, 0.3),     # yellow
	"cancelled":       Color(0.5, 0.5, 0.5),     # grey
	"timeout":         Color(0.9, 0.5, 0.2),     # dark orange
}


func _ready() -> void:
	_tree = Tree.new()
	_tree.columns = 6
	_tree.set_column_title(0, "Name")
	_tree.set_column_title(1, "Status")
	_tree.set_column_title(2, "Provider")
	_tree.set_column_title(3, "Rounds")
	_tree.set_column_title(4, "Tokens")
	_tree.set_column_title(5, "Duration")
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_tree)

	_root = _tree.create_item()

	# Connect to WorkerRegistry signals
	var registry = SingletonObject.worker_registry
	if registry:
		registry.worker_spawned.connect(_on_worker_spawned)
		registry.worker_finished.connect(_on_worker_finished)

	# Connect double-click navigation
	_tree.item_activated.connect(_on_item_activated)

	# Populate with any workers that already exist
	_refresh_all()


## Rebuild the tree from scratch based on current registry state.
func _refresh_all() -> void:
	_tree.clear()
	_root = _tree.create_item()
	_worker_items.clear()
	_parent_items.clear()

	var registry = SingletonObject.worker_registry
	if not registry:
		return

	for info in registry.get_all_workers():
		_add_worker_to_tree(info)


## Add a single worker to the tree (creates supervisor group node if needed).
func _add_worker_to_tree(info) -> void:
	var parent_item := _get_or_create_parent_item(info.parent_chat_id)
	var item := _tree.create_item(parent_item)
	item.set_metadata(0, info.worker_id)
	_worker_items[info.worker_id] = item
	_update_worker_item(item, info)


## Get or create the supervisor group TreeItem for a given parent_chat_id.
func _get_or_create_parent_item(parent_chat_id: String) -> TreeItem:
	if _parent_items.has(parent_chat_id):
		return _parent_items[parent_chat_id]

	# Look up a friendly name from ChatList
	var display_name := parent_chat_id
	if SingletonObject.ChatList:
		for ch in SingletonObject.ChatList:
			if ch.HistoryId == parent_chat_id:
				if not ch.Title.is_empty():
					display_name = ch.Title
				break

	var group_item := _tree.create_item(_root)
	group_item.set_text(0, display_name)
	group_item.set_metadata(0, "")  # empty metadata marks this as a group row
	group_item.collapsed = false
	_parent_items[parent_chat_id] = group_item
	return group_item


## Update all visible columns for a worker TreeItem.
func _update_worker_item(item: TreeItem, info) -> void:
	# Col 0: Name
	item.set_text(0, info.worker_name)

	# Col 1: Status (with colour)
	item.set_text(1, info.status)
	var color: Color = _STATUS_COLORS.get(info.status, Color.WHITE)
	item.set_custom_color(1, color)

	# Col 2: Provider
	item.set_text(2, info.provider_name)

	# Col 3: Rounds
	if info.max_tool_rounds > 0:
		item.set_text(3, "%d/%d" % [info.rounds_used, info.max_tool_rounds])
	else:
		item.set_text(3, str(info.rounds_used))

	# Col 4: Tokens (comma-formatted for large numbers)
	item.set_text(4, _format_tokens(info.tokens_used))

	# Col 5: Duration
	item.set_text(5, _format_duration(info.spawned_at))


## Format a token count with commas for readability.
func _format_tokens(count: int) -> String:
	if count == 0:
		return "0"
	var s := str(count)
	var result := ""
	var offset := s.length() % 3
	for i in s.length():
		if i > 0 and (i - offset) % 3 == 0:
			result += ","
		result += s[i]
	return result


## Format elapsed time since spawned_at ISO string.
func _format_duration(spawned_at: String) -> String:
	if spawned_at.is_empty():
		return ""
	var dt := Time.get_datetime_dict_from_datetime_string(spawned_at, true)
	if dt.is_empty():
		return ""
	var elapsed := int(Time.get_unix_time_from_system() - Time.get_unix_time_from_datetime_dict(dt))
	if elapsed < 0:
		elapsed = 0
	if elapsed >= 3600:
		var hours := int(elapsed / 3600.0)
		var minutes := int((elapsed % 3600) / 60.0)
		return "%dh%dm" % [hours, minutes]
	elif elapsed >= 60:
		var minutes := int(elapsed / 60.0)
		return "%dm%ds" % [minutes, elapsed % 60]
	return "%ds" % elapsed


# ──────────────────────────────────────────────
# Signal handlers
# ──────────────────────────────────────────────

func _on_worker_spawned(worker_info) -> void:
	_add_worker_to_tree(worker_info)


func _on_worker_finished(worker_info) -> void:
	var item: TreeItem = _worker_items.get(worker_info.worker_id, null)
	if item:
		_update_worker_item(item, worker_info)


func _on_item_activated() -> void:
	var selected := _tree.get_selected()
	if not selected:
		return

	var worker_id: String = selected.get_metadata(0)
	if worker_id.is_empty():
		# This is a group/supervisor row — ignore or could expand/collapse
		return

	var registry = SingletonObject.worker_registry
	if not registry:
		return
	var info = registry.get_worker(worker_id)
	if not info:
		return

	# Switch to the worker's chat tab
	if not SingletonObject.ChatList or not SingletonObject.Chats:
		return
	for i in SingletonObject.ChatList.size():
		if SingletonObject.ChatList[i].HistoryId == info.worker_chat_id:
			SingletonObject.Chats.current_tab = i
			break
