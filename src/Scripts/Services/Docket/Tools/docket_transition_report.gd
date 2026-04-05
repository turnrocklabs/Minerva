extends RefCounted
class_name DocketTransitionReport
## MCP tool: report on failed state transition attempts.
## Aggregates transition_log data to show which transitions agents reach for
## that don't exist, sorted by frequency. Used to inform state machine redesign.


func get_definition() -> Dictionary:
	return {
		"name": "docket_transition_report",
		"description": "Report failed state transition attempts aggregated by (item_type, from_state, attempted_to), sorted by frequency. Use to identify state machine design gaps.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(_args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var report := db.get_transition_report()
	return {"failures": report, "total_failures": report.size()}
