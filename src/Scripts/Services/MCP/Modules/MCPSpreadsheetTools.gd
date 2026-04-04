class_name MCPSpreadsheetTools
extends MCPToolModule
## MCP tool module for Spreadsheet and Chart domain tools.

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const SpreadsheetChartScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetChart.gd")
const SpreadsheetFileHandlerScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetFileHandler.gd")
const SpreadsheetCellScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetCell.gd")
const NoteScript := preload("res://Scripts/UI/Controls/Note.gd")


func get_tool_names() -> Array[String]:
	return [
		"minerva_create_spreadsheet_editor",
		"minerva_get_spreadsheet_data",
		"minerva_update_spreadsheet_data",
		"minerva_add_spreadsheet_row",
		"minerva_add_spreadsheet_column",
		"minerva_delete_spreadsheet_row",
		"minerva_delete_spreadsheet_column",
		"minerva_insert_spreadsheet_row",
		"minerva_insert_spreadsheet_column",
		"minerva_format_cells",
		"minerva_set_row_height",
		"minerva_set_column_width",
		"minerva_set_cell_formula",
		"minerva_create_chart",
		"minerva_get_chart_image",
		"minerva_list_charts",
		"minerva_update_chart",
		"minerva_delete_chart",
		"minerva_refresh_charts",
		"minerva_link_spreadsheet_to_note",
		"minerva_export_to_nudge",
		"minerva_undo_spreadsheet",
		"minerva_redo_spreadsheet",
		"minerva_get_spreadsheet_history",
		"minerva_fill_down",
		"minerva_recalculate",
	]


func register_tools() -> void:
	server._register_tool("minerva_create_spreadsheet_editor",
		"Create a new spreadsheet editor tab. Returns an editor_name that can be used for subsequent operations. Next steps: use minerva_update_spreadsheet_data to populate cells, minerva_format_cells for styling, minerva_create_chart for visualization, minerva_link_spreadsheet_to_note to save as a note.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the spreadsheet tab"
				},
				"csv_content": {
					"type": "string",
					"description": "Optional initial CSV content to populate the spreadsheet"
				},
				"file_path": {
					"type": "string",
					"description": "Optional file path to load (CSV, TSV, XLSX, or .minsheet)"
				}
			},
			"required": ["name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_get_spreadsheet_data",
		"Get the data from a spreadsheet in various formats. Returns data_starts_at_row (1-based) to show where content begins. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"format": {
					"type": "string",
					"description": "Output format: 'csv', 'json', or 'markdown'. Default: 'csv'",
					"enum": ["csv", "json", "markdown"]
				},
				"range": {
					"type": "string",
					"description": "Optional cell range to get (e.g., 'A1:C10'). If not specified, returns all data."
				},
				"include_empty_rows": {
					"type": "boolean",
					"description": "If true, include leading empty rows in output. Default: false (only returns used data range)."
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_update_spreadsheet_data",
		"Update cells in a spreadsheet. Can update individual cells or load entire CSV content. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"csv_content": {
					"type": "string",
					"description": "Full CSV content to replace all data"
				},
				"cells": {
					"type": "array",
					"description": "Array of cell updates: [{\"cell\": \"A1\", \"value\": \"Hello\"}, ...]",
					"items": {
						"type": "object",
						"properties": {
							"cell": {"type": "string", "description": "Cell reference (e.g., 'A1', 'B2')"},
							"value": {"type": "string", "description": "Value to set (string, number, or formula starting with '=')"}
						},
						"required": ["cell", "value"]
					}
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_add_spreadsheet_row",
		"Add a new row to the spreadsheet with optional values.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"at_row": {
					"type": "integer",
					"description": "Row index to insert at (0-based). If not specified, appends at the end."
				},
				"values": {
					"type": "array",
					"description": "Array of values for the new row (one per column)",
					"items": {"type": "string"}
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_add_spreadsheet_column",
		"Add a new column to the spreadsheet with optional header.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"at_col": {
					"type": "integer",
					"description": "Column index to insert at (0-based). If not specified, appends at the end."
				},
				"header": {
					"type": "string",
					"description": "Header text for the new column"
				},
				"values": {
					"type": "array",
					"description": "Array of values for the column (starting from row 1 if header is provided)",
					"items": {"type": "string"}
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_delete_spreadsheet_row",
		"Delete a row from the spreadsheet. All rows below shift up. This action can be undone.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"row": {
					"type": "integer",
					"description": "Row number to delete (1-based, like Excel). Row 1 is the first row."
				}
			},
			"required": ["editor_name", "row"]
		}
	, "spreadsheet")

	server._register_tool("minerva_delete_spreadsheet_column",
		"Delete a column from the spreadsheet. All columns to the right shift left. This action can be undone.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"column": {
					"type": "integer",
					"description": "Column number to delete (1-based). Column 1 is A, column 2 is B, etc."
				}
			},
			"required": ["editor_name", "column"]
		}
	, "spreadsheet")

	server._register_tool("minerva_insert_spreadsheet_row",
		"Insert an empty row at a specific position. All rows at and below shift down.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"at_row": {
					"type": "integer",
					"description": "Row index where the empty row will be inserted (0-based)."
				}
			},
			"required": ["editor_name", "at_row"]
		}
	, "spreadsheet")

	server._register_tool("minerva_insert_spreadsheet_column",
		"Insert an empty column at a specific position. All columns at and to the right shift right.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"at_column": {
					"type": "integer",
					"description": "Column index where the empty column will be inserted (0-based). 0 = A."
				}
			},
			"required": ["editor_name", "at_column"]
		}
	, "spreadsheet")

	server._register_tool("minerva_format_cells",
		"Apply formatting to cells or a range of cells. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"range": {
					"type": "string",
					"description": "Cell range to format (e.g., 'A1', 'A1:C1', 'A:A' for whole column)"
				},
				"bold": {
					"type": "boolean",
					"description": "Set text bold"
				},
				"italic": {
					"type": "boolean",
					"description": "Set text italic"
				},
				"alignment": {
					"type": "string",
					"description": "Text alignment: 'left', 'center', or 'right'",
					"enum": ["left", "center", "right"]
				},
				"text_color": {
					"type": "string",
					"description": "Text color as hex (e.g., '#FF0000' for red)"
				},
				"bg_color": {
					"type": "string",
					"description": "Background color as hex (e.g., '#FFFF00' for yellow)"
				},
				"number_format": {
					"type": "string",
					"description": "Number display format: 'none' (default), 'currency' or 'usd' ($X,XXX.XX), 'percent' (X.XX%), 'decimal' (X.XX)",
					"enum": ["none", "currency", "usd", "percent", "decimal"]
				},
				"wrap_text": {
					"type": "boolean",
					"description": "Enable text wrapping in cell (displays text on multiple lines)"
				}
			},
			"required": ["editor_name", "range"]
		}
	, "spreadsheet")

	server._register_tool("minerva_set_row_height",
		"Set the height of one or more spreadsheet rows. Use to make wrapped text visible.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"rows": {
					"type": "array",
					"description": "Array of row configs. Row numbers are 1-based.",
					"items": {
						"type": "object",
						"properties": {
							"row": {
								"type": "integer",
								"description": "Row number (1-based)"
							},
							"height": {
								"type": "number",
								"description": "Height in pixels (min 16, max 200)"
							}
						},
						"required": ["row", "height"]
					}
				}
			},
			"required": ["editor_name", "rows"]
		}
	, "spreadsheet")

	server._register_tool("minerva_set_column_width",
		"Set the width of one or more spreadsheet columns. Use to make content fully visible.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"columns": {
					"type": "array",
					"description": "Array of column configs. Column can be a letter (A, B, ...) or 1-based number.",
					"items": {
						"type": "object",
						"properties": {
							"column": {
								"type": "string",
								"description": "Column letter (e.g., 'A', 'B') or 1-based number (e.g., '1', '2')"
							},
							"width": {
								"type": "number",
								"description": "Width in pixels (min 30, max 500)"
							}
						},
						"required": ["column", "width"]
					}
				}
			},
			"required": ["editor_name", "columns"]
		}
	, "spreadsheet")

	server._register_tool("minerva_set_cell_formula",
		"Set a formula in a specific cell. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"cell": {
					"type": "string",
					"description": "Cell reference (e.g., 'A1', 'B2')"
				},
				"formula": {
					"type": "string",
					"description": "Formula to set (e.g., '=SUM(A1:A10)', '=A1+B1'). The '=' prefix is optional."
				}
			},
			"required": ["editor_name", "cell", "formula"]
		}
	, "spreadsheet")

	server._register_tool("minerva_create_chart",
		"Create a chart from spreadsheet data. Requires editor_name from minerva_list_editors. Get column/row data from minerva_get_spreadsheet_data first. After creating, use minerva_get_chart_image to view the chart, minerva_update_chart to modify it.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"title": {
					"type": "string",
					"description": "Chart title"
				},
				"type": {
					"type": "string",
					"description": "Chart type: 'line' or 'bar'. Default: 'line'",
					"enum": ["line", "bar"]
				},
				"x_range": {
					"type": "string",
					"description": "Cell range for X-axis values (e.g., 'A1:A10')"
				},
				"series": {
					"type": "array",
					"description": "Array of series ranges (e.g., ['B1:B10', 'C1:C10'])",
					"items": {"type": "string"}
				},
				"x_is_date": {
					"type": "boolean",
					"description": "Whether X-axis contains date values. Default: false"
				},
				"first_row_is_header": {
					"type": "boolean",
					"description": "Whether first row contains headers (skip for data, use for labels). Default: true"
				}
			},
			"required": ["editor_name", "x_range", "series"]
		}
	, "spreadsheet")

	server._register_tool("minerva_get_chart_image",
		"Export a chart as a base64-encoded PNG image for LLM viewing. Requires editor_name and chart_id from minerva_list_charts.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"chart_index": {
					"type": "integer",
					"description": "Index of the chart to export (0-based). Default: 0 (first chart)"
				},
				"width": {
					"type": "integer",
					"description": "Image width in pixels. Default: 800"
				},
				"height": {
					"type": "integer",
					"description": "Image height in pixels. Default: 400"
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_list_charts",
		"List all charts in a spreadsheet editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_update_chart",
		"Update an existing chart's properties. Use this when data ranges change or to modify chart appearance.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"chart_id": {
					"type": "string",
					"description": "The chart ID to update (from minerva_list_charts or minerva_create_chart)"
				},
				"chart_index": {
					"type": "integer",
					"description": "Alternative: chart index (0-based) if chart_id not provided"
				},
				"title": {
					"type": "string",
					"description": "New chart title"
				},
				"type": {
					"type": "string",
					"description": "Chart type: 'line' or 'bar'",
					"enum": ["line", "bar"]
				},
				"x_range": {
					"type": "string",
					"description": "New cell range for X-axis values (e.g., 'A1:A20')"
				},
				"series": {
					"type": "array",
					"description": "New array of series ranges (replaces existing series)",
					"items": {"type": "string"}
				},
				"x_is_date": {
					"type": "boolean",
					"description": "Whether X-axis contains date values"
				},
				"first_row_is_header": {
					"type": "boolean",
					"description": "Whether first row contains headers"
				},
				"x_axis_label": {
					"type": "string",
					"description": "X-axis label"
				},
				"y_axis_label": {
					"type": "string",
					"description": "Y-axis label"
				},
				"show_legend": {
					"type": "boolean",
					"description": "Whether to show the legend"
				},
				"y_auto_scale": {
					"type": "boolean",
					"description": "Whether to auto-scale Y axis"
				},
				"y_min": {
					"type": "number",
					"description": "Y-axis minimum (when y_auto_scale is false)"
				},
				"y_max": {
					"type": "number",
					"description": "Y-axis maximum (when y_auto_scale is false)"
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_delete_chart",
		"Delete a chart from a spreadsheet editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"chart_id": {
					"type": "string",
					"description": "The chart ID to delete"
				},
				"chart_index": {
					"type": "integer",
					"description": "Alternative: chart index (0-based) if chart_id not provided"
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_refresh_charts",
		"Refresh all charts in a spreadsheet to reflect current data. Call this after updating spreadsheet data.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_link_spreadsheet_to_note",
		"Create a linked note from a spreadsheet. The note displays the spreadsheet as a markdown table. Editing the note opens the spreadsheet editor. Changes sync bidirectionally.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab to link"
				},
				"note_title": {
					"type": "string",
					"description": "Title for the new note. Defaults to spreadsheet name if not provided"
				},
				"thread_name": {
					"type": "string",
					"description": "Name of the notes thread/tab to add the note to. Creates new thread if doesn't exist"
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_export_to_nudge",
		"Export spreadsheet data to the Nudge MCP hint system for quick LLM retrieval.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"component": {
					"type": "string",
					"description": "Nudge component name for organizing hints (e.g., 'finance', 'inventory')"
				},
				"key": {
					"type": "string",
					"description": "Nudge key for this data (e.g., 'monthly_revenue', 'stock_levels')"
				},
				"format": {
					"type": "string",
					"description": "Export format: 'raw' (full JSON), 'summary' (row/col counts, totals), 'schema' (column names/types), 'timeseries' (date-indexed), 'kv_pairs' (two-column key-value)",
					"enum": ["raw", "summary", "schema", "timeseries", "kv_pairs"]
				},
				"include_charts": {
					"type": "boolean",
					"description": "Include chart descriptions in the export. Default: false"
				}
			},
			"required": ["editor_name", "component", "key"]
		}
	, "spreadsheet")

	server._register_tool("minerva_undo_spreadsheet",
		"Undo the last action in a spreadsheet editor. Returns information about what was undone.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"count": {
					"type": "integer",
					"description": "Number of actions to undo (default: 1). Use this to undo multiple steps at once."
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_redo_spreadsheet",
		"Redo a previously undone action in a spreadsheet editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"count": {
					"type": "integer",
					"description": "Number of actions to redo (default: 1). Use this to redo multiple steps at once."
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_get_spreadsheet_history",
		"Get the undo/redo history status of a spreadsheet editor.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")

	server._register_tool("minerva_fill_down",
		"Fill down formulas/values from a source row to target rows. Copies the content from the source row and adjusts relative cell references (e.g., A1 becomes A2, A3, etc.). Absolute references ($A$1) are preserved. This is equivalent to Excel's Ctrl+D fill down feature.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				},
				"source_row": {
					"type": "integer",
					"description": "The 1-based row number containing the formulas/values to copy (e.g., 2 for row 2)"
				},
				"target_rows": {
					"type": "array",
					"items": {"type": "integer"},
					"description": "Array of 1-based row numbers to fill into (e.g., [3, 4, 5] to fill rows 3-5)"
				},
				"columns": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Array of column letters to fill (e.g., ['B', 'C', 'D'] or ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I']). If omitted, fills all columns with data in the source row."
				}
			},
			"required": ["editor_name", "source_row", "target_rows"]
		}
	, "spreadsheet")

	server._register_tool("minerva_recalculate",
		"Recalculate all formulas in a spreadsheet. Use this after bulk operations or when cross-sheet references need refreshing.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the spreadsheet editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "spreadsheet")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_create_spreadsheet_editor":
			return await _create_spreadsheet_editor(arguments)
		"minerva_get_spreadsheet_data":
			return _get_spreadsheet_data(arguments)
		"minerva_update_spreadsheet_data":
			return _update_spreadsheet_data(arguments)
		"minerva_add_spreadsheet_row":
			return _add_spreadsheet_row(arguments)
		"minerva_add_spreadsheet_column":
			return _add_spreadsheet_column(arguments)
		"minerva_delete_spreadsheet_row":
			return _delete_spreadsheet_row(arguments)
		"minerva_delete_spreadsheet_column":
			return _delete_spreadsheet_column(arguments)
		"minerva_insert_spreadsheet_row":
			return _insert_spreadsheet_row(arguments)
		"minerva_insert_spreadsheet_column":
			return _insert_spreadsheet_column(arguments)
		"minerva_format_cells":
			return _format_cells(arguments)
		"minerva_set_row_height":
			return _set_row_height(arguments)
		"minerva_set_column_width":
			return _set_column_width(arguments)
		"minerva_set_cell_formula":
			return _set_cell_formula(arguments)
		"minerva_create_chart":
			return _create_chart(arguments)
		"minerva_get_chart_image":
			return await _get_chart_image(arguments)
		"minerva_list_charts":
			return _list_charts(arguments)
		"minerva_update_chart":
			return _update_chart(arguments)
		"minerva_delete_chart":
			return _delete_chart(arguments)
		"minerva_refresh_charts":
			return _refresh_charts(arguments)
		"minerva_link_spreadsheet_to_note":
			return _link_spreadsheet_to_note(arguments)
		"minerva_export_to_nudge":
			return await _export_to_nudge(arguments)
		"minerva_undo_spreadsheet":
			return _undo_spreadsheet(arguments)
		"minerva_redo_spreadsheet":
			return _redo_spreadsheet(arguments)
		"minerva_get_spreadsheet_history":
			return _get_spreadsheet_history(arguments)
		"minerva_fill_down":
			return _fill_down_spreadsheet(arguments)
		"minerva_recalculate":
			return _recalculate_spreadsheet(arguments)
	return MCPToolUtils.error("Unknown spreadsheet tool: %s" % tool_name)


#region Helpers

func _find_spreadsheet_editor(editor_name: String) -> Variant:
	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return null

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.SPREADSHEET:
		return null

	return editor


## Helper to generate CSV including empty rows from row 0
func _to_csv_with_empty_rows(data) -> String:
	var used_range: Rect2i = data.get_used_range()
	if used_range.size == Vector2i.ZERO:
		return ""

	var lines := PackedStringArray()
	var delimiter := ","

	# Start from row 0, not from used_range.position.y
	for row in range(0, used_range.end.y):
		var values := PackedStringArray()
		for col in range(used_range.position.x, used_range.end.x):
			var cell = data.get_cell_if_exists(row, col)
			var val := ""
			if cell and not cell.is_empty():
				val = str(cell.value)
				# Escape delimiter and quotes
				if delimiter in val or '"' in val or '\n' in val:
					val = '"' + val.replace('"', '""') + '"'
			values.append(val)
		lines.append(delimiter.join(values))

	return "\n".join(lines)


## Export spreadsheet as raw JSON data
func _export_raw(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var cells_data: Array = []

	for row in range(bounds.position.y, bounds.position.y + bounds.size.y):
		var row_data: Array = []
		for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
			row_data.append(data.get_cell_display(row, col))
		cells_data.append(row_data)

	return {
		"rows": bounds.size.y,
		"columns": bounds.size.x,
		"data": cells_data
	}


## Export spreadsheet summary (counts, headers, totals)
func _export_summary(data: SpreadsheetDataScript, spreadsheet_editor) -> Dictionary:
	var bounds := data.get_used_range()

	# Get headers (first row)
	var headers: Array = []
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		headers.append(data.get_cell_display(bounds.position.y, col))

	# Calculate numeric totals per column
	var totals: Dictionary = {}
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		var total: float = 0.0
		var has_numbers := false
		for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
			var cell = data.get_cell_if_exists(row, col)
			if cell and cell.type == SpreadsheetCellScript.CellType.NUMBER:
				total += float(cell.value)
				has_numbers = true
		if has_numbers:
			var header: String = headers[col - bounds.position.x] if col - bounds.position.x < headers.size() else "Column %d" % col
			totals[header] = total

	return {
		"rows": bounds.size.y,
		"columns": bounds.size.x,
		"headers": headers,
		"totals": totals,
		"chart_count": spreadsheet_editor.charts.size() if spreadsheet_editor else 0
	}


## Export spreadsheet schema (column names and types)
func _export_schema(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var columns: Array = []

	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		var header: String = data.get_cell_display(bounds.position.y, col)

		# Detect column type from first few data cells
		var detected_type := "text"
		var sample_values: Array = []
		for row in range(bounds.position.y + 1, mini(bounds.position.y + 4, bounds.position.y + bounds.size.y)):
			var cell = data.get_cell_if_exists(row, col)
			if cell:
				sample_values.append(data.get_cell_display(row, col))
				if cell.type == SpreadsheetCellScript.CellType.NUMBER:
					detected_type = "number"
				elif cell.type == SpreadsheetCellScript.CellType.DATE:
					detected_type = "date"
				elif cell.type == SpreadsheetCellScript.CellType.FORMULA:
					detected_type = "formula"

		columns.append({
			"name": header,
			"type": detected_type,
			"samples": sample_values
		})

	return {
		"column_count": bounds.size.x,
		"row_count": bounds.size.y - 1,  # Exclude header
		"columns": columns
	}


## Export as time series (first column as date keys)
func _export_timeseries(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var series: Dictionary = {}

	# Get column headers
	var headers: Array = []
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		headers.append(data.get_cell_display(bounds.position.y, col))

	# Build time series with date as key
	for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
		var date_key: String = data.get_cell_display(row, bounds.position.x)
		var values: Dictionary = {}

		for col in range(bounds.position.x + 1, bounds.position.x + bounds.size.x):
			var header: String = headers[col - bounds.position.x]
			values[header] = data.get_cell_display(row, col)

		series[date_key] = values

	return {
		"date_column": headers[0] if headers.size() > 0 else "Date",
		"value_columns": headers.slice(1) if headers.size() > 1 else [],
		"series": series
	}


## Export as key-value pairs from first two columns
func _export_kv_pairs(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var pairs: Dictionary = {}

	if bounds.size.x < 2:
		return {"error": "Need at least 2 columns for key-value pairs"}

	for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
		var key_val: String = data.get_cell_display(row, bounds.position.x)
		var value_val: String = data.get_cell_display(row, bounds.position.x + 1)
		if not key_val.is_empty():
			pairs[key_val] = value_val

	return pairs


## Call Nudge MCP server to set a hint
func _call_nudge_set_hint(component: String, key: String, value: Variant) -> Dictionary:
	# Try to find the Nudge MCP server connection
	if not server.mcp_manager:
		return {"error": "MCP manager not available"}

	# Check if Nudge server is connected
	if not server.mcp_manager.is_server_connected("nudge"):
		return {"error": "Nudge MCP server not connected"}

	# Call the nudge_set_hint tool
	var result: Dictionary = await server.mcp_manager.execute_tool("nudge_set_hint", {
		"component": component,
		"key": key,
		"value": value
	})

	return result

#endregion


#region Tool Implementations

func _create_spreadsheet_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Spreadsheet")
	var csv_content: String = args.get("csv_content", "")
	var file_path: String = args.get("file_path", "")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return {"error": "Editor pane not available", "success": false}

	# Before creating, check if resource with same name exists
	# If it does, return it with already_existed: true
	if not name_.is_empty():
		var existing_editor = MCPToolUtils.find_editor_by_name(name_)
		if existing_editor:
			return {"success": true, "already_existed": true, "editor_name": existing_editor.tab_title}

	# Check if file exists when file_path is provided
	if not file_path.is_empty() and not FileAccess.file_exists(file_path):
		return {"error": "File not found: %s" % file_path, "success": false}

	# Create the spreadsheet editor
	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	var file_arg: Variant = null
	if not file_path.is_empty():
		file_arg = file_path
	var editor = editor_pane.add(EditorGDScript.Type.SPREADSHEET, file_arg, name_, null)

	# Wait for the spreadsheet editor to be ready
	if not editor.spreadsheet_editor:
		await Engine.get_main_loop().process_frame

	# Set CSV content if provided (and no file was loaded)
	if not csv_content.is_empty() and file_path.is_empty() and editor.spreadsheet_editor:
		editor.spreadsheet_editor.set_content(csv_content)

	return {
		"success": true,
		"editor_name": editor.tab_title,
		"message": "Spreadsheet editor created. Use this editor_name for subsequent operations."
	}


func _get_spreadsheet_data(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var format_: String = args.get("format", "csv")
	#var range_str: String = args.get("range", "")
	var include_empty_rows: bool = args.get("include_empty_rows", false)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Get the used range to determine where data starts
	var used_range: Rect2i = data.get_used_range()
	var data_starts_at_row: int = used_range.position.y + 1  # Convert to 1-based

	var content: Variant
	match format_:
		"csv":
			if include_empty_rows:
				content = _to_csv_with_empty_rows(data)
			else:
				content = data.to_csv(",")
		"json":
			content = data.to_json_array()
		"markdown":
			content = data.to_markdown()
		_:
			if include_empty_rows:
				content = _to_csv_with_empty_rows(data)
			else:
				content = data.to_csv(",")

	return {
		"success": true,
		"format": format_,
		"data": content,
		"row_count": data.row_count,
		"column_count": data.column_count,
		"data_starts_at_row": data_starts_at_row,
		"has_leading_empty_rows": data_starts_at_row > 1
	}


func _update_spreadsheet_data(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var csv_content: String = args.get("csv_content", "")
	var cells: Array = args.get("cells", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	var updated_count := 0

	# If CSV content provided, replace all data
	if not csv_content.is_empty():
		editor.spreadsheet_editor.set_content(csv_content)
		updated_count = -1  # Indicate full replacement

	# Update individual cells (with history recording)
	if cells.size() > 0:
		for cell_update in cells:
			if cell_update is Dictionary:
				var cell_ref: String = cell_update.get("cell", "")
				var value: Variant = cell_update.get("value", "")

				if not cell_ref.is_empty():
					var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(cell_ref)
					if pos.x >= 0 and pos.y >= 0:
						# Use history-recording method
						editor.spreadsheet_editor.set_cell_value_with_history(pos.y, pos.x, value)
						updated_count += 1

	return {
		"success": true,
		"message": "Spreadsheet updated" if updated_count == -1 else "Updated %d cells" % updated_count
	}


func _add_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_row: int = args.get("at_row", -1)
	var values: Array = args.get("values", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Determine row index
	var row_idx: int = at_row if at_row >= 0 else data.row_count

	# Insert the row
	data.insert_row(row_idx)

	# Set values if provided (with history recording)
	for col in range(values.size()):
		editor.spreadsheet_editor.set_cell_value_with_history(row_idx, col, values[col])

	# Trigger redraw for row headers
	editor.spreadsheet_editor.row_headers.queue_redraw()

	return {
		"success": true,
		"row_index": row_idx,
		"message": "Row added at index %d" % row_idx
	}


func _add_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_col: int = args.get("at_col", -1)
	var header: String = args.get("header", "")
	var values: Array = args.get("values", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Determine column index
	var col_idx: int = at_col if at_col >= 0 else data.column_count

	# Insert the column
	data.insert_column(col_idx)

	# Set header if provided (row 0) with history recording
	var start_row := 0
	if not header.is_empty():
		editor.spreadsheet_editor.set_cell_value_with_history(0, col_idx, header)
		start_row = 1

	# Set values with history recording
	for i in range(values.size()):
		editor.spreadsheet_editor.set_cell_value_with_history(start_row + i, col_idx, values[i])

	# Trigger redraw for column headers
	editor.spreadsheet_editor.column_headers.queue_redraw()

	return {
		"success": true,
		"column_index": col_idx,
		"column_label": SpreadsheetDataScript.get_column_label(col_idx),
		"message": "Column added at index %d" % col_idx
	}


func _delete_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var row: int = args.get("row", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if row < 1:
		return {"error": "row number is required and must be >= 1 (1-based indexing)", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Convert from 1-based to 0-based indexing
	var internal_row: int = row - 1

	if internal_row >= data.row_count:
		return {"error": "Row %d out of bounds (max row: %d)" % [row, data.row_count], "success": false}

	# Delete the row with history support
	var success = editor.spreadsheet_editor.delete_row_with_history(internal_row)
	if not success:
		return {"error": "Failed to delete row %d" % row, "success": false}

	return {
		"success": true,
		"deleted_row": row,
		"message": "Row %d deleted (can be undone with Ctrl+Z)" % row
	}


func _delete_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var column: int = args.get("column", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if column < 1:
		return {"error": "column number is required and must be >= 1 (1-based indexing)", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Convert from 1-based to 0-based indexing
	var internal_col: int = column - 1

	if internal_col >= data.column_count:
		return {"error": "Column %d out of bounds (max column: %d)" % [column, data.column_count], "success": false}

	var col_label = SpreadsheetDataScript.get_column_label(internal_col)

	# Delete the column with history support
	var success = editor.spreadsheet_editor.delete_column_with_history(internal_col)
	if not success:
		return {"error": "Failed to delete column %d (%s)" % [column, col_label], "success": false}

	return {
		"success": true,
		"deleted_column": column,
		"deleted_column_label": col_label,
		"message": "Column %s deleted (can be undone with Ctrl+Z)" % col_label
	}


func _insert_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_row: int = args.get("at_row", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if at_row < 0:
		return {"error": "at_row is required and must be >= 0", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Insert empty row
	data.insert_row(at_row)

	# Trigger redraw
	editor.spreadsheet_editor.row_headers.queue_redraw()
	editor.spreadsheet_editor.queue_redraw()

	return {
		"success": true,
		"inserted_at_row": at_row,
		"message": "Empty row inserted at index %d" % at_row
	}


func _insert_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_column: int = args.get("at_column", -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if at_column < 0:
		return {"error": "at_column is required and must be >= 0", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Insert empty column
	data.insert_column(at_column)

	var col_label = SpreadsheetDataScript.get_column_label(at_column)

	# Trigger redraw
	editor.spreadsheet_editor.column_headers.queue_redraw()
	editor.spreadsheet_editor.queue_redraw()

	return {
		"success": true,
		"inserted_at_column": at_column,
		"inserted_column_label": col_label,
		"message": "Empty column inserted at %s (index %d)" % [col_label, at_column]
	}


func _format_cells(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var range_str: String = args.get("range", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if range_str.is_empty():
		return {"error": "range is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Parse the range
	var cells_to_format: Array[Vector2i] = []

	if range_str.contains(":"):
		# Range like A1:C10
		var parts: PackedStringArray = range_str.split(":")
		var start_pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(parts[0].strip_edges())
		var end_pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(parts[1].strip_edges())

		if start_pos.x >= 0 and start_pos.y >= 0 and end_pos.x >= 0 and end_pos.y >= 0:
			for row in range(mini(start_pos.y, end_pos.y), maxi(start_pos.y, end_pos.y) + 1):
				for col in range(mini(start_pos.x, end_pos.x), maxi(start_pos.x, end_pos.x) + 1):
					cells_to_format.append(Vector2i(col, row))
	else:
		# Single cell like A1
		var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(range_str)
		if pos.x >= 0 and pos.y >= 0:
			cells_to_format.append(Vector2i(pos.x, pos.y))

	if cells_to_format.is_empty():
		return {"error": "Invalid range: %s" % range_str, "success": false}

	# Build format options dictionary
	var format_options: Dictionary = {}

	if args.has("bold"):
		format_options["bold"] = MCPToolUtils.coerce_bool(args.get("bold"))
	if args.has("italic"):
		format_options["italic"] = MCPToolUtils.coerce_bool(args.get("italic"))
	if args.has("alignment"):
		var align_str: String = args.get("alignment", "left")
		match align_str:
			"left":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_LEFT
			"center":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_CENTER
			"right":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_RIGHT
	if args.has("text_color"):
		format_options["text_color"] = MCPToolUtils.coerce_color(args.get("text_color"), Color.WHITE)
	if args.has("bg_color"):
		format_options["bg_color"] = MCPToolUtils.coerce_color(args.get("bg_color"), Color.BLACK)
	if args.has("number_format"):
		format_options["number_format"] = args.get("number_format", "none")
	if args.has("wrap_text"):
		format_options["wrap_text"] = MCPToolUtils.coerce_bool(args.get("wrap_text"))

	# Apply formatting with history recording
	var formatted_count := 0
	for cell_pos in cells_to_format:
		editor.spreadsheet_editor.format_cell_with_history(cell_pos.y, cell_pos.x, format_options)
		formatted_count += 1

	return {
		"success": true,
		"cells_formatted": formatted_count,
		"message": "Formatted %d cells" % formatted_count
	}


func _set_row_height(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var rows: Array = args.get("rows", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if rows.is_empty():
		return {"error": "rows array is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	var updated_count := 0
	for row_config in rows:
		if not row_config is Dictionary:
			continue
		var row_1based: int = MCPToolUtils.coerce_int(row_config.get("row", -1), -1)
		var height: float = MCPToolUtils.coerce_float(row_config.get("height", -1.0), -1.0)
		if row_1based < 1 or height < 0:
			continue

		var row := row_1based - 1  # Convert to 0-based
		if row < 0 or row >= data.row_count:
			continue

		height = clampf(height, SpreadsheetDataScript.MIN_ROW_HEIGHT, SpreadsheetDataScript.MAX_ROW_HEIGHT)
		var old_height: float = data.get_row_height(row)
		data.set_row_height(row, height)
		if height != old_height:
			editor.spreadsheet_editor.history.record_row_resize(row, old_height, height)
		updated_count += 1

	# Trigger UI updates
	editor.spreadsheet_editor.cells_canvas.queue_redraw()
	editor.spreadsheet_editor.row_headers.queue_redraw()
	editor.spreadsheet_editor._update_scrollbar_ranges()

	return {
		"success": true,
		"rows_updated": updated_count,
		"message": "Updated height for %d rows" % updated_count
	}


func _set_column_width(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var columns: Array = args.get("columns", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if columns.is_empty():
		return {"error": "columns array is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	var updated_count := 0
	for col_config in columns:
		if not col_config is Dictionary:
			continue
		var col_str: String = str(col_config.get("column", ""))
		var width: float = MCPToolUtils.coerce_float(col_config.get("width", -1.0), -1.0)
		if col_str.is_empty() or width < 0:
			continue

		# Parse column: letter (A, B, ...) or 1-based number
		var col: int = -1
		if col_str.is_valid_int():
			col = int(col_str) - 1  # Convert 1-based to 0-based
		else:
			col = SpreadsheetDataScript.parse_column_label(col_str.to_upper())

		if col < 0 or col >= data.column_count:
			continue

		width = clampf(width, SpreadsheetDataScript.MIN_COLUMN_WIDTH, SpreadsheetDataScript.MAX_COLUMN_WIDTH)
		var old_width: float = data.get_column_width(col)
		data.set_column_width(col, width)
		if width != old_width:
			editor.spreadsheet_editor.history.record_column_resize(col, old_width, width)
		updated_count += 1

	# Trigger UI updates
	editor.spreadsheet_editor.cells_canvas.queue_redraw()
	editor.spreadsheet_editor.column_headers.queue_redraw()
	editor.spreadsheet_editor._update_scrollbar_ranges()

	return {
		"success": true,
		"columns_updated": updated_count,
		"message": "Updated width for %d columns" % updated_count
	}


func _set_cell_formula(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var cell_ref: String = args.get("cell", "")
	var formula: String = args.get("formula", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if cell_ref.is_empty():
		return {"error": "cell is required", "success": false}

	if formula.is_empty():
		return {"error": "formula is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return {"error": "No spreadsheet data available", "success": false}

	# Parse cell reference
	var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(cell_ref)
	if pos.x < 0 or pos.y < 0:
		return {"error": "Invalid cell reference: %s" % cell_ref, "success": false}

	# Ensure formula starts with =
	if not formula.begins_with("="):
		formula = "=" + formula

	# Set the formula with history recording
	editor.spreadsheet_editor.set_cell_value_with_history(pos.y, pos.x, formula)

	# Get the computed result
	var cell = data.get_cell(pos.y, pos.x)
	var result: String = cell.get_display_text()

	return {
		"success": true,
		"cell": cell_ref,
		"formula": formula,
		"result": result
	}


func _create_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var title: String = args.get("title", "Chart")
	var chart_type: String = args.get("type", "line")
	var x_range: String = args.get("x_range", "")
	var series: Array = args.get("series", [])
	var x_is_date: bool = MCPToolUtils.coerce_bool(args.get("x_is_date", false))
	var first_row_is_header: bool = MCPToolUtils.coerce_bool(args.get("first_row_is_header", true), true)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if x_range.is_empty():
		return {"error": "x_range is required", "success": false}

	if series.is_empty():
		return {"error": "series is required (array of cell ranges)", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	# Create the chart
	var chart := SpreadsheetChartScript.new()
	chart.title = title
	chart.type = SpreadsheetChartScript.ChartType.LINE if chart_type == "line" else SpreadsheetChartScript.ChartType.BAR
	chart.x_range = x_range
	chart.x_is_date = x_is_date
	chart.first_row_is_header = first_row_is_header

	# Add series
	for series_range in series:
		if series_range is String:
			chart.add_series(series_range)

	# Add the chart
	editor.spreadsheet_editor.add_chart(chart)

	return {
		"success": true,
		"chart_id": chart.id,
		"chart_count": editor.spreadsheet_editor.charts.size(),
		"message": "Chart created successfully"
	}


func _get_chart_image(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_index: int = MCPToolUtils.coerce_int(args.get("chart_index", 0), 0)
	var width: int = MCPToolUtils.coerce_int(args.get("width", 800), 800)
	var height: int = MCPToolUtils.coerce_int(args.get("height", 400), 400)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var charts = editor.spreadsheet_editor.charts
	if chart_index < 0 or chart_index >= charts.size():
		return {"error": "Chart index out of range (have %d charts)" % charts.size(), "success": false}

	var chart_canvas = editor.spreadsheet_editor._chart_canvas
	if not chart_canvas:
		return {"error": "Chart canvas not available", "success": false}

	# Make sure the chart canvas has the right chart selected
	var target_chart = charts[chart_index]
	chart_canvas.set_chart(target_chart)
	chart_canvas.update_from_spreadsheet(editor.spreadsheet_editor.spreadsheet_data)

	# Capture the chart as base64 PNG
	var base64_png: String = await chart_canvas.capture_to_base64_png(width, height)

	if base64_png.is_empty():
		return {"error": "Failed to capture chart image", "success": false}

	return {
		"success": true,
		"chart_index": chart_index,
		"chart_title": target_chart.title,
		"width": width,
		"height": height,
		"format": "png",
		"encoding": "base64",
		"image_data": base64_png
	}


func _list_charts(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var charts_info: Array = []
	for i in range(editor.spreadsheet_editor.charts.size()):
		var chart = editor.spreadsheet_editor.charts[i]
		var series_info: Array = []
		for s in chart.series:
			series_info.append({
				"range": s.get("range", ""),
				"name": s.get("name", "")
			})

		charts_info.append({
			"index": i,
			"id": chart.id,
			"title": chart.title,
			"type": "line" if chart.type == SpreadsheetChartScript.ChartType.LINE else "bar",
			"x_range": chart.x_range,
			"x_is_date": chart.x_is_date,
			"first_row_is_header": chart.first_row_is_header,
			"series": series_info
		})

	return {
		"success": true,
		"chart_count": charts_info.size(),
		"charts": charts_info
	}


func _update_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_id: String = args.get("chart_id", "")
	var chart_index: int = MCPToolUtils.coerce_int(args.get("chart_index", -1), -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	# Find chart by ID or index
	var target_index: int = -1
	if not chart_id.is_empty():
		target_index = editor.spreadsheet_editor.get_chart_index(chart_id)
	elif chart_index >= 0:
		target_index = chart_index

	if target_index < 0 or target_index >= editor.spreadsheet_editor.charts.size():
		return {"error": "Chart not found. Provide valid chart_id or chart_index.", "success": false}

	# Build properties dictionary from args
	var properties: Dictionary = {}
	if args.has("title"):
		properties["title"] = args["title"]
	if args.has("type"):
		properties["type"] = args["type"]
	if args.has("x_range"):
		properties["x_range"] = args["x_range"]
	if args.has("series"):
		properties["series"] = args["series"]
	if args.has("x_is_date"):
		properties["x_is_date"] = MCPToolUtils.coerce_bool(args["x_is_date"])
	if args.has("first_row_is_header"):
		properties["first_row_is_header"] = MCPToolUtils.coerce_bool(args["first_row_is_header"])
	if args.has("x_axis_label"):
		properties["x_axis_label"] = args["x_axis_label"]
	if args.has("y_axis_label"):
		properties["y_axis_label"] = args["y_axis_label"]
	if args.has("show_legend"):
		properties["show_legend"] = MCPToolUtils.coerce_bool(args["show_legend"])
	if args.has("y_auto_scale"):
		properties["y_auto_scale"] = MCPToolUtils.coerce_bool(args["y_auto_scale"])
	if args.has("y_min"):
		properties["y_min"] = MCPToolUtils.coerce_float(args["y_min"])
	if args.has("y_max"):
		properties["y_max"] = MCPToolUtils.coerce_float(args["y_max"])

	if properties.is_empty():
		return {"error": "No properties to update. Provide at least one property.", "success": false}

	# Update the chart
	var success: bool = editor.spreadsheet_editor.update_chart_properties(target_index, properties)

	if not success:
		return {"error": "Failed to update chart", "success": false}

	var chart = editor.spreadsheet_editor.charts[target_index]
	return {
		"success": true,
		"chart_id": chart.id,
		"chart_index": target_index,
		"updated_properties": properties.keys(),
		"message": "Chart updated successfully"
	}


func _delete_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_id: String = args.get("chart_id", "")
	var chart_index: int = MCPToolUtils.coerce_int(args.get("chart_index", -1), -1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	# Find chart by ID or index
	var target_index: int = -1
	if not chart_id.is_empty():
		target_index = editor.spreadsheet_editor.get_chart_index(chart_id)
	elif chart_index >= 0:
		target_index = chart_index

	if target_index < 0 or target_index >= editor.spreadsheet_editor.charts.size():
		return {"error": "Chart not found. Provide valid chart_id or chart_index.", "success": false}

	var deleted_id: String = editor.spreadsheet_editor.charts[target_index].id
	editor.spreadsheet_editor.remove_chart(target_index)

	return {
		"success": true,
		"deleted_chart_id": deleted_id,
		"remaining_charts": editor.spreadsheet_editor.charts.size(),
		"message": "Chart deleted successfully"
	}


func _refresh_charts(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	editor.spreadsheet_editor._update_all_charts()

	return {
		"success": true,
		"charts_refreshed": editor.spreadsheet_editor.charts.size(),
		"message": "All charts refreshed"
	}


func _link_spreadsheet_to_note(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var note_title: String = args.get("note_title", "")
	var thread_name: String = args.get("thread_name", "Spreadsheets")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	# Use spreadsheet name as note title if not provided
	if note_title.is_empty():
		note_title = editor_name

	# Get markdown content from spreadsheet
	var data = editor.spreadsheet_editor.spreadsheet_data
	var markdown_content: String = data.to_markdown()

	# Create the linked note
	var note = NoteScript.create_spreadsheet_note(note_title, editor_name, markdown_content)

	# Find or create the notes thread
	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return {"error": "Notes container not available", "success": false}

	var thread_vbox = notes_container.find_or_create_tab(thread_name)
	thread_vbox.add_note(note)

	return {
		"success": true,
		"note_uuid": note.uuid,
		"note_title": note_title,
		"thread_name": thread_name,
		"linked_spreadsheet": editor_name,
		"message": "Created linked note '%s' in thread '%s'. Edit button opens spreadsheet." % [note_title, thread_name]
	}


func _export_to_nudge(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component: String = args.get("component", "")
	var key: String = args.get("key", "")
	var format_: String = args.get("format", "summary")
	var include_charts: bool = MCPToolUtils.coerce_bool(args.get("include_charts", false))

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if component.is_empty():
		return {"error": "component is required", "success": false}

	if key.is_empty():
		return {"error": "key is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var data = editor.spreadsheet_editor.spreadsheet_data

	# Build the export value based on format
	var export_value: Variant

	match format_:
		"raw":
			export_value = _export_raw(data)
		"summary":
			export_value = _export_summary(data, editor.spreadsheet_editor)
		"schema":
			export_value = _export_schema(data)
		"timeseries":
			export_value = _export_timeseries(data)
		"kv_pairs":
			export_value = _export_kv_pairs(data)
		_:
			export_value = _export_summary(data, editor.spreadsheet_editor)

	# Add chart info if requested
	if include_charts and editor.spreadsheet_editor.charts.size() > 0:
		var charts_info: Array = []
		for chart in editor.spreadsheet_editor.charts:
			charts_info.append({
				"id": chart.id,
				"title": chart.title,
				"type": "line" if chart.type == SpreadsheetChartScript.ChartType.LINE else "bar",
				"x_range": chart.x_range,
				"series_count": chart.series.size()
			})
		if export_value is Dictionary:
			export_value["charts"] = charts_info

	# Call Nudge MCP to set the hint
	var nudge_result: Dictionary = await _call_nudge_set_hint(component, key, export_value)

	if nudge_result.has("error"):
		return {"error": "Nudge export failed: %s" % nudge_result.get("error", "Unknown error"), "success": false}

	return {
		"success": true,
		"component": component,
		"key": key,
		"format": format_,
		"message": "Exported spreadsheet data to Nudge as %s/%s" % [component, key]
	}


## Undo the last action(s) in a spreadsheet
func _undo_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var count: int = MCPToolUtils.coerce_int(args.get("count", 1), 1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor

	if not spreadsheet.can_undo():
		return {
			"success": false,
			"message": "Nothing to undo",
			"undo_count": 0,
			"redo_count": spreadsheet.get_redo_count()
		}

	var undone := 0
	for i in range(count):
		if spreadsheet.undo():
			undone += 1
		else:
			break

	return {
		"success": true,
		"undone_count": undone,
		"remaining_undo_count": spreadsheet.get_undo_count(),
		"redo_count": spreadsheet.get_redo_count(),
		"message": "Undid %d action(s)" % undone
	}


## Redo a previously undone action in a spreadsheet
func _redo_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var count: int = MCPToolUtils.coerce_int(args.get("count", 1), 1)

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor

	if not spreadsheet.can_redo():
		return {
			"success": false,
			"message": "Nothing to redo",
			"undo_count": spreadsheet.get_undo_count(),
			"redo_count": 0
		}

	var redone := 0
	for i in range(count):
		if spreadsheet.redo():
			redone += 1
		else:
			break

	return {
		"success": true,
		"redone_count": redone,
		"undo_count": spreadsheet.get_undo_count(),
		"remaining_redo_count": spreadsheet.get_redo_count(),
		"message": "Redid %d action(s)" % redone
	}


## Get the undo/redo history status of a spreadsheet
func _get_spreadsheet_history(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor

	return {
		"success": true,
		"can_undo": spreadsheet.can_undo(),
		"can_redo": spreadsheet.can_redo(),
		"undo_count": spreadsheet.get_undo_count(),
		"redo_count": spreadsheet.get_redo_count()
	}


## Fill down formulas/values from source row to target rows
func _fill_down_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var source_row: int = MCPToolUtils.coerce_int(args.get("source_row", 0), 0)
	var target_rows: Array = args.get("target_rows", [])
	var columns: Array = args.get("columns", [])

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	if source_row < 1:
		return {"error": "source_row must be >= 1 (1-based row number)", "success": false}

	if target_rows.is_empty():
		return {"error": "target_rows array is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor
	var data = spreadsheet.spreadsheet_data

	# Convert 1-based to 0-based
	var source_row_idx: int = source_row - 1

	# Determine columns to fill
	var col_indices: Array[int] = []
	if columns.is_empty():
		# Fill all columns that have data in source row
		for col in range(data.column_count):
			var cell = data.get_cell_if_exists(source_row_idx, col)
			if cell and not cell.is_empty():
				col_indices.append(col)
	else:
		# Parse column letters to indices
		for col_letter in columns:
			var col_idx: int = SpreadsheetDataScript.parse_column_label(str(col_letter).to_upper())
			if col_idx >= 0:
				col_indices.append(col_idx)

	if col_indices.is_empty():
		return {"error": "No columns to fill (source row is empty or columns not found)", "success": false}

	# Capture old cells for history
	var old_cells: Dictionary = {}
	var new_cells: Dictionary = {}
	var filled_count: int = 0

	# Fill each target row
	for target_row in target_rows:
		var target_row_idx: int = int(target_row) - 1  # Convert to 0-based
		if target_row_idx < 0 or target_row_idx == source_row_idx:
			continue

		var row_offset: int = target_row_idx - source_row_idx

		for col in col_indices:
			var source_cell = data.get_cell_if_exists(source_row_idx, col)
			if not source_cell:
				continue

			var key := SpreadsheetDataScript.cell_key(target_row_idx, col)

			# Capture old value
			var old_cell = data.get_cell_if_exists(target_row_idx, col)
			if old_cell:
				old_cells[key] = old_cell.to_dict()
			else:
				old_cells[key] = {}

			# Determine what to set
			if source_cell.has_formula():
				# Adjust the formula's row references
				var adjusted_formula: String = spreadsheet._adjust_formula_row_refs(source_cell.formula, row_offset)
				data.set_cell_value(target_row_idx, col, adjusted_formula)
			else:
				# Just copy the value (no adjustment needed)
				data.set_cell_value(target_row_idx, col, source_cell.value)

			# Capture new value
			var new_cell = data.get_cell_if_exists(target_row_idx, col)
			if new_cell:
				new_cells[key] = new_cell.to_dict()
			filled_count += 1

	# Record in history
	if not new_cells.is_empty():
		spreadsheet.history.record_range_edit(source_row_idx + 1, col_indices[0], old_cells, new_cells)

	spreadsheet.cells_canvas.queue_redraw()
	spreadsheet.content_changed.emit()

	# Build column letters for response
	var col_letters: Array[String] = []
	for col in col_indices:
		col_letters.append(SpreadsheetDataScript.get_column_label(col))

	return {
		"success": true,
		"filled_cells": filled_count,
		"source_row": source_row,
		"target_rows": target_rows,
		"columns": col_letters,
		"message": "Filled %d cells from row %d to rows %s in columns %s" % [filled_count, source_row, str(target_rows), ", ".join(col_letters)]
	}


## Recalculate all formulas in a spreadsheet
func _recalculate_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return {"error": "editor_name is required", "success": false}

	var editor = _find_spreadsheet_editor(editor_name)
	if not editor:
		return {"error": "Spreadsheet editor not found: %s" % editor_name, "success": false}

	if not editor.spreadsheet_editor:
		return {"error": "Spreadsheet editor not initialized", "success": false}

	var spreadsheet = editor.spreadsheet_editor
	spreadsheet._recalculate_all()

	return {
		"success": true,
		"message": "Recalculated all formulas in %s" % editor_name
	}

#endregion
