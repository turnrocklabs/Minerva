class_name ContextBlock
extends RefCounted

enum Type {
	TEXT,
	STRUCTURED_JSON,
	IMAGE,
	SOURCE_CODE,
	TABLE,
	UNSUPPORTED_PLACEHOLDER,
}

var type: Type = Type.TEXT
var type_name: String = "TEXT"
var content: Variant = null


static func make(block_type: Type, block_content: Variant) -> Dictionary:
	return {
		"type": int(block_type),
		"type_name": type_name_for(block_type),
		"content": block_content,
	}


static func type_name_for(block_type: Type) -> String:
	match block_type:
		Type.TEXT:
			return "TEXT"
		Type.STRUCTURED_JSON:
			return "STRUCTURED_JSON"
		Type.IMAGE:
			return "IMAGE"
		Type.SOURCE_CODE:
			return "SOURCE_CODE"
		Type.TABLE:
			return "TABLE"
		Type.UNSUPPORTED_PLACEHOLDER:
			return "UNSUPPORTED_PLACEHOLDER"
	return "TEXT"
