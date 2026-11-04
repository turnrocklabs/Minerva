class_name T3SessionLaunchForm
extends VBoxContainer
## Capability-driven fields for the terminal passthrough dialog's T3 kind.
## The plugin owns session choices and registration; this view only presents them.

const ENTRY_KEY := "plugin:t3_code:t3-code"
const STATUS_TOOL := "minerva_t3_code_status"
const LAUNCH_TOOL := "minerva_t3_code_launch"

@onready var _workspace: LineEdit = %Workspace
@onready var _models: OptionButton = %Model
@onready var _efforts: OptionButton = %Effort
@onready var _notice: Label = %Notice
@onready var _result: TextEdit = %Result

var _call_tool: Callable
var _project_path: Callable
var _options: Dictionary = {}
var _choices: Array[Dictionary] = []
var _loaded_project: String = ""
var _loading: bool = false


func configure(tool_caller: Callable, project_reader: Callable) -> void:
	_call_tool = tool_caller
	_project_path = project_reader


func refresh() -> void:
	if _loading:
		return
	_result.hide()
	_options = {}
	_choices.clear()
	_models.clear()
	_efforts.clear()
	_loaded_project = str(_project_path.call())
	_workspace.text = _loaded_project.get_base_dir() if not _loaded_project.is_empty() else ""
	var invalid_project: String = _project_error()
	if not invalid_project.is_empty():
		_notice.text = invalid_project
		return
	_notice.text = "Loading T3 Code session choices…"
	_loading = true
	var result: Dictionary = await _call_tool.call(STATUS_TOOL, {})
	_loading = false
	var failure: String = tool_error(result)
	if not failure.is_empty():
		_notice.text = failure
		return
	var advertised: Variant = result.get("launch_options")
	if not advertised is Dictionary:
		_notice.text = "T3 Code returned no launch choices. Reopen after starting its runtime."
		return
	_options = advertised
	if _options.get("available") != true:
		_notice.text = "T3 Code launch choices are unavailable. Start its runtime, then reopen this dialog.\n%s" % str(advertised)
		return
	if not result_matches_project():
		_notice.text = "Saved project folder: %s\nT3 Code pinned folder: %s\nOpen the pinned project or restart T3 Code for the saved folder." % [_workspace.text, str(_options.get("workspace", ""))]
		return
	var models: Variant = _options.get("models", [])
	if models is Array:
		var model_list: Array = models
		for raw_model: Variant in model_list:
			if raw_model is Dictionary:
				var model_choice: Dictionary = raw_model
				if model_choice.get("id") is String:
					_choices.append(model_choice)
					_models.add_item(str(model_choice.get("label", model_choice.id)))
	var default_selection: Dictionary = {}
	var raw_default: Variant = _options.get("default")
	if raw_default is Dictionary:
		default_selection = raw_default
	var default_index: int = -1
	if not default_selection.is_empty():
		for choice_index: int in range(_choices.size()):
			if _choices[choice_index].id == default_selection.get("model"):
				default_index = choice_index
	_models.select(default_index)
	_on_model_selected(default_index)
	if default_index >= 0:
		var default_options: Variant = default_selection.get("options", [])
		if default_options is Array:
			var option_list: Array = default_options
			for raw_option: Variant in option_list:
				if raw_option is Dictionary:
					var option: Dictionary = raw_option
					if option.get("id") == "reasoningEffort":
						for effort_index: int in range(_efforts.item_count):
							if _efforts.get_item_metadata(effort_index) == option.get("value"):
								_efforts.select(effort_index)
	var registration_note: String = ""
	if _options.get("registered") == false:
		registration_note = "First use: register %s with T3 Code" % _workspace.text
	elif _options.get("registered") != true:
		registration_note = "T3 Code project registration is unknown. Reopen after its runtime is ready."
	_notice.text = registration_note
	if default_selection.is_empty():
		_notice.text += "\nChoose a listed model. %s" % str(_options.get("default_error", ""))


func _project_error() -> String:
	if _loaded_project.is_empty() or not _loaded_project.is_absolute_path() \
			or _loaded_project.get_extension().to_lower() != "minproj" \
			or not FileAccess.file_exists(_loaded_project):
		return "Save the current project before starting T3 Code."
	if str(_project_path.call()) != _loaded_project:
		return "The current project changed. Reopen this dialog before starting T3 Code."
	return ""


func result_matches_project() -> bool:
	return str(_options.get("workspace", "")).simplify_path() == _workspace.text.simplify_path()


func validation_error() -> String:
	var invalid_project: String = _project_error()
	if not invalid_project.is_empty():
		return invalid_project
	if _loading:
		return "Wait for T3 Code session choices."
	if _options.get("available") != true or not result_matches_project():
		return _notice.text
	if _options.get("registered") != true and _options.get("registered") != false:
		return "T3 Code project registration is unknown."
	if _models.selected < 0 or _models.selected >= _choices.size():
		return "Choose an advertised Codex model."
	return ""


func _on_model_selected(choice_index: int) -> void:
	_efforts.clear()
	_efforts.add_item("Default")
	_efforts.set_item_metadata(0, "")
	_efforts.select(0)
	_efforts.disabled = true
	if choice_index < 0 or choice_index >= _choices.size():
		return
	var model_choice: Dictionary = _choices[choice_index]
	var advertised_efforts: Variant = model_choice.get("efforts")
	if advertised_efforts is Array:
		var effort_list: Array = advertised_efforts
		_efforts.disabled = effort_list.is_empty()
		for effort: Variant in effort_list:
			if not effort is String:
				continue
			_efforts.add_item(str(effort))
			var effort_index: int = _efforts.item_count - 1
			_efforts.set_item_metadata(effort_index, effort)
			if effort == model_choice.get("default_effort"):
				_efforts.select(effort_index)
	else:
		_efforts.set_item_text(0, "Default (effort support unverified)")


func launch(chat_id: String) -> Dictionary:
	var args: Dictionary = {"chat_id": chat_id, "model": _choices[_models.selected].id}
	var effort: String = str(_efforts.get_item_metadata(_efforts.selected))
	if not effort.is_empty():
		args["effort"] = effort
	return await _call_tool.call(LAUNCH_TOOL, args)


static func tool_error(result: Dictionary) -> String:
	if result.get("kind") == "error" or result.get("success") == false \
			or result.get("isError") == true or result.has("error"):
		return "%s: %s" % [str(result.get("code", result.get("error_code", "launch_failed"))),
			str(result.get("text", result.get("error_message", result.get("error", result))))]
	return ""


func show_result(message: String) -> void:
	_result.text = message
	_result.visible = not message.is_empty()
