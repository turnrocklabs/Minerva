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
