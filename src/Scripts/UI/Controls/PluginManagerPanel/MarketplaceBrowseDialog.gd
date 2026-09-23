class_name MarketplaceBrowseDialog
extends Window
## Lists plugins available in the marketplace registry; one-click install.
##
## On open, fetches the registry from the canonical URL (overridable in
## settings later). User selects a plugin, clicks Install. The dialog hands
## the entry to PluginManager's install queue and listens to the job, so
## closing the dialog neither stops nor loses the install.
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

	# Split: plugin list (left) + details (right).
	# HSplitContainer's `split_offset` is measured from the centre, NOT the
	# left edge — a positive value moves the divider toward the right child
	# (giving the LEFT pane more space). Negative shifts left → more space
	# for the right (details) pane. We want details > list.
	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = -120
	root_vbox.add_child(split)

	_list = ItemList.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(200, 0)
	_list.item_selected.connect(_on_list_selected)
	split.add_child(_list)

	_details = RichTextLabel.new()
	_details.bbcode_enabled = true
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details.custom_minimum_size = Vector2(320, 0)
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
		var pretty: String = MarketplaceClient.format_install_error(result)
		SingletonObject.ErrorDisplay("Marketplace unavailable", pretty)
		return

	var registry: Dictionary = result.registry
	_plugins = registry.get("plugins", [])
	if _plugins.is_empty():
		_status.text = "No plugins available in the registry"
		return

	var target: String = MarketplaceClient.resolve_platform_target()
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
	var target: String = MarketplaceClient.resolve_platform_target()
	var downloads: Dictionary = entry.get("downloads", {})
	var installed: bool = _is_already_installed(entry.get("id", ""))
	var job = _unfinished_job(entry.get("id", ""))

	_install_btn.disabled = installed or job != null or not downloads.has(target)
	_install_btn.text = "Installing…" if job != null else ("Already installed" if installed else "Install")

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

	# The queue registers through PluginManager so capability auto-grant,
	# skill seeding, runtime setup, and directory creation all run — same code
	# path as side-load. Direct PluginDB.install would skip those.
	var job = pm.install_queue.request(entry)
	job.finished.connect(_on_install_finished.bind(job, idx))


func _on_install_finished(job, idx: int) -> void:
	_refresh_btn.disabled = false
	var plugin_id: String = job.plugin_id()
	if job.outcome == job.OUTCOME_CANCELLED:
		_install_btn.disabled = false
		_status.text = "Install of %s cancelled" % plugin_id
	elif job.outcome == job.OUTCOME_START_FAILED:
		_status.text = "Installed %s %s, but it failed to start: %s" % [
			plugin_id, str(job.result.get("version", "")), job.message]
		plugin_installed.emit(plugin_id)
		_on_list_selected(idx)
	elif job.result.get("ok") == true:
		_status.text = "Installed %s %s" % [plugin_id, str(job.result.get("version", ""))]
		SingletonObject.create_toast_notification(
			"Installed plugin: %s" % plugin_id,
			ToastNotification.Type.INFO
		)
		plugin_installed.emit(plugin_id)
		# Refresh the selection state so the Install button shows
		# "Already installed".
		_on_list_selected(idx)
	else:
		_install_btn.disabled = false
		_status.text = "Install failed: %s" % str(job.result.get("error", "unknown"))
		SingletonObject.ErrorDisplay("Plugin install failed: %s" % plugin_id, job.message)


## The queue's unfinished install of `plugin_id`, or null.
func _unfinished_job(plugin_id: String):
	var pm = SingletonObject.plugin_manager
	if plugin_id.is_empty() or pm == null or pm.install_queue == null:
		return null
	var job = pm.install_queue.job_for(plugin_id)
	return job if job != null and job.state != job.State.DONE else null


func _is_already_installed(plugin_id: String) -> bool:
	if plugin_id.is_empty() or SingletonObject.plugin_manager == null:
		return false
	var db = SingletonObject.plugin_manager.get_db()
	return db != null and db.has_plugin(plugin_id)


func _on_close_requested() -> void:
	hide()
	queue_free()
