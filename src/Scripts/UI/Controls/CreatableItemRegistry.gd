class_name CreatableItemRegistry
extends RefCounted

## Registry of creatable editor/viewer items for the "New → Item" flow.
## Built-in editor types register at startup. Plugins register/unregister
## items on start/stop. UI elements (menus, toolbars) read from this registry.


## Emitted whenever items are added or removed, so UI can rebuild.
signal items_changed


class CreatableItem:
	## Unique key, e.g. "text", "graphics", "pcb", "email_inbox"
	var id: String
	## Shown in menu, e.g. "Text Editor", "Graphics Editor"
	var display_name: String
	## Nullable, for menu/toolbar display
	var icon: Texture2D
	## "builtin" or "plugin"
	var category: String
	## Empty for built-ins, plugin id for plugin items
	var source_plugin_id: String
	## Called with no args to create the item
	var create_callback: Callable
	## For stable menu ordering (built-ins 0-99, plugins 100+)
	var sort_order: int

	static func create(
		p_id: String,
		p_display_name: String,
		p_create_callback: Callable,
		p_icon: Texture2D = null,
		p_sort_order: int = 50,
		p_category: String = "builtin",
		p_source_plugin_id: String = ""
	) -> CreatableItem:
		var item := CreatableItem.new()
		item.id = p_id
		item.display_name = p_display_name
		item.create_callback = p_create_callback
		item.icon = p_icon
		item.sort_order = p_sort_order
		item.category = p_category
		item.source_plugin_id = p_source_plugin_id
		return item


## Internal storage keyed by item id.
var _items: Dictionary = {}


## Adds an item to the registry. Warns and overwrites if the id already exists.
func register_item(item: CreatableItem) -> void:
	if _items.has(item.id):
		push_warning("CreatableItemRegistry: overwriting existing item '%s'" % item.id)
	_items[item.id] = item
	items_changed.emit()


## Removes an item by id. No-op if the id doesn't exist.
func unregister_item(id: String) -> void:
	if _items.erase(id):
		items_changed.emit()


## Removes all items registered by a given plugin, emitting items_changed once.
func unregister_by_source(plugin_id: String) -> void:
	var ids_to_remove: Array[String] = []
	for id: String in _items:
		var item: CreatableItem = _items[id]
		if item.source_plugin_id == plugin_id:
			ids_to_remove.append(id)
	if ids_to_remove.is_empty():
		return
	for id: String in ids_to_remove:
		_items.erase(id)
	items_changed.emit()


## Returns all items sorted by sort_order.
func get_all_items() -> Array[CreatableItem]:
	var result: Array[CreatableItem] = []
	for id: String in _items:
		result.append(_items[id])
	result.sort_custom(func(a: CreatableItem, b: CreatableItem) -> bool:
		return a.sort_order < b.sort_order
	)
	return result


## Returns item by id, or null if not found.
func get_item(id: String) -> CreatableItem:
	return _items.get(id, null)


## Returns the number of registered items.
func get_item_count() -> int:
	return _items.size()
