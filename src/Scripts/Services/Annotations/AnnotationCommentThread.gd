class_name AnnotationCommentThread
extends RefCounted
## Canonical, backward-compatible operations for text_comment reply threads.
## The root comment remains kind_payload.text; replies are append-only records
## under kind_payload.replies unless explicitly edited or deleted by stable id.

const MAX_TEXT_BYTES := 64 * 1024


static func replies(annotation: Dictionary) -> Array:
	var payload: Variant = annotation.get("kind_payload", {})
	if not payload is Dictionary:
		return []
	var raw: Variant = (payload as Dictionary).get("replies", [])
	if not raw is Array:
		return []
	var out: Array = []
	for value in (raw as Array):
		if value is Dictionary:
			out.append((value as Dictionary).duplicate(true))
	return out


static func add_reply(annotation: Dictionary, text: String, author: Dictionary,
		parent_id: String = "") -> Dictionary:
	var clean := text.strip_edges()
	var error := _validate_text(clean)
	if not error.is_empty():
		return {"ok": false, "error": error}
	if str(annotation.get("kind", "")) != "text_comment":
		return {"ok": false, "error": "annotation is not a text comment"}
	var existing := replies(annotation)
	var resolved_parent := parent_id if not parent_id.is_empty() else str(annotation.get("id", "root"))
	if not _contains_message(annotation, existing, resolved_parent):
		return {"ok": false, "error": "parent reply not found: %s" % resolved_parent}
	var reply_id := _new_reply_id(existing)
	var now := int(Time.get_unix_time_from_system())
	var reply := {
		"id": reply_id,
		"parent_id": resolved_parent,
		"text": clean,
		"author": _normalized_author(author),
		"created_at": now,
		"updated_at": now,
	}
	existing.append(reply)
	var updated := _with_replies(annotation, existing)
	# Replying is active discussion. A resolved thread reopens without losing
	# its prior resolution record, which remains useful history in the sidecar.
	if str(updated.get("lifecycle", "open")) == "resolved":
		updated["lifecycle"] = "open"
	updated["updated_at"] = now
	return {"ok": true, "annotation": updated, "reply": reply}


static func edit_reply(annotation: Dictionary, reply_id: String, text: String) -> Dictionary:
	var clean := text.strip_edges()
	var error := _validate_text(clean)
	if not error.is_empty():
		return {"ok": false, "error": error}
	var existing := replies(annotation)
	for i in range(existing.size()):
		var reply: Dictionary = existing[i]
		if str(reply.get("id", "")) != reply_id:
			continue
		reply["text"] = clean
		reply["updated_at"] = int(Time.get_unix_time_from_system())
		existing[i] = reply
		var updated := _with_replies(annotation, existing)
		updated["updated_at"] = reply["updated_at"]
		return {"ok": true, "annotation": updated, "reply": reply}
	return {"ok": false, "error": "reply not found: %s" % reply_id}


static func delete_reply(annotation: Dictionary, reply_id: String) -> Dictionary:
	var existing := replies(annotation)
	for i in range(existing.size()):
		if str((existing[i] as Dictionary).get("id", "")) != reply_id:
			continue
		# Children retain parent_id as durable conversation provenance even after
		# their parent is removed; rendering remains chronological and unbroken.
		existing.remove_at(i)
		var updated := _with_replies(annotation, existing)
		updated["updated_at"] = int(Time.get_unix_time_from_system())
		return {"ok": true, "annotation": updated}
	return {"ok": false, "error": "reply not found: %s" % reply_id}


static func export_text(annotation: Dictionary) -> String:
	var payload: Variant = annotation.get("kind_payload", {})
	var parts := PackedStringArray()
	if payload is Dictionary:
		var root := str((payload as Dictionary).get("text", "")).strip_edges()
		if not root.is_empty():
			parts.append(root)
	for reply in replies(annotation):
		var body := str((reply as Dictionary).get("text", "")).strip_edges()
		if not body.is_empty():
			parts.append(body)
	return "\n\n".join(parts)


static func _with_replies(annotation: Dictionary, values: Array) -> Dictionary:
	var updated := annotation.duplicate(true)
	var payload_v: Variant = updated.get("kind_payload", {})
	var payload: Dictionary = (payload_v as Dictionary).duplicate(true) if payload_v is Dictionary else {}
	if values.is_empty():
		payload.erase("replies")
	else:
		payload["replies"] = values
	updated["kind_payload"] = payload
	return updated


static func _contains_message(annotation: Dictionary, values: Array, message_id: String) -> bool:
	if message_id == str(annotation.get("id", "")) or message_id == "root":
		return true
	for reply in values:
		if str((reply as Dictionary).get("id", "")) == message_id:
			return true
	return false


static func _new_reply_id(existing: Array) -> String:
	var used := {}
	for reply in existing:
		used[str((reply as Dictionary).get("id", ""))] = true
	var reply_token := "%x_%08x" % [Time.get_ticks_usec(), randi()]
	var candidate := "reply_%s" % reply_token
	var suffix := 1
	while used.has(candidate):
		candidate = "reply_%s_%d" % [reply_token, suffix]
		suffix += 1
	return candidate


static func _normalized_author(author: Dictionary) -> Dictionary:
	var kind := str(author.get("kind", "human"))
	if kind != "ai":
		kind = "human"
	var out := {"kind": kind}
	var author_id := str(author.get("id", "")).strip_edges()
	if not author_id.is_empty():
		out["id"] = author_id
	return out


static func _validate_text(text: String) -> String:
	if text.is_empty():
		return "reply text is required"
	if text.to_utf8_buffer().size() > MAX_TEXT_BYTES:
		return "reply text exceeds 64 KiB"
	return ""
