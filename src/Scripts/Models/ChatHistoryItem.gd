class_name ChatHistoryItem
extends RefCounted

enum PartType {TEXT, CODE, JPEG}
enum ChatRole {USER, ASSISTANT, MODEL, SYSTEM}

static var SERIALIZER_FIELDS = [
	"Role",
	"InjectedNotes",
	"Message",
	"Images",
	"Captions",
	"Order",
	"Type",
	"ModelName",
	"ModelShortName",
	"EstimatedTokenCost",
	"TokenCost",
	"Visible",
	"Expanded",
	"LastYSize",
	"LinkedMemories",
	"CodeLabelsState",
	"isMerged"
]

# This signal is to be emitted when new message in the history list is added
signal response_arrived(item: ChatHistoryItem)

var Id: String:
	set(value): SingletonObject.save_state(false); Id = value

var Role: ChatRole:
	set(value): SingletonObject.save_state(false); Role = value

var InjectedNotes: Array[Variant]:
	set(value): SingletonObject.save_state(false); InjectedNotes = value

var Message: String:
	set(value): SingletonObject.save_state(false); Message = value

var Images: Array[Image]:
	set(value): SingletonObject.save_state(false); Images = value

var Order: int:
	set(value): SingletonObject.save_state(false); Order = value

var Type: PartType:
	set(value): SingletonObject.save_state(false); Type = value

var ModelName: String:
	set(value): SingletonObject.save_state(false); ModelName = value

var ModelShortName: String:
	set(value): SingletonObject.save_state(false); ModelShortName = value

var Complete: bool:
	set(value): SingletonObject.save_state(false); Complete = value

var Error: String:
	set(value): SingletonObject.save_state(false); Error = value

var Visible: bool = true:
	set(value): SingletonObject.save_state(false); Visible = value

## Estimated amount of tokens of this history item.
## `null` if no estimation was made for this history item.
var EstimatedTokenCost: int:
	set(value): SingletonObject.save_state(false); EstimatedTokenCost = value

## Amount of tokens of this history item
var TokenCost: int = 0:
	set(value): SingletonObject.save_state(false); TokenCost = value

var provider: BaseProvider:
	set(value):
		_provider_updated()
		provider = value

var Expanded: bool = true:
	set(value): SingletonObject.save_state(false); Expanded = value

var LastYSize: float = 0.0:
	set(value): SingletonObject.save_state(false); LastYSize = value

#this  filed is for saving the UUID of the memoryItems with its respective code label
#{codeLabelIndex: int, MemoryItemUUID: String}
var LinkedMemories: Dictionary = {}:
	set(value): SingletonObject.save_state(false); LinkedMemories = value

var CodeLabelsState: Dictionary = {}:
	set(value): SingletonObject.save_state(false); CodeLabelsState = value
	
var isMerged: bool = false:
	set(value): SingletonObject.save_state(false); isMerged = value

## The node that is currently rendering this item
var rendered_node: MessageMarkdown


func _init(_type: PartType = PartType.TEXT, _role: ChatRole = ChatRole.USER, _text: String = "", _provider: BaseProvider = null):
	self.Type = _type
	self.Role = _role
	self.Message = _text
	self.Complete = true

	# take provider from active tab as one used, if there is one
	# otherwise the code that initializes this object should set the provider
	if not SingletonObject.ChatList.is_empty():
		self.provider = SingletonObject.ChatList[SingletonObject.Chats.current_tab].provider
	elif not _provider == null:
		self.provider = _provider
	else:
		self.provider = HumanProvider.new()
	var rng = RandomNumberGenerator.new() # Instantiate the RandomNumberGenerator
	rng.randomize() # Uses the current time to seed the random number generator
	var random_number = rng.randi() # Generates a random integer
	self.Id = str(random_number).sha256_text()

	response_arrived.connect(_on_response_arrived)


## When the provider is updated update the used model names
func _provider_updated():
	if provider:
		self.ModelName = provider.model_name
		self.ModelShortName = provider.short_name

func _on_response_arrived(item: ChatHistoryItem):
	print("Response arrived for %s (%s)" % [self, item])
	if rendered_node:
		# Set the history_item again to trigger the setter
		rendered_node.history_item = self
	SingletonObject.play_chat_notification()


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

	# Save images to user folder
	var images_ = Images.map(
		func(img: Image):
			var b64_data = Marshalls.raw_to_base64(img.save_png_to_buffer())
			return b64_data
	)

	var captions_ = Images.map(
		func(img: Image):
			if img.has_meta("caption"):
				return img.get_meta("caption")
			else: 
				return ""
	)

	var save_dict: Dictionary = {
		"Role": Role,
		"InjectedNotes": Marshalls.variant_to_base64(InjectedNotes),
		"Message": Message,
		"Order": Order,
		"Type": Type,
		"ModelName": ModelName,
		"ModelShortName": ModelShortName,
		"Visible": Visible,
		"EstimatedTokenCost": EstimatedTokenCost,
		"TokenCost": TokenCost,
		"Images": images_,
		"Captions": captions_,
		"Expanded": Expanded,
		"LastYSize": LastYSize,
		"LinkedMemories": LinkedMemories,
		"CodeLabelsState": CodeLabelsState,
		"isMerged": isMerged
	}
	return save_dict


static func Deserialize(data: Dictionary) -> ChatHistoryItem:
	# region Backwards compatibility

	# 1. In case we don't have model specified just use this as a fallback
	# 2. Old project files don't have "Images" field
	data.merge({
		"ModelName": "NA",
		"ModelShortName": "NA",
		"Visible": true,
		"TokenCost": 0,
		"Images": [],
		"Captions": []
	})
	
	# Make sure "Captions" has same number of elements as "Images"
	if data["Captions"].size() == data["Images"].size():
		data["Captions"].resize(data.get("Images").size())

	var chi = ChatHistoryItem.new()

	# InjectedNote changed to InjectedNotes.
	# Just place the old InjectedNote into the array
	if data.has("InjectedNote"):
		chi.InjectedNotes = [data["InjectedNote"]]

	# endregion


	for prop in SERIALIZER_FIELDS:
		var value = data.get(prop)
		
		match prop:
			"Images":
				var img_arr: Array[Image] = []
				img_arr.assign((value as Array).map(
					func(b64_data: String):
						var img = Image.new()
						img.load_png_from_buffer(Marshalls.base64_to_raw(b64_data))
						return img
				))

				value = img_arr
			
			# Make sure `Captions` is after `Images` in `SERIALIZER_FIELDS`
			# so the images array is set
			"Captions":
				for i in range((value as Array).size()):
					chi.Images[i].set_meta("caption", value[i])
			
			"InjectedNotes":
				var b64_notes = data.get("InjectedNotes", "")

				# Condition "len < 4" is true. Returning: ERR_INVALID_DATA
				# base64 string is invalid if it's less than 4 characters
				if not b64_notes.length() < 4:
					value = Marshalls.base64_to_variant(b64_notes)
				
				if not value:
					value = []

		chi.set(prop, value)

	return chi


## Merges two history items together
func merge(item: ChatHistoryItem) -> void:
	if Message and item.Message and Images.is_empty() and item.Images.is_empty():
		# Merge text messages
		var separator = "\u200B\u200C\u200D"  # Combination of invisible characters
		Message = "%s%s%s" % [Message, separator, item.Message]
		InjectedNotes.append_array(item.InjectedNotes)
		Complete = Complete and item.Complete
		isMerged = true
	elif Images and item.Images and Message.is_empty() and item.Message.is_empty():
		# Merge images
		Images.append_array(item.Images)
		InjectedNotes.append_array(item.InjectedNotes)
		Complete = Complete and item.Complete
		isMerged = true
	elif (Message or item.Message) and (Images or item.Images):
		# Merge both text and images
		if Message and item.Message:
			var separator = "\u200B\u200C\u200D"
			Message = "%s%s%s" % [Message, separator, item.Message]
		elif item.Message:
			Message = item.Message  # If only one has text, set it
		
		if Images and item.Images:
			Images.append_array(item.Images)
		elif item.Images:
			Images = item.Images  # If only one has images, set it

		InjectedNotes.append_array(item.InjectedNotes)
		Complete = Complete and item.Complete
		isMerged = true

	
