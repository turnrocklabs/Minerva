class_name SpreadsheetRecoveryDialog
extends ConfirmationDialog
## Failed GUI handoffs retain their request without creating an empty editor.
var operation: Callable
var provider: Callable
var manager: WeakRef
var pane: WeakRef
var context: MCPExecutionContext
var busy: bool = false
@onready var message: RichTextLabel = $Message

func _ready() -> void:
	add_button("Open Plugins", false, "plugins")
	context = MCPExecutionContext.create("spreadsheet_recovery")
	tree_exiting.connect(context.cancel)

func configure(reason: String, request: Callable, provider_resolver: Callable, plugin_manager: PluginManager, editor_pane: EditorPane) -> void:
	operation = request
	provider = provider_resolver
	manager = weakref(plugin_manager) if plugin_manager != null else null
	pane = weakref(editor_pane) if editor_pane != null else null
	_show_error(reason)

func _show_error(reason: String) -> void:
	message.text = reason + "\nStart/install %s in Plugins, then Retry. No document was opened or changed." % str(provider.call())
	push_error(message.text)

func _on_retry() -> void:
	if busy:
		return
	busy = true
	get_ok_button().disabled = true
	var plugins: PluginManager = manager.get_ref() if manager != null else null
	var database: PluginDB = plugins.get_db() if plugins != null else null
	var provider_id := str(provider.call())
	if database != null and database.get_by_id(provider_id) != null:
		await plugins.start_plugin(provider_id)
	if context.is_stopped():
		return
	var result: Dictionary = await operation.call(context)
	if context.is_stopped():
		return
	if result.get("ok", false):
		queue_free()
	else:
		var errors: Array = result.get("errors", [])
		_show_error(", ".join(PackedStringArray(errors)))
		busy = false
		get_ok_button().disabled = false

func _on_close() -> void:
	hide()
	context.cancel()
	queue_free()

func _on_custom_action(action: StringName) -> void:
	var editors: EditorPane = pane.get_ref() if pane != null else null
	if action == &"plugins" and editors != null:
		editors.add(Editor.Type.PLUGIN_MANAGER)
