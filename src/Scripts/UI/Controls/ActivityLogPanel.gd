class_name ActivityLogPanel
extends VBoxContainer
## Panel for displaying MCP tool call activity log.
## Builds UI programmatically (no .tscn needed).

var _scroll: ScrollContainer
var _entries_container: VBoxContainer
var _auto_scroll: bool = true
var agent_id: String = ""  # set by the routing system

func _ready() -> void:
	_build_ui()

func _build_ui() -> void:
	# Scroll container fills the panel
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	_scroll.follow_focus = true
	add_child(_scroll)

	_entries_container = VBoxContainer.new()
	_entries_container.size_flags_horizontal = SIZE_EXPAND_FILL
	_scroll.add_child(_entries_container)

func add_entry(tool_name: String, arguments: Dictionary, result: Dictionary) -> void:
	## Add a tool call entry to the log.
	var entry := ActivityLogEntry.new(tool_name, arguments, result)
	_entries_container.add_child(entry)

	# Auto-scroll to bottom
	if _auto_scroll:
		await get_tree().process_frame
		_scroll.scroll_vertical = _scroll.get_v_scroll_bar().max_value

func get_entry_count() -> int:
	return _entries_container.get_child_count()
