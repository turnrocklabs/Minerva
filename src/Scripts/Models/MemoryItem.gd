class_name MemoryItem
extends RefCounted ## so I get memory management and signals.

## MemoryItem is my stab at a single memory item that I can then use as I want.

## This signal is emitted when [member Enabled] is changed.
signal toggled(on: bool)
signal changed(property: StringName)

static var SERIALIZER_FIELDS = ["UUID" ,"Enabled", "File", "Locked", "Type", "Title", "Content", "MemoryImage", "ImageCaption", "Audio", "Visible", "Pinned", "Order", "Expanded", "LastYSize", "isDrawer"]


## Emits a signal that the property [parameter prop_name] has been updated.[br]
## if [parameter update_saved_state] is `true`, `SingletonObject.save_state(false)` will also be called.
func _property_updated(prop_name: StringName, update_saved_state: = true) -> void:

	changed.emit(prop_name)
	
	if update_saved_state:
		SingletonObject.save_state(false)


var UUID: String = "":
	set(value):
		if UUID == "":
			UUID = value; _property_updated("UUID")
		else: 
			printerr("Tried to update UUID")

var Enabled: bool = true:
	set(value):
		if Locked: return
		Enabled = value; _property_updated("Enabled")
		toggled.emit(value)

## File from which this items content was loaded from
var File: String:
	set(value): File = value; _property_updated("File")

## a sha-256 hash computed whenever the item is updated
var Sha_256: String

## If memory item is locked, changing the `Enabled` property is not possible
var Locked: bool = false:
	set(value): Locked = value; _property_updated("Locked")

var Type: int = SingletonObject.note_type.TEXT:
	set(value): Type = value; _property_updated("Type")

var Title: String:
	set(value): 
		if not value.is_empty():
			Title = value; _property_updated("Title")

var Content: String = "":
	set(value):
		Sha_256 = hash_string(value)
		Content = value; _property_updated("Content")

var MemoryImage: Image:
	set(value): MemoryImage = value; _property_updated("MemoryImage")

var ImageCaption: String = "":
	set(value): ImageCaption = value; _property_updated("ImageCaption")

var Audio: AudioStream:
	set(value): Audio = value; _property_updated("Audio")

var ContentType: String:
	set(value): ContentType = value; _property_updated("ContentType")

var Visible: bool:
	set(value): Visible = value; _property_updated("Visible")

var Pinned: bool:
	set(value): Pinned = value; _property_updated("Pinned")

var Order: int:
	set(value): Order = value; _property_updated("Order")

var Expanded: bool = true:
	set(value): Expanded = value; _property_updated("Expanded")

var LastYSize: float = 0.0:
	set(value): LastYSize = value; _property_updated("LastYSize")

var isCompleted: bool:
	set(value): isCompleted = value; _property_updated("isCompleted")

var isDrawer: bool:
	set(value): isDrawer = value

###### ////////////////////////////////////////////////////////////////
## Every time you add a field to the serializer be sure to add it to the SERIALIZER_FIELDS array at the top
###### ////////////////////////////////////////////////////////////////

var OwningThread

func hash_string(input: String) -> String:
	if input.length() < 1: return ""

	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(input.to_utf8_buffer())
	var hashed = ctx.finish()
	return hashed.hex_encode()


func _init(_OwningThread = null):
	self.OwningThread = _OwningThread
	self.Enabled = true


func _enable_toggle():
	self.Enabled = !self.Enabled


## Function:
# Serialize takes this instance of a MemoryItem and serializes it so it can be represented as JSON
func Serialize(use_b64: = true) -> Dictionary:
	var b64_data_image
	if MemoryImage and use_b64:
		b64_data_image = Marshalls.raw_to_base64(MemoryImage.save_png_to_buffer())
	

	var b64_data_audio
	if Audio and use_b64:
		b64_data_audio = Marshalls.variant_to_base64(Audio, true)

	var save_dict:Dictionary = {
		"UUID": UUID,
		"Enabled": Enabled,
		"File": File,
		"Locked": Locked,
		"Title": Title,
		"Content": Content,
		"Type": Type,
		"ContentType": ContentType,
		"MemoryImage": b64_data_image if use_b64 else MemoryImage,
		"Audio": b64_data_audio if use_b64 else Audio,
		"ImageCaption": ImageCaption,
		"Visible": Visible,
		"Pinned": Pinned,
		"Order": Order,
		"OwningThread": OwningThread,
		"Expanded": Expanded,
		"LastYSize": LastYSize,
		"isDrawer": isDrawer
	}
	return save_dict


static func Deserialize(data: Dictionary) -> MemoryItem:
	var mi = MemoryItem.new(data.get("OwningThread"))

	for prop in SERIALIZER_FIELDS:
		var value = data.get(prop)

		if prop == "MemoryImage":
			if not value: continue # if no data, just skip

			var img = Image.new()
			if value is String:
				img.load_png_from_buffer(Marshalls.base64_to_raw(value))
			elif value is FileAccess:
				value.seek(0)
				img.load_png_from_buffer(FileAccess.get_file_as_bytes(value.get_path()))
			elif value is Image:
				img.copy_from(value)
			
			value = img
			
		elif prop == "Audio":
			if not value: continue # if no data, just skip

			var audio: AudioStream = Marshalls.base64_to_variant(value, true)

			value = audio
		
		elif prop == "File":
			if not value: continue # if no data, just skip
			
			# if file doesn't exist anymore, set it to null
			if value is String:
				if not FileAccess.file_exists(value):
					value = null
			elif value is FileAccess:
				value = value.get_path_absolute()

		elif prop == "UUID":
			if value == "":
				value = SingletonObject.generate_UUID()

		
		mi.set(prop, value)
	
	return mi
