extends RefCounted
class_name DocketErrorReport
## MCP tool: report on all MCP tool errors aggregated by frequency.
## Covers every tool — update rejections, missing items, invalid transitions, etc.


func get_definition() -> Dictionary:
	return {
		"name": "docket_error_report",
		"description": "Report all MCP tool errors aggregated by (tool_name, error_message), sorted by frequency. Use to identify UX gaps and common agent mistakes.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(_args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var report := db.get_error_report()
	return {"errors": report, "total_patterns": report.size()}
