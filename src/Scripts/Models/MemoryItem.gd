class_name MemoryItem
extends RefCounted ## so I get memory management and signals.

## MemoryItem is my stab at a single memory item that I can then use as I want.

var Enabled: bool = true
var Title: String
var Content: String
var Visible: bool
var Pinned: bool
var Order: int
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
		"Visible": Visible,
		"Pinned": Pinned,
		"Order": Order,
		"OwningThread": OwningThread
	}
	return save_dict


static func Deserialize(data: Dictionary) -> MemoryItem:

	var mi = MemoryItem.new(data.get("OwningThread"))

	var properties = ["Enabled", "Title", "Content", "Visible", "Pinned", "Order"]

	for prop in properties:
		mi.set(prop, data.get(prop))
	
	return mi
