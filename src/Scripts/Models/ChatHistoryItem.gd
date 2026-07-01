class_name ChatHistoryItem
extends RefCounted

enum PartType {TEXT, CODE, JPEG}
enum ChatRole {USER, ASSISTANT, MODEL, SYSTEM, TOOL}

static var SERIALIZER_FIELDS = [
	"Role",
	"InjectedNotes",
	"Message",
	"HcpStructure",
	"HcpData",
	"Images",
	"Captions",
	"Order",
	"Type",
	"ModelName",
	"ModelShortName",
	"EstimatedTokenCost",
	"TokenCost",
	"InputTokens",
	"OutputTokens",
	"Visible",
	"Expanded",
	"LastYSize",
	"LinkedMemories",
	"CodeLabelsState",
	"isMerged",
	"SliderContainerId", # if 2 or more items share the same ID they get put in the same SliderContainer
	"MultiSliderContainerId", # if 2 or more items share the same ID they get put in the same SliderContainer
	"ToolCallId",
	"ToolName",
	"ToolCalls",
	"IsToolCall",
	"ToolExecutions",
	"ToolSummary",
	"ToolArtifactNoteId",
	"RequestMetadata",
	"Reasoning"
]

# This signal is to be emitted when new message in the history list is added
signal response_arrived(item: ChatHistoryItem)

var _suppress_save_state: bool = false

func _queue_save_state() -> void:
	if not _suppress_save_state:
		SingletonObject.call_deferred("save_state", false)

var Id: String:
	set(value): _queue_save_state(); Id = value

var Role: ChatRole:
	set(value): _queue_save_state(); Role = value

var InjectedNotes: Array[Variant]:
	set(value): _queue_save_state(); InjectedNotes = value

var HcpData: Dictionary:
	set(value): _queue_save_state(); HcpData = value

var HcpStructure: Dictionary:
	set(value): _queue_save_state(); HcpStructure = value

var Message: String:
	set(value): _queue_save_state(); Message = value

var Images: Array[Image]:
	set(value): _queue_save_state(); Images = value

var Order: int:
	set(value): _queue_save_state(); Order = value

var Type: PartType:
	set(value): _queue_save_state(); Type = value

var ModelName: String:
	set(value): _queue_save_state(); ModelName = value

var ModelShortName: String:
	set(value): _queue_save_state(); ModelShortName = value

var Complete: bool:
	set(value): _queue_save_state(); Complete = value

var Error: String:
	set(value): _queue_save_state(); Error = value

var Visible: bool = true:
	set(value): _queue_save_state(); Visible = value

## Estimated amount of tokens of this history item.
## `null` if no estimation was made for this history item.
var EstimatedTokenCost: int:
	set(value): _queue_save_state(); EstimatedTokenCost = value

## Number of input tokens (prompt tokens) for this turn
var InputTokens: int = 0:
	set(value): _queue_save_state(); InputTokens = value

## Number of output tokens (completion tokens) for this turn
var OutputTokens: int = 0:
	set(value): _queue_save_state(); OutputTokens = value

## Amount of tokens of this history item (legacy - now computed from InputTokens + OutputTokens)
var TokenCost: int:
	get: return InputTokens + OutputTokens
	set(value):
		# Legacy setter - distribute to output tokens for backwards compat
		OutputTokens = value
		_queue_save_state()

var provider: BaseProvider:
	set(value):
		provider = value
		_provider_updated()

var Expanded: bool = true:
	set(value): _queue_save_state(); Expanded = value

var LastYSize: float = 0.0:
	set(value): _queue_save_state(); LastYSize = value

#this  filed is for saving the UUID of the memoryItems with its respective code label
#{codeLabelIndex: int, MemoryItemUUID: String}
var LinkedMemories: Dictionary = {}:
	set(value): _queue_save_state(); LinkedMemories = value

var CodeLabelsState: Dictionary = {}:
	set(value): _queue_save_state(); CodeLabelsState = value
	
var isMerged: bool = false:
	set(value): _queue_save_state(); isMerged = value

var SliderContainerId: String = "":
	set(value): _queue_save_state(); SliderContainerId = value

var MultiSliderContainerId: String = "":
	set(value): _queue_save_state(); MultiSliderContainerId = value

## Tool call ID (for TOOL role responses - correlates with the tool_call that triggered this)
var ToolCallId: String = "":
	set(value): _queue_save_state(); ToolCallId = value

## Tool name (for TOOL role - which tool was called)
var ToolName: String = "":
	set(value): _queue_save_state(); ToolName = value

## Tool arguments (for ASSISTANT role with tool calls)
var ToolCalls: Array[Dictionary] = []:
	set(value): _queue_save_state(); ToolCalls = value

## Whether this is a tool call message
var IsToolCall: bool = false:
	set(value): _queue_save_state(); IsToolCall = value

## Tool execution data for displaying in UI
## Structure: [{call_id: String, tool_name: String, arguments: Dictionary, result: String, status: String}]
## status can be: "calling", "done", "error"
var ToolExecutions: Array[Dictionary] = []:
	set(value): _queue_save_state(); ToolExecutions = value

## Reasoning/thinking segments for display (mirrors ToolExecutions).
## Display-only metadata — never enters Format() on a normal turn.
## Structure: [{kind: String, text: String, redacted: bool, order: int}]
var Reasoning: Array[Dictionary] = []:
	set(value): _queue_save_state(); Reasoning = value

## Raw provider reasoning items for same-model replay within the in-flight agent
## tool loop (e.g. OpenAI Responses reasoning items with encrypted_content).
## TRANSIENT — deliberately NOT in SERIALIZER_FIELDS (opaque/expiring payloads).
var ReasoningRaw: Array = []

## Compact deterministic summary used for prompt projection/dehydration.
var ToolSummary: String = "":
	set(value): _queue_save_state(); ToolSummary = value

## UUID of the note storing the full tool artifact, when available.
var ToolArtifactNoteId: String = "":
	set(value): _queue_save_state(); ToolArtifactNoteId = value

## Request metadata for debugging - stored on USER messages to show what was sent
## Structure: {system_prompt: String, tools: Array, tool_count: int, message_count: int, model: String}
var RequestMetadata: Dictionary = {}:
	set(value): _queue_save_state(); RequestMetadata = value

## The node that is currently rendering this item
var rendered_node: MessageMarkdown


func _init(_type: PartType = PartType.TEXT, _role: ChatRole = ChatRole.USER, _text: String = "", suppress_save_state: bool = false):
	self._suppress_save_state = suppress_save_state
	self.Type = _type
	self.Role = _role
	self.Message = _text
	self.Complete = true

	# take provider from active tab as one used, if there is one
	# otherwise the code that initializes this object should set the provider
	# if not SingletonObject.ChatList.is_empty():
	# 	self.provider = SingletonObject.ChatList[SingletonObject.Chats.current_tab].provider
	
	
	var rng = RandomNumberGenerator.new() # Instantiate the RandomNumberGenerator
	rng.randomize() # Uses the current time to seed the random number generator
	var random_number = rng.randi() # Generates a random integer
	self.Id = str(random_number).sha256_text()
	self._suppress_save_state = false

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
	
	for i in SingletonObject.notes_container.get_tab_count():
		SingletonObject.notes_container.disable_notes(i)

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		SingletonObject.drawer_notes_container.disable_notes(i)


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
		"HcpData": HcpData,
		"HcpStructure": HcpStructure,
		"Order": Order,
		"Type": Type,
		"ModelName": ModelName,
		"ModelShortName": ModelShortName,
		"Visible": Visible,
		"EstimatedTokenCost": EstimatedTokenCost,
		"TokenCost": TokenCost,
		"InputTokens": InputTokens,
		"OutputTokens": OutputTokens,
		"Images": images_,
		"Captions": captions_,
		"Expanded": Expanded,
		"LastYSize": LastYSize,
		"LinkedMemories": LinkedMemories,
		"CodeLabelsState": CodeLabelsState,
		"isMerged": isMerged,
		"SliderContainerId": SliderContainerId,
		"MultiSliderContainerId": MultiSliderContainerId,
		"ToolExecutions": ToolExecutions,
		"Reasoning": Reasoning,
		# Tool-related fields for agentic mode
		"ToolCallId": ToolCallId,
		"ToolName": ToolName,
		"ToolCalls": ToolCalls,
		"IsToolCall": IsToolCall,
		"ToolSummary": ToolSummary,
		"ToolArtifactNoteId": ToolArtifactNoteId,
		# Request metadata for debugging
		"RequestMetadata": RequestMetadata
	}
	return save_dict


static func Deserialize(data: Dictionary) -> ChatHistoryItem:
	# region Backwards compatibility

	print("\n\n")
	print("data: ", data)
	print("\n\n")

	# 1. In case we don't have model specified just use this as a fallback
	# 2. Old project files don't have "Images" field
	# 3. Migration: InputTokens/OutputTokens default to 0
	data.merge({
		"ModelName": "NA",
		"ModelShortName": "NA",
		"Visible": true,
		"TokenCost": 0,
		"InputTokens": 0,
		"OutputTokens": 0,
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

			"ToolExecutions":
				# Convert to typed array for backwards compatibility
				var executions: Array[Dictionary] = []
				if value is Array:
					executions.assign(value)
				value = executions

			"Reasoning":
				# Convert to typed array for backwards compatibility
				# (old project files predate the Reasoning field → null)
				var segments: Array[Dictionary] = []
				if value is Array:
					segments.assign(value)
				value = segments

			"ToolCalls":
				# Convert to typed array for backwards compatibility
				var calls: Array[Dictionary] = []
				if value is Array:
					calls.assign(value)
				value = calls

		chi.set(prop, value)

	return chi


## Create a shallow prompt-safe copy of this history item.
## Used when prompt projection needs to adjust notes or dehydrate tool payloads
## without mutating the canonical transcript.
func duplicate_for_prompt() -> ChatHistoryItem:
	var copy := ChatHistoryItem.new(PartType.TEXT, ChatRole.USER, "", true)
	copy._suppress_save_state = true
	for prop in SERIALIZER_FIELDS:
		copy.set(prop, get(prop))
	copy.provider = provider
	copy.Complete = Complete
	copy.Error = Error
	copy._suppress_save_state = false
	return copy


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

	
