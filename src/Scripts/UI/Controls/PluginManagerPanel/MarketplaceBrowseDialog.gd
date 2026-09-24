class_name MarketplaceBrowseDialog
extends Window
## Lists the plugins in the marketplace registry, describes the selected
## one, and installs any selection through PluginManager's install queue.
## Scene: res://Scenes/MarketplaceBrowseDialog.tscn.
##
## The queue owns every install, so closing this dialog neither stops nor
## loses one. The Installs list shows one MarketplaceJobRow per job the
## queue still keeps — including installs started elsewhere (MCP) or before
## this dialog opened — so an install's progress and outcome survive
## selection changes and reopening.

const MARKETPLACE_CLIENT_GD := "res://Scripts/Services/Plugins/MarketplaceClient.gd"
const JOB_ROW_TSCN := preload("res://Scenes/MarketplaceJobRow.tscn")

## Set before the dialog enters the tree; defaults to the app's manager and
## the canonical registry.
var plugin_manager: Node = null
var registry_url := ""

var _client: Node = null
var _plugins: Array = []
var _rows := {}  # PluginInstallJob -> MarketplaceJobRow

@onready var _list: ItemList = %PluginList
@onready var _details: RichTextLabel = %Details
@onready var _status: Label = %Status
@onready var _install_btn: Button = %Install
@onready var _refresh_btn: Button = %Refresh


func _ready() -> void:
	if plugin_manager == null:
		plugin_manager = SingletonObject.plugin_manager
	close_requested.connect(_on_close_requested)
	%Close.pressed.connect(_on_close_requested)
	_refresh_btn.pressed.connect(_refresh)
	_install_btn.pressed.connect(_on_install_pressed)
	_list.multi_selected.connect(func(index: int, _selected: bool) -> void: _on_selection_changed(index))
	_client = load(MARKETPLACE_CLIENT_GD).new()
	add_child(_client)
	var queue = _queue()
	if queue != null:
		for job in queue.jobs():
			_add_row(job)
		queue.job_changed.connect(_on_job_changed)
	await _refresh()


func _refresh() -> void:
	_status.text = "Fetching registry…"
	_refresh_btn.disabled = true
	_install_btn.disabled = true
	_list.clear()
	_plugins = []
	_details.text = "Select a plugin to see details."

	var result: Dictionary = await _client.fetch_registry(registry_url)
	_refresh_btn.disabled = false
	if not result.get("ok", false):
		_status.text = "Failed to fetch registry: %s" % str(result.get("error", "unknown"))
		SingletonObject.ErrorDisplay("Marketplace unavailable", MarketplaceClient.format_install_error(result))
		return

	_plugins = result.registry.get("plugins", [])
	var target := MarketplaceClient.resolve_platform_target()
	for entry in _plugins:
		_list.add_item("%s — v%s" % [entry.get("name", entry.get("id", "?")), entry.get("version", "?")])
		if MarketplaceClient.download_target(entry.get("downloads", {})).is_empty():
			var idx := _list.item_count - 1
			_list.set_item_disabled(idx, true)
			_list.set_item_tooltip(idx, "No build published for %s" % target)
	_status.text = "No plugins available in the registry" if _plugins.is_empty() \
		else "%d plugin(s) — your platform: %s" % [_plugins.size(), target]


## Describe the entry at `index` and count what the selection would install.
func _on_selection_changed(index: int) -> void:
	if index >= 0 and index < _plugins.size():
		_details.text = _describe(_plugins[index])
	var installable := _installable_selection()
	_install_btn.disabled = installable.is_empty()
	_install_btn.text = "Install" if installable.size() <= 1 else "Install %d" % installable.size()


func _describe(entry: Dictionary) -> String:
	var target := MarketplaceClient.resolve_platform_target()
	var lines := PackedStringArray()
	lines.append("[b]%s[/b]  v%s" % [_plain(entry.get("name", "?")), _plain(entry.get("version", "?"))])
	lines.append("ID:  [code]%s[/code]" % _plain(entry.get("id", "?")))
	var installed := _installed_version(str(entry.get("id", "")))
	if not installed.is_empty():
		lines.append("Installed:  v%s" % installed)
	lines.append("")
	var description := str(entry.get("description", ""))
	lines.append(_plain(description) if not description.is_empty()
		else "[i]This release was published without a description.[/i]")
	lines.append("")
	lines.append("[b]Available for:[/b]")
	for t in entry.get("downloads", {}).keys():
		var here: bool = t == MarketplaceClient.download_target(entry.get("downloads", {}))
		lines.append("  %s %s%s" % ["✓" if here else "·", _plain(t), "  (this computer)" if here else ""])
	if MarketplaceClient.download_target(entry.get("downloads", {})).is_empty():
		lines.append("[i]No build for this computer (%s).[/i]" % target)
	return "\n".join(lines)


## Selected entries with a build for this computer, not already installed at
## that version, and not already being installed.
func _installable_selection() -> Array:
	var queue = _queue()
	var picked := []
	for idx in _list.get_selected_items():
		var entry: Dictionary = _plugins[idx]
		var id := str(entry.get("id", ""))
		var job = queue.job_for(id) if queue != null else null
		if not MarketplaceClient.download_target(entry.get("downloads", {})).is_empty() \
				and _installed_version(id) != str(entry.get("version", "")) \
				and (job == null or job.state == job.State.DONE):
			picked.append(entry)
	return picked


func _on_install_pressed() -> void:
	var queue = _queue()
	if queue == null:
		_status.text = "Plugin manager unavailable"
		return
	for entry in _installable_selection():
		queue.request(entry)
	_on_selection_changed(-1)


## Keep the rows to the jobs the queue still keeps (a trimmed job can no
## longer be retried), and the Install button to what can be installed now.
func _on_job_changed(job) -> void:
	_add_row(job)
	var kept: Array = _queue().jobs()
	for shown in _rows.keys():
		if not shown in kept:
			_rows[shown].queue_free()
			_rows.erase(shown)
		elif shown != job:
			_rows[shown].refresh()
	_on_selection_changed(-1)


func _add_row(job) -> void:
	if _rows.has(job):
		return
	var row = JOB_ROW_TSCN.instantiate()
	row.bind(job, _queue())
	_rows[job] = row
	%JobRows.add_child(row)
	%JobRows.move_child(row, 0)  # newest first


## Registry text shown as text, not as BBCode markup.
static func _plain(value) -> String:
	return str(value).replace("[", "[lb]")


func _installed_version(plugin_id: String) -> String:
	if plugin_manager == null or plugin_id.is_empty():
		return ""
	var def = plugin_manager.get_db().get_by_id(plugin_id)
	return str(def.version) if def != null else ""


func _queue():
	return plugin_manager.install_queue if plugin_manager != null else null


func _on_close_requested() -> void:
	hide()
	queue_free()
