class_name SpreadsheetFileHandler
extends RefCounted
## Handles file import/export for spreadsheets (CSV, TSV, native format).

const SpreadsheetDataScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd")
const ExcelHandlerScript := preload("res://Scripts/UI/Controls/SpreadsheetEditor/ExcelHandler.gd")


## Import CSV file into SpreadsheetData
static func import_csv(path: String, data: SpreadsheetDataScript) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return FileAccess.get_open_error()

	var content := file.get_as_text()
	file.close()

	data.from_csv(content, ",")
	return OK


## Export SpreadsheetData to CSV file
static func export_csv(path: String, data: SpreadsheetDataScript) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()

	var content := data.to_csv(",")
	file.store_string(content)
	file.close()
	return OK


## Import TSV file into SpreadsheetData
static func import_tsv(path: String, data: SpreadsheetDataScript) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return FileAccess.get_open_error()

	var content := file.get_as_text()
	file.close()

	data.from_csv(content, "\t")
	return OK


## Export SpreadsheetData to TSV file
static func export_tsv(path: String, data: SpreadsheetDataScript) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()

	var content := data.to_csv("\t")
	file.store_string(content)
	file.close()
	return OK


## Import native JSON format (.minsheet)
static func import_minsheet(path: String, data: SpreadsheetDataScript) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return FileAccess.get_open_error()

	var content := file.get_as_text()
	file.close()

	var json := JSON.new()
	var parse_result := json.parse(content)
	if parse_result != OK:
		return parse_result

	var dict: Variant = json.data
	if not dict is Dictionary:
		return ERR_INVALID_DATA

	data.load_from_dict(dict)
	return OK


## Export SpreadsheetData to native JSON format (.minsheet)
static func export_minsheet(path: String, data: SpreadsheetDataScript) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()

	var dict := data.to_dict()
	var content := JSON.stringify(dict, "\t")
	file.store_string(content)
	file.close()
	return OK


## Detect file type from extension and import
static func import_file(path: String, data: SpreadsheetDataScript) -> Error:
	var ext := path.get_extension().to_lower()

	match ext:
		"csv":
			return import_csv(path, data)
		"tsv":
			return import_tsv(path, data)
		"minsheet":
			return import_minsheet(path, data)
		"xlsx":
			return ExcelHandlerScript.import_xlsx(path, data)
		_:
			# Try CSV as default
			return import_csv(path, data)


## Detect file type from extension and export
static func export_file(path: String, data: SpreadsheetDataScript) -> Error:
	var ext := path.get_extension().to_lower()

	match ext:
		"csv":
			return export_csv(path, data)
		"tsv":
			return export_tsv(path, data)
		"minsheet":
			return export_minsheet(path, data)
		"xlsx":
			return ExcelHandlerScript.export_xlsx(path, data)
		_:
			# Default to CSV
			return export_csv(path, data)


## Get supported import file filters for FileDialog
static func get_import_filters() -> PackedStringArray:
	return PackedStringArray([
		"*.csv ; CSV Files",
		"*.tsv ; TSV Files",
		"*.xlsx ; Excel Files",
		"*.minsheet ; Minerva Spreadsheet",
	])


## Get supported export file filters for FileDialog
static func get_export_filters() -> PackedStringArray:
	return PackedStringArray([
		"*.csv ; CSV Files",
		"*.tsv ; TSV Files",
		"*.xlsx ; Excel Files",
		"*.minsheet ; Minerva Spreadsheet",
	])
