class_name MarketplaceBrowseDialog
extends Window
## Lists plugins available in the marketplace registry; one-click install.
##
## On open, fetches the registry from the canonical URL (overridable in
## settings later). User selects a plugin, clicks Install. The dialog
## delegates to MarketplaceClient.install_from_registry_entry which
## downloads, verifies SHA256SUMS, extracts, and registers.
##
## Emits `plugin_installed(plugin_id)` after a successful install so the
## parent PluginManagerPanel can refresh its installed-list.

const MARKETPLACE_CLIENT_GD := "res://Scripts/Services/Plugins/MarketplaceClient.gd"

signal plugin_installed(plugin_id: String)

var _client: Node = null
var _plugins: Array = []

var _list: ItemList = null
var _status: Label = null
var _install_btn: Button = null
var _refresh_btn: Button = null
var _details: RichTextLabel = null


func _ready() -> void:
	title = "Plugin Marketplace"
	min_size = Vector2(700, 480)
	close_requested.connect(_on_close_requested)
	_build_ui()
	_client = load(MARKETPLACE_CLIENT_GD).new()
	add_child(_client)
	await _refresh()


func _build_ui() -> void:
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_vbox.offset_left = 8
	root_vbox.offset_top = 8
	root_vbox.offset_right = -8
	root_vbox.offset_bottom = -8
	add_child(root_vbox)

	# Header bar: title + refresh
	var header := HBoxContainer.new()
	root_vbox.add_child(header)
	var heading := Label.new()
	heading.text = "Available plugins"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_refresh_btn = Button.new()
	_refresh_btn.text = "Refresh"
	_refresh_btn.pressed.connect(func(): await _refresh())
	header.add_child(_refresh_btn)

	# Split: plugin list (left) + details (right)
	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 280
	root_vbox.add_child(split)

	_list = ItemList.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_list_selected)
	split.add_child(_list)

	_details = RichTextLabel.new()
	_details.bbcode_enabled = true
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details.text = "Select a plugin to see details."
	split.add_child(_details)

	# Footer: status + install
	var footer := HBoxContainer.new()
	root_vbox.add_child(footer)
	_status = Label.new()
	_status.text = ""
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_status)

	_install_btn = Button.new()
	_install_btn.text = "Install"
	_install_btn.disabled = true
	_install_btn.pressed.connect(_on_install_pressed)
	footer.add_child(_install_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_on_close_requested)
	footer.add_child(close_btn)


func _refresh() -> void:
	_status.text = "Fetching registry…"
	_refresh_btn.disabled = true
	_install_btn.disabled = true
	_list.clear()
	_plugins = []
	_details.text = "Select a plugin to see details."

	var result: Dictionary = await _client.fetch_registry()
	_refresh_btn.disabled = false
	if not (result is Dictionary and result.get("ok") == true):
		var err: String = str(result.get("error", "unknown"))
		_status.text = "Failed to fetch registry: %s" % err
		push_warning("[MarketplaceBrowseDialog] fetch_registry failed: %s" % JSON.stringify(result))
		return

	var registry: Dictionary = result.registry
	_plugins = registry.get("plugins", [])
	if _plugins.is_empty():
		_status.text = "No plugins available in the registry"
		return

	var target: String = _client.resolve_platform_target()
	for entry in _plugins:
		var available_for_this_platform: bool = entry.get("downloads", {}).has(target)
		var label := "%s — v%s" % [entry.get("name", entry.get("id", "?")), entry.get("version", "?")]
		_list.add_item(label)
		if not available_for_this_platform:
			# Mark unavailable items so user knows why install is greyed.
			var idx := _list.item_count - 1
			_list.set_item_disabled(idx, true)
			_list.set_item_tooltip(idx, "No binary published for %s" % target)
	_status.text = "%d plugin(s) — your platform: %s" % [_plugins.size(), target]


func _on_list_selected(idx: int) -> void:
	if idx < 0 or idx >= _plugins.size():
		return
	var entry: Dictionary = _plugins[idx]
	var target: String = _client.resolve_platform_target()
	var downloads: Dictionary = entry.get("downloads", {})
	var installed: bool = _is_already_installed(entry.get("id", ""))

	_install_btn.disabled = installed or not downloads.has(target)
	_install_btn.text = "Already installed" if installed else "Install"

	# Compose detail panel.
	var lines := PackedStringArray()
	lines.append("[b]%s[/b]" % entry.get("name", "?"))
	lines.append("ID:  [code]%s[/code]" % entry.get("id", "?"))
	lines.append("Version:  %s" % entry.get("version", "?"))
	if entry.has("release_tag"):
		lines.append("Release tag:  [code]%s[/code]" % entry.release_tag)
	if not downloads.is_empty():
		lines.append("")
		lines.append("[b]Available for:[/b]")
		for t in downloads.keys():
			var mark := "  ✓" if t == target else "  ·"
			lines.append("%s %s" % [mark, t])
	_details.text = "\n".join(lines)


func _on_install_pressed() -> void:
	var sel: PackedInt32Array = _list.get_selected_items()
	if sel.is_empty():
		return
	var idx: int = sel[0]
	var entry: Dictionary = _plugins[idx]
	var plugin_id: String = entry.get("id", "")

	_install_btn.disabled = true
	_refresh_btn.disabled = true
	_status.text = "Installing %s…" % plugin_id

	var pm = SingletonObject.plugin_manager
	if pm == null:
		_status.text = "PluginManager unavailable"
		_install_btn.disabled = false
		_refresh_btn.disabled = false
		return

	# Delegate the registration step to PluginManager so capability auto-grant,
	# skill seeding, runtime setup, and directory creation all run — same code
	# path as side-load. Direct PluginDB.install would skip those.
	var result: Dictionary = await _client.install_from_registry_entry(entry, pm)
	_refresh_btn.disabled = false
	if result is Dictionary and result.get("ok") == true:
		_status.text = "Installed %s successfully" % plugin_id
		plugin_installed.emit(plugin_id)
		# Refresh the selection state so the Install button shows
		# "Already installed".
		_on_list_selected(idx)
	else:
		_install_btn.disabled = false
		var err: String = str(result.get("error", "unknown"))
		_status.text = "Install failed: %s" % err
		push_warning("[MarketplaceBrowseDialog] install_from_registry_entry failed: %s" % JSON.stringify(result))


func _is_already_installed(plugin_id: String) -> bool:
	if plugin_id.is_empty() or SingletonObject.plugin_manager == null:
		return false
	var db = SingletonObject.plugin_manager.get_db()
	return db != null and db.has_plugin(plugin_id)


func _on_close_requested() -> void:
	hide()
	queue_free()
