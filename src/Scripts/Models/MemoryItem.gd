class_name MemoryItem
extends RefCounted ## so I get memory management and signals.

## MemoryItem is my stab at a single memory item that I can then use as I want.

## This signal is emitted when [member Enabled] is changed.
signal toggled(on: bool)


static var SERIALIZER_FIELDS = ["Enabled", "Locked", "Type", "Title", "Content", "MemoryImage", "ImageCaption", "Audio", "DataType", "Visible", "Pinned", "Order"]

var Enabled: bool = true:
	set(value):
		if Locked: return
		Enabled = value
		toggled.emit(value)
		SingletonObject.save_state(false)

## If memory item is locked, changing the `Enabled` property is not possible
var Locked: bool = false:
	set(value): SingletonObject.save_state(false); Locked = value

var Type: int = SingletonObject.note_type.TEXT:
	set(value): SingletonObject.save_state(false); Type = value

var Title: String:
	set(value): SingletonObject.save_state(false); Title = value

var Content: String = "":
	set(value): SingletonObject.save_state(false); Content = value

var MemoryImage: Image:
	set(value): SingletonObject.save_state(false); MemoryImage = value

var ImageCaption: String = "":
	set(value): SingletonObject.save_state(false); ImageCaption = value

var Audio: AudioStream:
	set(value): SingletonObject.save_state(false); Audio = value

var ContentType: String:
	set(value): SingletonObject.save_state(false); ContentType = value

var Visible: bool:
	set(value): SingletonObject.save_state(false); Visible = value

var Pinned: bool:
	set(value): SingletonObject.save_state(false); Pinned = value

var Order: int:
	set(value): SingletonObject.save_state(false); Order = value;

var OwningThread


func _init(_OwningThread = null):
	self.OwningThread = _OwningThread
	self.Enabled = true

	pass

func _enable_toggle():
	self.Enabled = !self.Enabled


## Function:
# Serialize takes this instance of a MemoryItem and serializes it so it can be represented as JSON
func Serialize() -> Dictionary:
	var b64_data_image
	if MemoryImage:
		b64_data_image = Marshalls.raw_to_base64(MemoryImage.save_png_to_buffer())
	

	var b64_data_audio
	if Audio:
		b64_data_audio = Marshalls.variant_to_base64(Audio, true)

	var save_dict:Dictionary = {
		"Enabled": Enabled,
		"Locked": Locked,
		"Title": Title,
		"Content": Content,
		"Type": Type,
		"ContentType": ContentType,
		"MemoryImage": b64_data_image,
		"Audio": b64_data_audio,
		"ImageCaption": ImageCaption,
		"Visible": Visible,
		"Pinned": Pinned,
		"Order": Order,
		"OwningThread": OwningThread
	}
	return save_dict


static func Deserialize(data: Dictionary) -> MemoryItem:
	var mi = MemoryItem.new(data.get("OwningThread"))

	for prop in SERIALIZER_FIELDS:
		var value = data.get(prop)

		if prop == "MemoryImage":
			if not value: continue # if no data, just skip

			var img = Image.new()
			img.load_png_from_buffer(Marshalls.base64_to_raw(value))
			value = img
			
		if prop == "Audio":
			if not value: continue # if no data, just skip

			var audio: AudioStream = Marshalls.base64_to_variant(value, true)

			value = audio
		
		mi.set(prop, value)
	
	return mi
