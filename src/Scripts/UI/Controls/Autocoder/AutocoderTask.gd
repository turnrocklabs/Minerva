class_name AutocoderTask
extends Resource

enum TaskStatus {
	PLAN,
	IN_PROGRESS,
	AI_REVIEW,
	HUMAN_REVIEW,
	DONE
}

enum SourceType {
	AUTOCODER,    ## Created by autocoder planning mode
	AGENT_TOOL,   ## Created by agent MCP tool
	USER_CHAT,    ## Converted from chat message
	USER_NOTE,    ## Converted from note
	USER_MANUAL,  ## Manually created by user
}

@export var id: String
@export var title: String
@export var description: String
@export var status: TaskStatus = TaskStatus.PLAN
@export var priority: int = 2  ## 1=highest, 5=lowest
@export var version: int = 1
@export var assigned_model: String = ""
@export var created_at: String = ""
@export var updated_at: String = ""
@export var related_files: Array[String] = []
@export var metadata: Dictionary = {}
## Notes attached to this task (each: {uuid, title, relation, attached_at})
@export var note_links: Array[Dictionary] = []

## Source tracking - client side only
@export var source_type: SourceType = SourceType.USER_MANUAL
@export var source_uuid: String = ""  ## UUID of note, chat message, etc.
@export var source_context: String = ""  ## Additional context (chat name, agent name, etc.)

## Image references (UUIDs to shared image store - future)
@export var image_ids: PackedStringArray = []


func _init(
	p_id: String = "",
	p_title: String = "",
	p_description: String = "",
	p_status: TaskStatus = TaskStatus.PLAN,
	p_model: String = "",
	p_priority: int = 2
):
	id = p_id
	title = p_title
	description = p_description
	status = p_status
	assigned_model = p_model
	priority = p_priority
	created_at = Time.get_datetime_string_from_system()
	updated_at = created_at


func get_status_name() -> String:
	match status:
		TaskStatus.PLAN:
			return "Plan"
		TaskStatus.IN_PROGRESS:
			return "In Progress"
		TaskStatus.AI_REVIEW:
			return "AI Review"
		TaskStatus.HUMAN_REVIEW:
			return "Human Review"
		TaskStatus.DONE:
			return "Done"
		_:
			return "Unknown"


func get_source_type_name() -> String:
	match source_type:
		SourceType.AUTOCODER:
			return "Autocoder"
		SourceType.AGENT_TOOL:
			return "Agent"
		SourceType.USER_CHAT:
			return "Chat"
		SourceType.USER_NOTE:
			return "Note"
		SourceType.USER_MANUAL:
			return "Manual"
		_:
			return "Unknown"


func get_primary_note_uuid() -> String:
	if note_links.is_empty():
		return source_uuid
	var link = note_links[0]
	if link is Dictionary:
		return str(link.get("uuid", ""))
	return source_uuid


## Get the source object if it still exists
func get_source_object() -> Object:
	var note_uuid = get_primary_note_uuid()
	if note_uuid.is_empty():
		return null
	return SingletonObject.get_registered_object(note_uuid)


func has_note_uuid(note_uuid: String) -> bool:
	if note_uuid.is_empty():
		return false
	for link in note_links:
		if link is Dictionary and str(link.get("uuid", "")) == note_uuid:
			return true
	return false


func add_note_link(note_uuid: String, note_title: String, relation: String) -> void:
	if note_uuid.is_empty():
		return
	if has_note_uuid(note_uuid):
		return
	note_links.append({
		"uuid": note_uuid,
		"title": note_title,
		"relation": relation,
		"attached_at": Time.get_datetime_string_from_system()
	})


func remove_note_link(note_uuid: String) -> bool:
	if note_uuid.is_empty():
		return false
	for i in range(note_links.size()):
		var link = note_links[i]
		if link is Dictionary and str(link.get("uuid", "")) == note_uuid:
			note_links.remove_at(i)
			# Also clear source_uuid if it matches
			if source_uuid == note_uuid:
				source_uuid = ""
			return true
	return false


func get_all_note_uuids() -> Array[String]:
	var uuids: Array[String] = []
	for link in note_links:
		if link is Dictionary:
			var uuid = str(link.get("uuid", ""))
			if not uuid.is_empty():
				uuids.append(uuid)
	return uuids


## Serialize task to dictionary for saving
func serialize() -> Dictionary:
	return {
		"id": id,
		"title": title,
		"description": description,
		"status": status,
		"priority": priority,
		"version": version,
		"assigned_model": assigned_model,
		"created_at": created_at,
		"updated_at": updated_at,
		"related_files": related_files,
		"metadata": metadata,
		"source_type": source_type,
		"source_uuid": source_uuid,
		"source_context": source_context,
		"note_links": note_links,
		"image_ids": Array(image_ids),
	}


## Deserialize task from dictionary
static func deserialize(data: Dictionary) -> AutocoderTask:
	var task = AutocoderTask.new()
	task.id = data.get("id", "")
	task.title = data.get("title", "")
	task.description = data.get("description", "")
	task.status = data.get("status", TaskStatus.PLAN)
	task.priority = data.get("priority", 2)
	task.version = data.get("version", 1)
	task.assigned_model = data.get("assigned_model", "")
	task.created_at = data.get("created_at", "")
	task.updated_at = data.get("updated_at", "")
	
	# Convert related_files to typed array
	var related_files_data = data.get("related_files", [])
	var typed_related_files: Array[String] = []
	for file in related_files_data:
		typed_related_files.append(str(file))
	task.related_files = typed_related_files
	
	task.metadata = data.get("metadata", {})
	task.source_type = data.get("source_type", SourceType.USER_MANUAL)
	task.source_uuid = data.get("source_uuid", "")
	task.source_context = data.get("source_context", "")
	# Convert note_links to typed array
	var note_links_data = data.get("note_links", [])
	var typed_note_links: Array[Dictionary] = []
	for link in note_links_data:
		if link is Dictionary:
			typed_note_links.append(link)
	task.note_links = typed_note_links
	
	var img_ids = data.get("image_ids", [])
	task.image_ids = PackedStringArray(img_ids)
	
	return task
