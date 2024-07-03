class_name MemoryItem
extends RefCounted ## so I get memory management and signals.

## MemoryItem is my stab at a single memory item that I can then use as I want.

static var SERIALIZER_FIELDS = ["Enabled", "Type", "Title", "Content", "Memory_Image", "Image_caption", "Audio", "DataType", "Visible", "Pinned", "Order"]

var Enabled: bool = true:
	set(value): SingletonObject.save_state(false); Enabled = value

var Type: int = SingletonObject.note_type.TEXT:
	set(value): SingletonObject.save_state(false); Type = value

var Title: String:
	set(value): SingletonObject.save_state(false); Title = value

var Content: String = "":
	set(value): SingletonObject.save_state(false); Content = value

var Memory_Image: Image = Image.new():
	set(value): SingletonObject.save_state(false); Memory_Image = value

var Image_caption: String = "":
	set(value): SingletonObject.save_state(false); Image_caption = value

var Audio: AudioStreamWAV = AudioStreamWAV.new():
	set(value): SingletonObject.save_state(false); Audio = value

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
	var b64_data_image
	if Memory_Image != null:
		b64_data_image = Marshalls.variant_to_base64(Memory_Image, true)
	else:
		b64_data_image = Marshalls.variant_to_base64(Image.new(), true)
	
	var b64_data_audio
	if Audio != null:
		b64_data_audio = Marshalls.variant_to_base64(Audio, true)
	else:
		b64_data_audio = Marshalls.variant_to_base64( AudioStreamWAV.new(), true)
	
	var save_dict:Dictionary = {
		"Enabled": Enabled,
		"Title": Title,
		"Content": Content,
		"Type": Type,
		"ContentType": ContentType,
		#encode the image to png and then to base64
		"Memory_Image": b64_data_image,
		"Audio": b64_data_audio,
		"Image_caption": Image_caption,
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
		if prop == "Memory_Image":
			#decode to png
			var img = Image.new()
			if value != null:
				img = Marshalls.base64_to_variant(value, true)
				value = img
			else:
				value = img
		if prop == "Audio":
			if value != null:
				var audio = Marshalls.base64_to_variant(value, true)
				value = audio
		
		mi.set(prop, value)
	
	return mi
