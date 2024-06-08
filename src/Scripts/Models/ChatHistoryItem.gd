class_name ChatHistoryItem
extends RefCounted

enum PartType {TEXT, CODE, JPEG}
enum ChatRole {SYSTEM,USER, ASSISTANT, MODEL}

static var SERIALIZER_FIELDS = ["Role", "InjectedNote", "Message", "Base64Data", "Order", "Type"]

var Role: ChatRole:
	set(value): SingletonObject.save_state(false); Role = value

var InjectedNote: String:
	set(value): SingletonObject.save_state(false); InjectedNote = value

var Message: String:
	set(value): SingletonObject.save_state(false); Message = value

var Base64Data: String:
	set(value): SingletonObject.save_state(false); Base64Data = value

var Order: int:
	set(value): SingletonObject.save_state(false); Order = value

var Type: PartType:
	set(value): SingletonObject.save_state(false); Type = value


func _init(_type: PartType = PartType.TEXT, _role: ChatRole = ChatRole.USER):
	self.Type = _type
	self.Role = _role
	self.Message = ""
	self.Base64Data = ""
	pass


func format(callback: Callable) -> String:
	var output: String = callback.call(self)
	return output

func to_bot_response() -> BotResponse:
	var res = BotResponse.new()
	res.FullText = Message

	return res

## Function:
# Serialize the item to a string
func Serialize() -> Dictionary:
	var save_dict: Dictionary = {
		"Role": Role,
		"InjectedNote": InjectedNote,
		"Message" : Message,
		"Base64Data" : Base64Data,
		"Order" : Order,
		"Type" : Type
	}
	return save_dict


static func Deserialize(data: Dictionary) -> ChatHistoryItem:
	
	var chi = ChatHistoryItem.new()

	for prop in SERIALIZER_FIELDS:
		chi.set(prop, data.get(prop))

	return chi
