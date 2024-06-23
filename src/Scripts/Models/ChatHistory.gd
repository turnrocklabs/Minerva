class_name ChatHistory
extends RefCounted
## Each LLM provider has a different concept of turn-based chats and multi-modal parts.
# Note: Modal, not model.  Modal refers to text, video, audio, etc.
# This abstraction is an interface to create a standard that each provider can then use.

var HistoryId: String:
	set(value): SingletonObject.save_state(false); HistoryId = value

var HistoryName: String:
	set(value): SingletonObject.save_state(false); HistoryName = value

var HistoryItemList: Array[ChatHistoryItem]:
	set(value): SingletonObject.save_state(false); HistoryItemList = value

var VBox: VBoxChat
var Provider



static var SERIALIZER_FIELDS = ["HistoryId", "HistoryName", "HistoryItemList"]


## initialize with a new HistoryId

func _init(_provider, optional_historyId = null):
	self.Provider = _provider
	if optional_historyId == null:
		var rng = RandomNumberGenerator.new() # Instantiate the RandomNumberGenerator
		rng.randomize() # Uses the current time to seed the random number generator
		var random_number = rng.randi() # Generates a random integer
		var hash256 = str(random_number).sha256_text()
		self.HistoryId = hash256
	else:
		# id was provided
		self.HistoryId = optional_historyId
	HistoryItemList = []
	pass

func To_Prompt() -> Array[Variant]:
	var retVal:Array[Variant] = []
	for chat: ChatHistoryItem in self.HistoryItemList:
		var item: Variant = Provider.Format(chat)
		retVal.append(item)
	return retVal


## Function:
# Serialize creates a JSON representation of this instance.
func Serialize() -> Dictionary:
	var serialized_items: Array[Dictionary] = []

	for chat_history_item: ChatHistoryItem in HistoryItemList:
		var searialized_item = chat_history_item.Serialize()
		serialized_items.append(searialized_item)


	var save_dict:Dictionary = {
		"HistoryId" : HistoryId,
		"HistoryName" : HistoryName,
		"HistoryItemList" : serialized_items
	}
	return save_dict

static func Deserialize(data: Dictionary) -> ChatHistory:
	var ch = ChatHistory.new(SingletonObject.Provider, data.get("HistoryId"))

	ch.HistoryName = data.get("HistoryName")

	for chi_data in data.get("HistoryItemList", []):
		ch.HistoryItemList.append(ChatHistoryItem.Deserialize(chi_data))

	return ch

