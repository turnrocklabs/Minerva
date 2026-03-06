class_name SpendingDashboard
extends Window
## Spending dashboard showing cost breakdowns, per-model usage, and budget controls.
## Opened via Tools > Spending...

var _summary_label: RichTextLabel
var _model_table: VBoxContainer
var _provider_table: VBoxContainer
var _hourly_table: VBoxContainer
var _budget_input: LineEdit
var _budget_period_dropdown: OptionButton
var _budget_error_label: Label
var _budget_bar: ProgressBar
var _budget_status_label: Label
var _budget_set_button: Button

const _PERIOD_MAP := {0: "hour", 1: "day", 2: "week", 3: "month"}
const _PERIOD_INDEX := {"hour": 0, "day": 1, "week": 2, "month": 3}
const _PERIOD_LABELS := {"hour": "Hourly", "day": "Daily", "week": "Weekly", "month": "Monthly"}


func _init() -> void:
	title = "Spending Dashboard"
	size = Vector2i(700, 600)
	min_size = Vector2i(550, 400)
	transient = true
	exclusive = false
	wrap_controls = true
	close_requested.connect(hide)


func _ready() -> void:
	_build_ui()
	refresh()


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var tabs := TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(tabs)

	# Tab 1: Overview
	var overview_scroll := ScrollContainer.new()
	overview_scroll.name = "Overview"
	overview_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(overview_scroll)

	var overview_vbox := VBoxContainer.new()
	overview_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overview_scroll.add_child(overview_vbox)

	# Summary section
	_summary_label = RichTextLabel.new()
	_summary_label.bbcode_enabled = true
	_summary_label.fit_content = true
	_summary_label.scroll_active = false
	_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_label.custom_minimum_size.y = 80
	overview_vbox.add_child(_summary_label)

	overview_vbox.add_child(HSeparator.new())

	# Budget section
	var budget_section := _build_budget_section()
	overview_vbox.add_child(budget_section)

	overview_vbox.add_child(HSeparator.new())

	# Provider breakdown
	var prov_header := Label.new()
	prov_header.text = "By Provider"
	prov_header.add_theme_font_size_override("font_size", 16)
	overview_vbox.add_child(prov_header)

	_provider_table = VBoxContainer.new()
	_provider_table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overview_vbox.add_child(_provider_table)

	# Tab 2: By Model
	var model_scroll := ScrollContainer.new()
	model_scroll.name = "By Model"
	model_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(model_scroll)

	_model_table = VBoxContainer.new()
	_model_table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	model_scroll.add_child(_model_table)

	# Tab 3: Hourly
	var hourly_scroll := ScrollContainer.new()
	hourly_scroll.name = "Hourly"
	hourly_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(hourly_scroll)

	_hourly_table = VBoxContainer.new()
	_hourly_table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hourly_scroll.add_child(_hourly_table)


func _build_budget_section() -> VBoxContainer:
	var section := VBoxContainer.new()

	var header := Label.new()
	header.text = "Budget"
	header.add_theme_font_size_override("font_size", 16)
	section.add_child(header)

	_budget_bar = ProgressBar.new()
	_budget_bar.custom_minimum_size.y = 24
	_budget_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_budget_bar.show_percentage = false
	section.add_child(_budget_bar)

	_budget_status_label = Label.new()
	_budget_status_label.text = "No budget set"
	section.add_child(_budget_status_label)

	var budget_row := HBoxContainer.new()
	budget_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var budget_label := Label.new()
	budget_label.text = "Budget ($): "
	budget_row.add_child(budget_label)

	_budget_input = LineEdit.new()
	_budget_input.placeholder_text = "e.g. 5.00"
	_budget_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	budget_row.add_child(_budget_input)

	_budget_period_dropdown = OptionButton.new()
	_budget_period_dropdown.add_item("Per Hour")
	_budget_period_dropdown.add_item("Per Day")
	_budget_period_dropdown.add_item("Per Week")
	_budget_period_dropdown.add_item("Per Month")
	_budget_period_dropdown.selected = 1  # Default: Per Day
	budget_row.add_child(_budget_period_dropdown)

	_budget_set_button = Button.new()
	_budget_set_button.text = "Set Budget"
	_budget_set_button.pressed.connect(_on_set_budget)
	budget_row.add_child(_budget_set_button)

	var clear_button := Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(_on_clear_budget)
	budget_row.add_child(clear_button)

	section.add_child(budget_row)

	_budget_error_label = Label.new()
	_budget_error_label.add_theme_color_override("font_color", Color(0.9, 0.2, 0.2))
	_budget_error_label.visible = false
	section.add_child(_budget_error_label)

	return section


func refresh() -> void:
	var tracker = SingletonObject.cost_tracker
	if not tracker:
		return

	_refresh_summary(tracker)
	_refresh_providers(tracker)
	_refresh_models(tracker)
	_refresh_hourly(tracker)
	_refresh_budget(tracker)


func _refresh_summary(tracker) -> void:
	var today_cost: float = tracker.get_cost_today()
	var month_cost: float = tracker.get_total_spend()
	var summary: Dictionary = tracker.get_cost_summary("today")
	var calls: int = summary.get("call_count", 0)
	var input_tok: int = summary.get("total_input_tokens", 0)
	var output_tok: int = summary.get("total_output_tokens", 0)

	_summary_label.text = ""
	_summary_label.append_text("[b]Today:[/b] %s  (%d calls, %s in / %s out)\n" % [
		_fmt_cost(today_cost), calls, _fmt_tokens(input_tok), _fmt_tokens(output_tok)
	])
	_summary_label.append_text("[b]This Month:[/b] %s" % _fmt_cost(month_cost))


func _refresh_providers(tracker) -> void:
	_clear_children(_provider_table)

	var by_provider: Dictionary = tracker.get_cost_by_provider()
	var total: float = 0.0
	for prov in by_provider:
		total += by_provider[prov]

	if by_provider.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No spending data yet"
		empty_label.modulate.a = 0.5
		_provider_table.add_child(empty_label)
		return

	# Header row
	_provider_table.add_child(_make_table_row(["Provider", "Cost", "Share"], true))

	for prov in by_provider:
		var cost: float = by_provider[prov]
		var pct: float = (cost / total * 100.0) if total > 0 else 0.0
		_provider_table.add_child(_make_table_row([
			prov, _fmt_cost(cost), "%.0f%%" % pct
		]))


func _refresh_models(tracker) -> void:
	_clear_children(_model_table)

	var details: Array = tracker.get_model_details()
	if details.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No spending data yet"
		empty_label.modulate.a = 0.5
		_model_table.add_child(empty_label)
		return

	# Header
	_model_table.add_child(_make_table_row(
		["Model", "Provider", "In Tokens", "Out Tokens", "Cost", "Calls"], true
	))

	for d in details:
		_model_table.add_child(_make_table_row([
			d["model"],
			d["provider"],
			_fmt_tokens(d["input_tokens"]),
			_fmt_tokens(d["output_tokens"]),
			_fmt_cost(d["cost_usd"]),
			str(d["calls"]),
		]))


func _refresh_hourly(tracker) -> void:
	_clear_children(_hourly_table)

	var hourly: Array = tracker.get_hourly_costs_today()
	if hourly.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No spending data for today"
		empty_label.modulate.a = 0.5
		_hourly_table.add_child(empty_label)
		return

	var header := Label.new()
	header.text = "Today's Spend by Hour"
	header.add_theme_font_size_override("font_size", 16)
	_hourly_table.add_child(header)

	# Find max for bar scaling
	var max_cost := 0.0
	for h in hourly:
		max_cost = maxf(max_cost, h["cost_usd"])

	for h in hourly:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var time_label := Label.new()
		time_label.text = "%s:00" % h["hour"]
		time_label.custom_minimum_size.x = 50
		row.add_child(time_label)

		var bar := ProgressBar.new()
		bar.max_value = max_cost if max_cost > 0 else 1.0
		bar.value = h["cost_usd"]
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(200, 18)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bar)

		var cost_label := Label.new()
		cost_label.text = _fmt_cost(h["cost_usd"])
		cost_label.custom_minimum_size.x = 70
		cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(cost_label)

		_hourly_table.add_child(row)


func _refresh_budget(tracker) -> void:
	var budget_info: Dictionary = tracker.get_global_budget()
	if not budget_info.get("has_budget", false):
		_budget_bar.value = 0
		_budget_bar.max_value = 1
		_budget_status_label.text = "No budget set"
		_budget_input.text = ""
		_budget_period_dropdown.selected = 1
		return

	var budget: float = budget_info.get("budget", 0.0)
	var spent: float = budget_info.get("spent", 0.0)
	var remaining: float = budget_info.get("remaining", 0.0)
	var pct: float = budget_info.get("pct_used", 0.0)
	var period: String = budget_info.get("period", "day")

	_budget_bar.max_value = budget
	_budget_bar.value = spent

	# Color the bar based on usage
	var bar_style := StyleBoxFlat.new()
	bar_style.corner_radius_top_left = 3
	bar_style.corner_radius_top_right = 3
	bar_style.corner_radius_bottom_left = 3
	bar_style.corner_radius_bottom_right = 3
	if pct >= 1.0:
		bar_style.bg_color = Color(0.9, 0.2, 0.2)  # Red
	elif pct >= 0.8:
		bar_style.bg_color = Color(0.9, 0.7, 0.1)  # Yellow
	else:
		bar_style.bg_color = Color(0.2, 0.8, 0.3)  # Green
	_budget_bar.add_theme_stylebox_override("fill", bar_style)

	var period_label: String = _PERIOD_LABELS.get(period, "Daily")
	_budget_status_label.text = "%s %s budget: %s spent / %s budget (%s remaining)" % [
		period_label, _fmt_cost(budget), _fmt_cost(spent), _fmt_cost(budget), _fmt_cost(remaining)
	]
	_budget_input.text = "%.2f" % budget
	_budget_period_dropdown.selected = _PERIOD_INDEX.get(period, 1)


func _on_set_budget() -> void:
	var tracker = SingletonObject.cost_tracker
	if not tracker:
		return

	# Validate input with regex: digits with optional decimal
	var input_text: String = _budget_input.text.strip_edges()
	var regex := RegEx.new()
	regex.compile("^\\d+(\\.\\d+)?$")
	if not regex.search(input_text):
		_budget_error_label.text = "Invalid amount — enter a number (e.g. 5.00)"
		_budget_error_label.visible = true
		return

	var amount: float = input_text.to_float()
	if amount <= 0:
		_budget_error_label.text = "Amount must be greater than zero"
		_budget_error_label.visible = true
		return

	_budget_error_label.visible = false
	var period: String = _PERIOD_MAP.get(_budget_period_dropdown.selected, "day")
	tracker.set_global_budget(amount, 0.8, period)
	_refresh_budget(tracker)


func _on_clear_budget() -> void:
	var tracker = SingletonObject.cost_tracker
	if not tracker:
		return
	tracker.clear_budget("__global__")
	_refresh_budget(tracker)


#region Helpers

func _make_table_row(cells: Array, is_header: bool = false) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in cells.size():
		var label := Label.new()
		label.text = str(cells[i])
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if is_header:
			label.add_theme_font_size_override("font_size", 13)
			label.modulate.a = 0.7
		# First column wider
		if i == 0:
			label.size_flags_stretch_ratio = 2.0
		row.add_child(label)
	return row


func _fmt_cost(dollars: float) -> String:
	if dollars < 0.001:
		return "%.3f¢" % (dollars * 100)
	elif dollars < 0.01:
		return "%.2f¢" % (dollars * 100)
	elif dollars < 1.0:
		return "%.0f¢" % (dollars * 100)
	else:
		return "$%.2f" % dollars


func _fmt_tokens(count: int) -> String:
	if count >= 1_000_000:
		return "%.1fM" % (count / 1_000_000.0)
	elif count >= 1000:
		return "%.1fK" % (count / 1000.0)
	return str(count)


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		child.queue_free()

#endregion
