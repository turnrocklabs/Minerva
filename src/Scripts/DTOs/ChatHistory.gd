class_name ChatHistory
extends RefCounted

## Each LLM provider has a different concept of turn-based chats and multi-modal parts.
# Note: Modal, not model.  Modal refers to text, video, audio, etc.
# This abstraction is an interface to create a standard that each provider can then use.

var HistoryId: String
var HistoryName: String
var HistoryItemList: Array[ChatHistoryItem]
var VBox: VBoxChat
var Provider

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
