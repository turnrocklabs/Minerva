class_name ChatHistoryItem
extends RefCounted

enum PartType {TEXT, CODE, JPEG}
enum ChatRole {USER, ASSISTANT, MODEL}

var Role: ChatRole
var Message: String
var Base64Data: String
var Order: int
var Type: PartType

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
func Serialize() -> String:
	var save_dict: Dictionary = {
		"Role": Role,
		"Message" : Message,
		"Base64Data" : Base64Data,
		"Order" : Order,
		"Type" : Type
	}
	var stringified = JSON.stringify(save_dict)
	return stringified


static func Deserialize(data: Dictionary) -> ChatHistoryItem:
	
	var chi = ChatHistoryItem.new()

	var properties = ["Role", "Message", "Base64Data", "Order", "Type"]

	for prop in properties:
		chi.set(prop, data.get(prop))

	return chi