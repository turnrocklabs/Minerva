class_name ChatHistoryItem
extends RefCounted

enum PartType {TEXT, CODE, JPEG}
enum ChatRole {USER, ASSISTANT, MODEL}

static var SERIALIZER_FIELDS = ["Role", "InjectedNote", "Message", "Base64Data", "Order", "Type", "ModelName", "ModelShortName"]

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

var ModelName: String:
	set(value): SingletonObject.save_state(false); ModelName = value

var ModelShortName: String:
	set(value): SingletonObject.save_state(false); ModelShortName = value



func _init(_type: PartType = PartType.TEXT, _role: ChatRole = ChatRole.USER):
	self.Type = _type
	self.Role = _role
	self.Message = ""
	self.Base64Data = ""
	self.ModelName = SingletonObject.Chats.provider.model_name
	self.ModelShortName = SingletonObject.Chats.provider.short_name


func format(callback: Callable) -> String:
	var output: String = callback.call(self)
	return output

func to_bot_response() -> BotResponse:
	var res = BotResponse.new()
	res.FullText = Message
	res.ModelName = ModelName
	res.ModelShortName = ModelShortName

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
		"Type" : Type,
		"ModelName": ModelName,
		"ModelShortName": ModelShortName,
	}
	return save_dict


static func Deserialize(data: Dictionary) -> ChatHistoryItem:
	
	# Backwards compatibility
	# In case we don't have model specified just use this as a fallback
	data.merge({
		"ModelName": "Unknown",
		"ModelShortName": "Unknown",
	})

	var chi = ChatHistoryItem.new()

	for prop in SERIALIZER_FIELDS:
		chi.set(prop, data.get(prop))

	return chi
