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
var MaxToolCallRounds: int = 15:
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

## Per-chat reasoning effort for providers that use the effort picker
## (Anthropic/OpenRouter/Gemini/ChatGPT). "" = provider default (no override);
## other values: "off", or a level from the provider's reasoning_effort_levels().
var ReasoningEffort: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); ReasoningEffort = value

## Whether to request a human-readable reasoning summary (ChatGPT). Default on.
var ReasoningSummary: bool = true:
	set(value): SingletonObject.call_deferred("save_state", false); ReasoningSummary = value

## Whether this chat was spawned by the agent trigger system
var IsAgentChat: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); IsAgentChat = value

## The AgentDefinition.id that spawned this chat (empty if manual)
var AgentDefinitionId: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); AgentDefinitionId = value

## Active profile IDs for this chat (overrides agent/global profiles when non-empty)
var ActiveSkills: Array[String] = []:
	set(value): SingletonObject.call_deferred("save_state", false); ActiveSkills = value

## Chat-scoped knowledge acquired through knowledge tools.
## Each entry is a Dictionary with stable fields like id/type/title/content.
var AcquiredKnowledge: Array[Dictionary] = []:
	set(value): SingletonObject.call_deferred("save_state", false); AcquiredKnowledge = value

## UUID of the note tab that stores agent tool artifacts for this chat.
var AgentNotesTabId: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); AgentNotesTabId = value

## UUID of the current floating summary note for this chat, when configured.
var AgentFloatingSummaryNoteId: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); AgentFloatingSummaryNoteId = value

## Prompt/dehydration telemetry for this chat.
var AgentContextTelemetry: Dictionary = {}:
	set(value): SingletonObject.call_deferred("save_state", false); AgentContextTelemetry = value

## Persisted tool memory state used by prompt projection to collapse stale tool activity.
## Structure: {version, active, compressed, recovery, status}
var AgentToolMemoryState: Dictionary = {}:
	set(value): SingletonObject.call_deferred("save_state", false); AgentToolMemoryState = value

## Whether this chat is archived (hidden from active tab list, retrievable)
var Archived: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); Archived = value

## Chat-group membership (DCR 01a017494904). Holds a ChatGroupRegistry group id,
## or "" for ungrouped. Never a display name — renames must not touch chats.
var ChatGroupId: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); ChatGroupId = value

## Soft-delete state. Replaces Undo.gd's 180-second timer: a closed chat is
## hidden, not removed, so undo is unlimited in time and survives save/load.
var Deleted: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); Deleted = value

## The group this chat was in when it was deleted. Parked here (and cleared from
## ChatGroupId) so a deleted chat cannot keep an otherwise-empty group alive;
## restore puts the chat back if that group still exists.
var PreDeleteGroupId: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); PreDeleteGroupId = value

## Unix timestamp of deletion, 0 when live. Feeds the Deleted-group purge.
var DeletedAt: int = 0:
	set(value): SingletonObject.call_deferred("save_state", false); DeletedAt = value

## Runtime-only: whether this chat has an active LLM request in flight. Not serialized.
var is_request_active: bool = false

## Static tool mode: when true, the chat has a pre-configured tool set and dynamic
## tool discovery (tool_search, list_skills, get_skill) is suppressed.
var StaticToolMode: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); StaticToolMode = value

## Tool names configured for this focused chat (source of truth for the static set).
var ConfiguredTools: Array[String] = []:
	set(value): SingletonObject.call_deferred("save_state", false); ConfiguredTools = value

## Skill names/IDs selected when creating this focused chat (for display/restore).
var ConfiguredSkills: Array[String] = []:
	set(value): SingletonObject.call_deferred("save_state", false); ConfiguredSkills = value

## Passthrough mode (chat-passthrough W2): when true, this chat is bound to a
## terminal-backed plugin provider for its whole life — the provider chooser is
## locked and never auto-falls-back (recovery is W3's relaunch affordance).
var PassthroughMode: bool = false:
	set(value): SingletonObject.call_deferred("save_state", false); PassthroughMode = value

## Terminal id the passthrough provider is bound to (empty until launch wires it).
var BoundTerminalId: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); BoundTerminalId = value

## Display name of the bound passthrough provider (for the header badge and the
## locked chooser's offline display — survives the registry entry vanishing).
var PassthroughName: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); PassthroughName = value

## Launch command for the bound terminal agent (chat-passthrough W3). Stored so
## the relaunch affordance can recreate the session after the agent/Minerva
## dies — terminal sessions are in-memory only (T3 restart semantics), so
## restart = this command + cwd into a FRESH session. Empty = bare shell.
var PassthroughCommand: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); PassthroughCommand = value

## Working directory the launch command runs in (chat-passthrough W3). Empty =
## whatever the fresh shell starts in.
var PassthroughCwd: String = "":
	set(value): SingletonObject.call_deferred("save_state", false); PassthroughCwd = value

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
	"ReasoningEffort",
	"ReasoningSummary",
	"IsAgentChat",
	"AgentDefinitionId",
	"ActiveSkills",
	"AcquiredKnowledge",
	"AgentNotesTabId",
	"AgentFloatingSummaryNoteId",
	"AgentContextTelemetry",
	"AgentToolMemoryState",
	"Archived",
	"termination_reason",
	"termination_message",
	"StaticToolMode",
	"ConfiguredTools",
	"ConfiguredSkills",
	"PluginProviderKey",
	"PassthroughMode",
	"BoundTerminalId",
	"PassthroughName",
	"PassthroughCommand",
	"PassthroughCwd",
]


## Sentinel int written into "Provider" when the active provider is a
## PluginProvider (chat-passthrough W1). Old readers (which only know the int
## field) fall through to the safe default-provider fallback in Deserialize
## rather than mis-resolving a stale enum value.
const PLUGIN_PROVIDER_SENTINEL := -1


## Get the API_MODEL_PROVIDERS enum value for a provider instance
static func _get_provider_enum(prov) -> int:
	if not prov:
		return SingletonObject.API_MODEL_PROVIDERS.HUMAN
	if prov.has_meta("dynamic_model_id"):
		return int(prov.get_meta("dynamic_model_id"))

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

	# Plugin chat-providers (chat-passthrough W1) serialize as a string key in a
	# NEW optional field; the int "Provider" stays at a safe sentinel so old
	# readers fall back to the default provider rather than mis-resolving.
	var plugin_provider_key: String = ""
	var provider_enum_value: int = _get_provider_enum(provider)
	if provider != null and "entry_key" in provider and not str(provider.entry_key).is_empty():
		plugin_provider_key = str(provider.entry_key)
		provider_enum_value = PLUGIN_PROVIDER_SENTINEL

	var save_dict:Dictionary = {
		"HistoryId" : HistoryId,
		"HistoryName" : HistoryName,
		"Provider": provider_enum_value,
		"PluginProviderKey": plugin_provider_key,
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
		"ReasoningEffort": ReasoningEffort,
		"ReasoningSummary": ReasoningSummary,
		"IsAgentChat": IsAgentChat,
		"AgentDefinitionId": AgentDefinitionId,
		"ActiveSkills": ActiveSkills,
		"AcquiredKnowledge": AcquiredKnowledge,
		"AgentNotesTabId": AgentNotesTabId,
		"AgentFloatingSummaryNoteId": AgentFloatingSummaryNoteId,
		"AgentContextTelemetry": AgentContextTelemetry,
		"AgentToolMemoryState": AgentToolMemoryState,
		"Archived": Archived,
		"ChatGroupId": ChatGroupId,
		"Deleted": Deleted,
		"PreDeleteGroupId": PreDeleteGroupId,
		"DeletedAt": DeletedAt,
		"termination_reason": termination_reason,
		"termination_message": termination_message,
		"StaticToolMode": StaticToolMode,
		"ConfiguredTools": ConfiguredTools,
		"ConfiguredSkills": ConfiguredSkills,
		"PassthroughMode": PassthroughMode,
		"BoundTerminalId": BoundTerminalId,
		"PassthroughName": PassthroughName,
		"PassthroughCommand": PassthroughCommand,
		"PassthroughCwd": PassthroughCwd,
	}
	return save_dict

static func Deserialize(data: Dictionary) -> ServiceHistory:
	# Get service type from data, default to CHAT for backwards compatibility
	var service_type_value = data.get("ServiceType", ServiceType.CHAT)
	
	# will be float if loaded from json, cast it to int
	var provider_enum_index = int(data.get("Provider", 0))
	var provider_obj: BaseProvider

	# Plugin chat-provider (chat-passthrough W1): if a key was serialized AND it
	# names a currently-registered entry, restore a PluginProvider. If the entry
	# is absent (plugin not installed/running), fall through to the int-based
	# default-provider path below — non-fatal, NO error dialog; the chat stays
	# usable with a default provider.
	var plugin_provider_key: String = str(data.get("PluginProviderKey", ""))
	if not plugin_provider_key.is_empty():
		var cpr = SingletonObject.plugin_chat_provider_registry if "plugin_chat_provider_registry" in SingletonObject else null
		if cpr != null and cpr.has_method("get_entry"):
			var entry: Dictionary = cpr.get_entry(plugin_provider_key)
			if not entry.is_empty():
				var PluginProviderScript = load("res://Scripts/Services/Providers/PluginProvider.gd")
				provider_obj = PluginProviderScript.new()
				provider_obj.configure_from_entry(entry)

	if provider_obj == null and provider_enum_index >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
		provider_obj = SingletonObject.create_dynamic_provider(provider_enum_index)
	if provider_obj == null and SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(provider_enum_index):
		provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[provider_enum_index].new()
	if provider_obj == null:
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
		history.MaxToolCallRounds = int(data.get("MaxToolCallRounds", 15))
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
	if data.has("ReasoningEffort"):
		history.ReasoningEffort = str(data.get("ReasoningEffort", ""))
	if data.has("ReasoningSummary"):
		history.ReasoningSummary = bool(data.get("ReasoningSummary", true))
	if data.has("IsAgentChat"):
		history.IsAgentChat = data.get("IsAgentChat", false)
	if data.has("AgentDefinitionId"):
		history.AgentDefinitionId = data.get("AgentDefinitionId", "")
	if data.has("ActiveSkills"):
		var active_sk = data.get("ActiveSkills", [])
		history.ActiveSkills.assign(active_sk)
	if data.has("AcquiredKnowledge"):
		var acquired: Array[Dictionary] = []
		acquired.assign(data.get("AcquiredKnowledge", []))
		history.AcquiredKnowledge = acquired
	if data.has("AgentNotesTabId"):
		history.AgentNotesTabId = data.get("AgentNotesTabId", "")
	if data.has("AgentFloatingSummaryNoteId"):
		history.AgentFloatingSummaryNoteId = data.get("AgentFloatingSummaryNoteId", "")
	if data.has("AgentContextTelemetry"):
		history.AgentContextTelemetry = data.get("AgentContextTelemetry", {})
	if data.has("AgentToolMemoryState"):
		history.AgentToolMemoryState = data.get("AgentToolMemoryState", {})
	if data.has("Archived"):
		history.Archived = data.get("Archived", false)
	if data.has("ChatGroupId"):
		history.ChatGroupId = str(data.get("ChatGroupId", ""))
	if data.has("Deleted"):
		history.Deleted = bool(data.get("Deleted", false))
	if data.has("PreDeleteGroupId"):
		history.PreDeleteGroupId = str(data.get("PreDeleteGroupId", ""))
	if data.has("DeletedAt"):
		history.DeletedAt = int(data.get("DeletedAt", 0))
	if data.has("termination_reason"):
		history.termination_reason = data.get("termination_reason", "")
	if data.has("termination_message"):
		history.termination_message = data.get("termination_message", "")
	if data.has("StaticToolMode"):
		history.StaticToolMode = data.get("StaticToolMode", false)
	if data.has("ConfiguredTools"):
		history.ConfiguredTools.assign(data.get("ConfiguredTools", []))
	if data.has("ConfiguredSkills"):
		history.ConfiguredSkills.assign(data.get("ConfiguredSkills", []))
	if data.has("PassthroughMode"):
		history.PassthroughMode = data.get("PassthroughMode", false)
	if data.has("BoundTerminalId"):
		history.BoundTerminalId = str(data.get("BoundTerminalId", ""))
	if data.has("PassthroughName"):
		history.PassthroughName = str(data.get("PassthroughName", ""))
	if data.has("PassthroughCommand"):
		history.PassthroughCommand = str(data.get("PassthroughCommand", ""))
	if data.has("PassthroughCwd"):
		history.PassthroughCwd = str(data.get("PassthroughCwd", ""))

	return history
