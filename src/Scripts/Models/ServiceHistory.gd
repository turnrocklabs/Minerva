class_name ServiceHistory
extends RefCounted

# Don't reorder, only add new entries
enum ServiceType {
	NONE,
	CHAT,
	NOTES,
	COCO,
}

var service_type: ServiceType

var HistoryId: String:
	set(value): SingletonObject.call_deferred("save_state", false); HistoryId = value

var HistoryName: String:
	set(value): SingletonObject.call_deferred("save_state", false); HistoryName = value

var HistoryItemList: Array[ChatHistoryItem]:
	set(value): SingletonObject.call_deferred("save_state", false); HistoryItemList = value

var HasUsedSystemPrompt: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); HasUsedSystemPrompt = value

## Whether the system prompt is enabled (sent to model). Separate from HasUsedSystemPrompt
## so user can disable without deleting the prompt text.
var SystemPromptEnabled: bool = true:
	set(value): SingletonObject.call_deferred("save_state", false); SystemPromptEnabled = value

var Temperature: float = 1:
	set(value): SingletonObject.call_deferred("save_state", false); Temperature = value

var TopP: float = 1:
	set(value): SingletonObject.call_deferred("save_state", false); TopP = value

var FrequencyPenalty: float = 0:
	set(value): SingletonObject.call_deferred("save_state", false); FrequencyPenalty = value

var PresencePenalty: float = 0:
	set(value): SingletonObject.call_deferred("save_state", false); PresencePenalty = value

## Agentic settings - per-chat configuration for agent mode
var MaxToolCallRounds: int = 10:
	set(value): SingletonObject.call_deferred("save_state", false); MaxToolCallRounds = value

var AutoContinueToolCalls: bool = true:
	set(value): SingletonObject.call_deferred("save_state", false); AutoContinueToolCalls = value

var DisabledTools: Array[String] = []:
	set(value): SingletonObject.call_deferred("save_state", false); DisabledTools = value

var AllowedDirectories: Array[String] = []:
	set(value): SingletonObject.call_deferred("save_state", false); AllowedDirectories = value

## Agentic system prompt - used instead of regular system prompt when agent mode is enabled
var AgenticSystemPrompt: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); AgenticSystemPrompt = value

## Whether the agentic system prompt is enabled
var AgenticSystemPromptEnabled: bool = true:
	set(value): SingletonObject.call_deferred("save_state", false); AgenticSystemPromptEnabled = value

## Agent context management settings (0 = use defaults from ChatPane)
var AgentMaxToolResultLength: int = 0:
	set(value): SingletonObject.call_deferred("save_state", false); AgentMaxToolResultLength = value

var AgentContextWarningThreshold: int = 0:
	set(value): SingletonObject.call_deferred("save_state", false); AgentContextWarningThreshold = value

var AgentContextHardLimit: int = 0:
	set(value): SingletonObject.call_deferred("save_state", false); AgentContextHardLimit = value

var AgentSummarizeThreshold: int = 0:
	set(value): SingletonObject.call_deferred("save_state", false); AgentSummarizeThreshold = value

## Whether agent mode is enabled for this chat
var AgentModeEnabled: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); AgentModeEnabled = value

## Whether this chat was spawned by the agent trigger system
var IsAgentChat: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); IsAgentChat = value

## The AgentDefinition.id that spawned this chat (empty if manual)
var AgentDefinitionId: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); AgentDefinitionId = value

## Active profile IDs for this chat (overrides agent/global profiles when non-empty)
var ActiveSkills: Array[String] = []:
	set(value): SingletonObject.call_deferred("save_state", false); ActiveSkills = value

## Whether this chat is archived (hidden from active tab list, retrievable)
var Archived: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); Archived = value

## Runtime-only: whether this chat has an active LLM request in flight. Not serialized.
var is_request_active: bool = false

## Why this chat's last agent turn ended. Empty string = not terminated or not an agent chat.
var termination_reason: String = ""
## Human-readable message about termination (error text, quota details, etc.)
var termination_message: String = ""

var VBox: VBoxChat
var provider: BaseProvider

static var SERIALIZER_FIELDS = [
	"HistoryId",
	"HistoryName",
	"HistoryItemList",
	"Provider",
	"ServiceType",
	"HasUsedSystemPrompt",
	"SystemPromptEnabled",
	"Temperature",
	"TopP",
	"FrequencyPenalty",
	"PresencePenalty",
	"MaxToolCallRounds",
	"AutoContinueToolCalls",
	"DisabledTools",
	"AllowedDirectories",
	"AgenticSystemPrompt",
	"AgenticSystemPromptEnabled",
	"AgentMaxToolResultLength",
	"AgentContextWarningThreshold",
	"AgentContextHardLimit",
	"AgentSummarizeThreshold",
	"AgentModeEnabled",
	"IsAgentChat",
	"AgentDefinitionId",
	"ActiveSkills",
	"Archived",
	"termination_reason",
	"termination_message",
]


## Get the API_MODEL_PROVIDERS enum value for a provider instance
static func _get_provider_enum(prov) -> int:
	if not prov:
		return SingletonObject.API_MODEL_PROVIDERS.HUMAN

	var provider_script = prov.get_script()
	for key in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		if SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key] == provider_script:
			return key

	# Fallback to first non-human provider
	return SingletonObject.API_MODEL_PROVIDERS.GPT_NANO


## Initialize with a new HistoryId
func _init(_provider, optional_historyId = null):
	self.provider = _provider
	if optional_historyId == null:
		var rng = RandomNumberGenerator.new()
		rng.randomize()
		var random_number = rng.randi()
		var hash256 = str(random_number).sha256_text()
		self.HistoryId = hash256
	else:
		self.HistoryId = optional_historyId
	HistoryItemList = []
	# Set owner_history_id so provider knows which chat it belongs to
	if _provider and _provider.has_method("get"):  # Check it's a valid object
		_provider.owner_history_id = self.HistoryId

## Calculate total session cost in dollars for all messages in this history
func get_session_cost() -> float:
	var total := 0.0
	for item in HistoryItemList:
		# Use item's provider if available, otherwise fall back to history provider
		var p: BaseProvider = item.provider if item.provider else provider
		if p:
			total += (item.InputTokens * p.input_token_cost +
					 item.OutputTokens * p.output_token_cost) / 1_000_000.0
	return total


## Get total input tokens for this session
func get_session_input_tokens() -> int:
	var total := 0
	for item in HistoryItemList:
		total += item.InputTokens
	return total


## Get total output tokens for this session
func get_session_output_tokens() -> int:
	var total := 0
	for item in HistoryItemList:
		total += item.OutputTokens
	return total


## Creates prompt from this history using the set provider.
## The `predicate` parameter is a `Callable` that returns an `Array` of 2 booleans.
## First determines if provided item should be added to the returned list,
## while second determines if the execution of the function should stop and the value returned immediately.
func to_prompt(predicate: Callable = Callable()) -> Array[Variant]:
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

## Serialize creates a JSON representation of this instance.
func Serialize() -> Dictionary:
	var serialized_items: Array[Dictionary] = []

	for chat_history_item: ChatHistoryItem in HistoryItemList:
		var serialized_item = chat_history_item.Serialize()
		serialized_items.append(serialized_item)

	var save_dict:Dictionary = {
		"HistoryId" : HistoryId,
		"HistoryName" : HistoryName,
		"Provider": _get_provider_enum(provider),
		"ServiceType": service_type,
		"HistoryItemList" : serialized_items,
		"HasUsedSystemPrompt": HasUsedSystemPrompt,
		"SystemPromptEnabled": SystemPromptEnabled,
		"Temperature": Temperature,
		"TopP": TopP,
		"FrequencyPenalty": FrequencyPenalty,
		"PresencePenalty": PresencePenalty,
		"MaxToolCallRounds": MaxToolCallRounds,
		"AutoContinueToolCalls": AutoContinueToolCalls,
		"DisabledTools": DisabledTools,
		"AllowedDirectories": AllowedDirectories,
		"AgenticSystemPrompt": AgenticSystemPrompt,
		"AgenticSystemPromptEnabled": AgenticSystemPromptEnabled,
		"AgentMaxToolResultLength": AgentMaxToolResultLength,
		"AgentContextWarningThreshold": AgentContextWarningThreshold,
		"AgentContextHardLimit": AgentContextHardLimit,
		"AgentSummarizeThreshold": AgentSummarizeThreshold,
		"AgentModeEnabled": AgentModeEnabled,
		"IsAgentChat": IsAgentChat,
		"AgentDefinitionId": AgentDefinitionId,
		"ActiveSkills": ActiveSkills,
		"Archived": Archived,
		"termination_reason": termination_reason,
		"termination_message": termination_message,
	}
	return save_dict

static func Deserialize(data: Dictionary) -> ServiceHistory:
	# Get service type from data, default to CHAT for backwards compatibility
	var service_type_value = data.get("ServiceType", ServiceType.CHAT)
	
	# will be float if loaded from json, cast it to int
	var provider_enum_index = int(data.get("Provider", 0))
	var provider_obj: BaseProvider

	if SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(provider_enum_index):
		provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[provider_enum_index].new()
	else:
		# Fallback to second defined model, skipping the human provider
		provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.values()[1].new()

	# Create the appropriate service history type based on service_type
	var history: ServiceHistory
	match service_type_value:
		ServiceType.CHAT:
			history = ChatHistory.new(provider_obj, data.get("HistoryId"))
		ServiceType.NOTES:
			history = NotesServiceHistory.new(provider_obj, data.get("HistoryId"))
		_:
			# Default to ChatHistory for unknown types
			history = ChatHistory.new(provider_obj, data.get("HistoryId"))

	history.HistoryName = data.get("HistoryName")

	for chi_data in data.get("HistoryItemList", []):
		var chi = ChatHistoryItem.Deserialize(chi_data)
		# chi.provider = history.provider
		history.HistoryItemList.append(chi)
	
	# Check if these params exist in the project (added after initial creation)
	if data.get("Temperature"):
		history.Temperature = data.get("Temperature")
	if data.get("TopP"):
		history.TopP = data.get("TopP")
	if data.get("FrequencyPenalty"):
		history.FrequencyPenalty = data.get("FrequencyPenalty")
	if data.get("PresencePenalty"):
		history.PresencePenalty = data.get("PresencePenalty")

	# System prompt flags
	if data.has("HasUsedSystemPrompt"):
		history.HasUsedSystemPrompt = data.get("HasUsedSystemPrompt", false)
	if data.has("SystemPromptEnabled"):
		history.SystemPromptEnabled = data.get("SystemPromptEnabled", true)

	# Agentic settings (with defaults for backwards compatibility)
	if data.has("MaxToolCallRounds"):
		history.MaxToolCallRounds = int(data.get("MaxToolCallRounds", 10))
	if data.has("AutoContinueToolCalls"):
		history.AutoContinueToolCalls = data.get("AutoContinueToolCalls", true)
	if data.has("DisabledTools"):
		var disabled = data.get("DisabledTools", [])
		history.DisabledTools.assign(disabled)
	if data.has("AllowedDirectories"):
		var allowed = data.get("AllowedDirectories", [])
		history.AllowedDirectories.assign(allowed)
	if data.has("AgenticSystemPrompt"):
		history.AgenticSystemPrompt = data.get("AgenticSystemPrompt", "")
	if data.has("AgenticSystemPromptEnabled"):
		history.AgenticSystemPromptEnabled = data.get("AgenticSystemPromptEnabled", true)
	if data.has("AgentMaxToolResultLength"):
		history.AgentMaxToolResultLength = int(data.get("AgentMaxToolResultLength", 0))
	if data.has("AgentContextWarningThreshold"):
		history.AgentContextWarningThreshold = int(data.get("AgentContextWarningThreshold", 0))
	if data.has("AgentContextHardLimit"):
		history.AgentContextHardLimit = int(data.get("AgentContextHardLimit", 0))
	if data.has("AgentSummarizeThreshold"):
		history.AgentSummarizeThreshold = int(data.get("AgentSummarizeThreshold", 0))
	if data.has("AgentModeEnabled"):
		history.AgentModeEnabled = data.get("AgentModeEnabled", false)
	if data.has("IsAgentChat"):
		history.IsAgentChat = data.get("IsAgentChat", false)
	if data.has("AgentDefinitionId"):
		history.AgentDefinitionId = data.get("AgentDefinitionId", "")
	if data.has("ActiveSkills"):
		var active_sk = data.get("ActiveSkills", [])
		history.ActiveSkills.assign(active_sk)
	if data.has("Archived"):
		history.Archived = data.get("Archived", false)
	if data.has("termination_reason"):
		history.termination_reason = data.get("termination_reason", "")
	if data.has("termination_message"):
		history.termination_message = data.get("termination_message", "")

	return history
