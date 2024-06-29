class_name MemoryItem
extends RefCounted ## so I get memory management and signals.

## MemoryItem is my stab at a single memory item that I can then use as I want.

static var SERIALIZER_FIELDS = ["Enabled", "Title", "Content", "DataType", "Visible", "Pinned", "Order"]

var Enabled: bool = true:
	set(value): SingletonObject.save_state(false); Enabled = value

var Type: int = SingletonObject.note_type.TEXT:
	set(value): SingletonObject.save_state(false); Type = value

var Title: String:
	set(value): SingletonObject.save_state(false); Title = value

var Content: String = "":
	set(value): SingletonObject.save_state(false); Content = value

var image: Image = null:
	set(value): SingletonObject.save_state(false); image = value

var audio: AudioStreamWAV = null:# type? -> AudioStreamWAV
	set(value): SingletonObject.save_state(false); audio = value

var ContentType: String:
	set(value): SingletonObject.save_state(false); ContentType = value

var Visible: bool:
	set(value): SingletonObject.save_state(false); Visible = value

var Pinned: bool:
	set(value): SingletonObject.save_state(false); Pinned = value

var Order: int:
	set(value): SingletonObject.save_state(false); Order = value;

var OwningThread: String

## Constructor
func _init(_OwningThread:String):
	self.OwningThread = _OwningThread
	self.Enabled = true

	pass

func _enable_toggle():
	self.Enabled = !self.Enabled


## Function:
# Serialize takes this instance of a MemoryItem and serializes it so it can be represented as JSON
func Serialize() -> Dictionary:
	var save_dict:Dictionary = {
		"Enabled": Enabled,
		"Title": Title,
		"Content": Content,
		"ContentType": ContentType,
		"Visible": Visible,
		"Pinned": Pinned,
		"Order": Order,
		"OwningThread": OwningThread
	}
	return save_dict


static func Deserialize(data: Dictionary) -> MemoryItem:

	var mi = MemoryItem.new(data.get("OwningThread"))

	for prop in SERIALIZER_FIELDS:
		mi.set(prop, data.get(prop))
	
	return mi
