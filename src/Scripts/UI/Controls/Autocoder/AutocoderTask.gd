class_name AutocoderTask
extends Resource

enum TaskStatus {
	PLAN,
	IN_PROGRESS,
	AI_REVIEW,
	HUMAN_REVIEW,
	DONE
}

@export var id: String
@export var title: String
@export var description: String
@export var status: TaskStatus = TaskStatus.PLAN
@export var assigned_model: String = ""
@export var created_at: String = ""
@export var updated_at: String = ""
@export var related_files: Array[String] = []
@export var metadata: Dictionary = {}

func _init(
	p_id: String = "",
	p_title: String = "",
	p_description: String = "",
	p_status: TaskStatus = TaskStatus.PLAN,
	p_model: String = ""
):
	id = p_id
	title = p_title
	description = p_description
	status = p_status
	assigned_model = p_model
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
