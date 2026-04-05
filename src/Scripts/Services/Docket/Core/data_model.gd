extends RefCounted
class_name DataModel
## Factory and validation for Docket work items (Dictionary-based).


static func create_item(schema: Dictionary, type: String, fields: Dictionary) -> Dictionary:
	if not schema.types.has(type):
		return {"error": "Unknown type: %s" % type}

	var type_def: Dictionary = schema.types[type]

	# Check required fields
	for req_field in type_def.required_fields:
		if not fields.has(req_field):
			return {"error": "Missing required field '%s' for type '%s'" % [req_field, type]}

	var now := Time.get_datetime_string_from_system(true)

	var item := {
		"type": type,
		"status": type_def.initial_state,
		"title": fields.get("title", ""),
		"description": fields.get("description", ""),
		"created_at": now,
		"updated_at": now,
		"created_by": fields.get("created_by", ""),
		"assigned_to": fields.get("assigned_to", ""),
		"directed_to": fields.get("directed_to", ""),
		"priority": int(fields.get("priority", 0)),
		"severity": int(fields.get("severity", 0)),
		"tags": fields.get("tags", []).duplicate(),
		"links": [],
		"events": [],
		"parent": fields.get("parent", ""),
	}

	# Copy type-specific optional fields
	var all_fields: Array = type_def.required_fields.duplicate()
	all_fields.append_array(type_def.optional_fields)
	for field_name in all_fields:
		if fields.has(field_name) and not item.has(field_name):
			item[field_name] = fields[field_name]

	# Add creation event
	add_event(item, "created", fields.get("created_by", ""), "Item created")

	return item


static func update_item(schema: Dictionary, item: Dictionary, changes: Dictionary) -> Dictionary:
	var type: String = item.type
	if not schema.types.has(type):
		return {"error": "Unknown type: %s" % type}

	var type_def: Dictionary = schema.types[type]
	var allowed_fields: Array = []
	allowed_fields.append_array(type_def.required_fields)
	allowed_fields.append_array(type_def.optional_fields)
	# Common mutable fields always allowed
	var common_mutable := ["title", "description", "assigned_to", "directed_to", "priority", "severity", "tags", "parent"]
	for f in common_mutable:
		if not allowed_fields.has(f):
			allowed_fields.append(f)

	# Don't allow changing type, status, id, events, links, timestamps via update
	var protected := ["type", "status", "id", "events", "links", "created_at", "updated_at"]

	for key in changes:
		if protected.has(key):
			continue
		if not allowed_fields.has(key):
			return {"error": "Field '%s' not valid for type '%s'" % [key, type]}
		var val = changes[key]
		if key in ["priority", "severity", "retrieval_count", "research_cost", "quality"]:
			val = int(val)
		item[key] = val

	item.updated_at = Time.get_datetime_string_from_system(true)
	return {}


static func build_write_back(item: Dictionary, changes: Dictionary) -> Dictionary:
	## Build a dict of changed fields suitable for DocketDB.update_item_fields().
	## Filters out system fields that shouldn't be written directly.
	const SKIP := ["type", "status", "id", "events", "links", "created_at"]
	var wb := {}
	for key in changes:
		if key in SKIP:
			continue
		if item.has(key):
			wb[key] = item[key]
	wb["updated_at"] = item.get("updated_at", "")
	return wb


static func add_event(item: Dictionary, event_type: String, actor: String, note: String = "") -> void:
	var event := {
		"event_type": event_type,
		"actor": actor,
		"timestamp": Time.get_datetime_string_from_system(true),
		"note": note,
	}
	item.events.append(event)
	item.updated_at = event.timestamp
