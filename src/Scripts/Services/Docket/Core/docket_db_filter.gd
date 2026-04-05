extends RefCounted
class_name DocketDBFilter
## SQL filter/sort translation for Docket queries.
## Pure functions: take filter dicts, return {where: String, bindings: Array}.
## Extracted verbatim from DocketDB to keep the query engine logic separate.


static func translate_filter(filter: Dictionary) -> Dictionary:
	var conditions := PackedStringArray()
	var bindings: Array = []

	for key in filter:
		var value = filter[key]

		if key == "tags_contains":
			conditions.append("EXISTS (SELECT 1 FROM item_tags WHERE item_tags.item_id=items.id AND item_tags.tag=?)")
			bindings.append(str(value))
		elif key.ends_with("__ne"):
			var field: String = key.substr(0, key.length() - 4)
			conditions.append("%s!=?" % field)
			bindings.append(value)
		elif key.ends_with("__in"):
			var field: String = key.substr(0, key.length() - 4)
			if value is Array and value.size() > 0:
				var placeholders := PackedStringArray()
				for v in value:
					placeholders.append("?")
					bindings.append(v)
				conditions.append("%s IN (%s)" % [field, ",".join(placeholders)])
			else:
				conditions.append("0")  # empty __in matches nothing
		else:
			conditions.append("%s=?" % key)
			bindings.append(value)

	return {
		"where": " AND ".join(conditions) if conditions.size() > 0 else "",
		"bindings": bindings,
	}


## Translate a flat conditions list (GUI format) to SQL.
## AND binds tighter than OR — consecutive AND conditions form groups separated by OR.
static func translate_conditions(conditions: Array) -> Dictionary:
	if conditions.is_empty():
		return {"where": "", "bindings": []}

	# Group conditions by OR boundaries. AND binds tighter than OR.
	var groups: Array = []  # Array of Array[Dictionary]
	var current_group: Array = []

	for i in conditions.size():
		var cond: Dictionary = conditions[i]
		if i == 0:
			current_group.append(cond)
		else:
			var conj: String = str(cond.get("conj", "and")).to_lower()
			if conj == "or":
				groups.append(current_group)
				current_group = [cond]
			else:
				current_group.append(cond)
	groups.append(current_group)

	var or_parts := PackedStringArray()
	var all_bindings: Array = []

	for group in groups:
		var and_parts := PackedStringArray()
		for cond in group:
			var translated := _condition_to_sql(cond)
			var sql_str: String = translated["sql"]
			if not sql_str.is_empty():
				and_parts.append(sql_str)
				all_bindings.append_array(translated["bindings"])
		if and_parts.size() > 0:
			if and_parts.size() == 1:
				or_parts.append(and_parts[0])
			else:
				or_parts.append("(%s)" % " AND ".join(and_parts))

	var where: String
	if or_parts.size() == 0:
		where = ""
	elif or_parts.size() == 1:
		where = or_parts[0]
	else:
		where = "(%s)" % " OR ".join(or_parts)

	return {"where": where, "bindings": all_bindings}


## Translate a nested $and/$or boolean tree to SQL.
static func translate_tree(tree: Dictionary) -> Dictionary:
	if tree.has("$or"):
		var parts := PackedStringArray()
		var bindings: Array = []
		for child in tree["$or"]:
			var t: Dictionary
			if child is Dictionary and (child.has("$or") or child.has("$and")):
				t = translate_tree(child)
			else:
				t = _condition_to_sql(child)
			var sql_str: String = t.get("sql", t.get("where", ""))
			if not sql_str.is_empty():
				parts.append(sql_str)
				bindings.append_array(t["bindings"])
		if parts.size() == 0:
			return {"where": "", "bindings": []}
		if parts.size() == 1:
			return {"where": parts[0], "bindings": bindings}
		return {"where": "(%s)" % " OR ".join(parts), "bindings": bindings}

	elif tree.has("$and"):
		var parts := PackedStringArray()
		var bindings: Array = []
		for child in tree["$and"]:
			var t: Dictionary
			if child is Dictionary and (child.has("$or") or child.has("$and")):
				t = translate_tree(child)
			else:
				t = _condition_to_sql(child)
			var sql_str: String = t.get("sql", t.get("where", ""))
			if not sql_str.is_empty():
				parts.append(sql_str)
				bindings.append_array(t["bindings"])
		if parts.size() == 0:
			return {"where": "", "bindings": []}
		if parts.size() == 1:
			return {"where": parts[0], "bindings": bindings}
		return {"where": "(%s)" % " AND ".join(parts), "bindings": bindings}

	else:
		# Single condition at tree root
		var c := _condition_to_sql(tree)
		return {"where": c["sql"], "bindings": c["bindings"]}


## Translate a single condition dict to SQL fragment + bindings.
static func _condition_to_sql(cond: Dictionary) -> Dictionary:
	var field: String = str(cond.get("field", ""))
	var op: String = str(cond.get("op", "eq"))
	var value = cond.get("value")

	# Pseudo-field: has_attachment
	if field == "has_attachment":
		var sub := "EXISTS (SELECT 1 FROM attachments WHERE attachments.item_id=items.id)"
		var is_true: bool = (value is bool and value) or (value is int and value == 1) or (value is float and value == 1.0) or str(value).to_lower() == "true"
		if is_true:
			return {"sql": sub, "bindings": []}
		else:
			return {"sql": "NOT %s" % sub, "bindings": []}

	# Pseudo-field: tags
	if field == "tags":
		if op == "eq":
			return {
				"sql": "EXISTS (SELECT 1 FROM item_tags WHERE item_tags.item_id=items.id AND item_tags.tag=?)",
				"bindings": [str(value)],
			}
		elif op == "neq":
			return {
				"sql": "NOT EXISTS (SELECT 1 FROM item_tags WHERE item_tags.item_id=items.id AND item_tags.tag=?)",
				"bindings": [str(value)],
			}
		elif op == "contains":
			return {
				"sql": "EXISTS (SELECT 1 FROM item_tags WHERE item_tags.item_id=items.id AND item_tags.tag LIKE '%' || ? || '%')",
				"bindings": [str(value)],
			}
		elif op == "not_contains":
			return {
				"sql": "NOT EXISTS (SELECT 1 FROM item_tags WHERE item_tags.item_id=items.id AND item_tags.tag LIKE '%' || ? || '%')",
				"bindings": [str(value)],
			}
		return {"sql": "", "bindings": []}

	# Parent field: match both bare ID and qualified "project:ID" patterns
	if field == "parent" and op == "eq" and value is String:
		var val_str: String = value
		if val_str.contains(":"):
			# Qualified ref: match exact
			return {"sql": "parent=?", "bindings": [val_str]}
		else:
			# Bare ID: match bare OR any qualified form ending with ":ID"
			return {"sql": "(parent=? OR parent LIKE '%' || ':' || ?)", "bindings": [val_str, val_str]}

	# ID field with short hex prefix: use LIKE prefix matching
	if field == "id" and op == "eq" and value is String:
		var val_str: String = value
		if not val_str.is_empty() and val_str.length() < 32 and val_str.is_valid_hex_number(false):
			return {"sql": "id LIKE ? || '%'", "bindings": [val_str]}

	# Standard operators
	match op:
		"eq":
			return {"sql": "%s=?" % field, "bindings": [value]}
		"neq":
			return {"sql": "%s!=?" % field, "bindings": [value]}
		"contains":
			return {"sql": "%s LIKE '%%' || ? || '%%'" % field, "bindings": [str(value)]}
		"not_contains":
			return {"sql": "%s NOT LIKE '%%' || ? || '%%'" % field, "bindings": [str(value)]}
		"like":
			var pattern := _translate_wildcards(str(value))
			return {"sql": "%s LIKE ? ESCAPE '\\'" % field, "bindings": [pattern]}
		"gt", "after":
			return {"sql": "%s>?" % field, "bindings": [value]}
		"lt", "before":
			return {"sql": "%s<?" % field, "bindings": [value]}
		"gte":
			return {"sql": "%s>=?" % field, "bindings": [value]}
		"lte":
			return {"sql": "%s<=?" % field, "bindings": [value]}
		"is_empty":
			return {"sql": "(%s IS NULL OR %s='')" % [field, field], "bindings": []}
		"is_not_empty":
			return {"sql": "(%s IS NOT NULL AND %s!='')" % [field, field], "bindings": []}

	return {"sql": "", "bindings": []}


## Translate human-friendly wildcards to SQL LIKE pattern.
## '.' → '_' (single char), '*' → '%' (any), literal '%' and '_' are escaped.
static func _translate_wildcards(pattern: String) -> String:
	var result := ""
	for i in pattern.length():
		var c := pattern[i]
		match c:
			".":
				result += "_"
			"*":
				result += "%"
			"%":
				result += "\\%"
			"_":
				result += "\\_"
			"\\":
				result += "\\\\"
			_:
				result += c
	return result
