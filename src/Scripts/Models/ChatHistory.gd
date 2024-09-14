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

var HasUsedSystemPrompt: bool = false:
	set(value): SingletonObject.save_state(false); HasUsedSystemPrompt = value

var Temperature: float = 1:
	set(value): SingletonObject.save_state(false); Temperature = value

var TopP: float = 1:
	set(value): SingletonObject.save_state(false); TopP = value

var FrecuencyPenalty: float = 0:
	set(value): SingletonObject.save_state(false); FrecuencyPenalty = value

var PresencePenalty: float = 0:
	set(value): SingletonObject.save_state(false); PresencePenalty = value

var VBox: VBoxChat
var provider: BaseProvider



static var SERIALIZER_FIELDS = [
	"HistoryId", 
	"HistoryName", 
	"HistoryItemList", 
	"Provider", 
	"Temperature", 
	"TopP",
	"FrecuencyPenalty",
	"PresencePenalty"
	]


## initialize with a new HistoryId

func _init(_provider, optional_historyId = null):
	self.provider = _provider
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


## Creates prompt from this history using the set provider.
## The `predivate` parameter is a `Callable` that returns an `Array` of 2 booleans.
## First detemines if provided item should be added to the returned list,
## while second detemines if the execution of the function should stop and the value returned immediately.
func To_Prompt(predicate: Callable = Callable()) -> Array[Variant]:
	var retVal:Array[Variant] = []

	for chat: ChatHistoryItem in self.HistoryItemList:
		
		if predicate.is_valid():
			var results = predicate.call(chat)
			var should_add: bool = results[0]
			var should_continue: bool = results[1]

			if should_add:
				var item: Variant = provider.Format(chat)
				if item: retVal.append(item)

			if not should_continue:
				return retVal
		else:
			var item: Variant = provider.Format(chat)
			if item: retVal.append(item)

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
		"Provider": SingletonObject.get_active_provider(SingletonObject.ChatList.find(self)),
		"HistoryItemList" : serialized_items,
		"Temperature": Temperature,
		"TopP": TopP,
		"FrecuencyPenalty": FrecuencyPenalty,
		"PresencePenalty": PresencePenalty
	}
	return save_dict

static func Deserialize(data: Dictionary) -> ChatHistory:
	# will be float if loaded from json, cast it to int
	var provider_enum_index = int(data.get("Provider", 0))
	var provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[provider_enum_index].new()

	var ch = ChatHistory.new(provider_obj, data.get("HistoryId"))

	ch.HistoryName = data.get("HistoryName")

	for chi_data in data.get("HistoryItemList", []):
		var chi = ChatHistoryItem.Deserialize(chi_data)
		chi.provider = ch.provider
		ch.HistoryItemList.append(chi)
	
	# we need to check if this params exists in the project because they got added after a lot of projects were created
	if data.get("Temperature"):
		ch.Temperature = data.get("Temperature")
	if data.get("TopP"):
		ch.TopP = data.get("TopP")
	if data.get("FrecuencyPenalty"):
		ch.FrecuencyPenalty = data.get("FrecuencyPenalty")
	if data.get("PresencePenalty"):
		ch.PresencePenalty = data.get("PresencePenalty")
	
	return ch
