## botresponse enables me to standardize responses from any chatbot
class_name BotResponse
extends RefCounted


var id: StringName
var text: String

var hcp_data: Dictionary

## Image associated with this response.
## Caption can be set by setting the `caption` meta field of this object
var image: Image

## Setting the error property marks this response as invalid
var error: String

var provider: BaseProvider

# if the message is not completed due to token limit or any other reason, but can be continued
var complete:= true


var prompt_tokens: int
var completion_tokens: int
var cache_creation_tokens: int
var cache_read_tokens: int

var total_tokens: int:
	get: return prompt_tokens + completion_tokens


## Rate limit flag — set when the provider returns HTTP 429 or a rate limit error
var is_rate_limited: bool = false

## Seconds to wait before retrying, as advised by the provider. -1 = unknown.
var rate_limit_retry_after: float = -1.0

## Tool calls requested by the LLM (for agentic mode)
## Each item: {id: String, name: String, arguments: Dictionary}
var tool_calls: Array[Dictionary] = []

## Reasoning/thinking traces for this response (display-only metadata).
## Position-aware sequence parallel to ToolExecutions, NOT a single string —
## models can interleave multiple thinking segments per turn.
## Each item: {kind: String, text: String, redacted: bool, order: int}
## kind: "thinking" (raw chain-of-thought) | "summary" (provider summary)
var reasoning: Array[Dictionary] = []

## Raw provider reasoning items for round-trip replay within the in-flight agent
## tool loop (e.g. OpenAI Responses reasoning items with encrypted_content).
## Transient — display-only metadata, NOT persisted to .minproj.
var reasoning_raw: Array = []

## Whether this response requires tool execution before continuing
var requires_tool_response: bool:
	get: return not tool_calls.is_empty()


## Check if this response has tool calls
func has_tool_calls() -> bool:
	return not tool_calls.is_empty()


## Add a tool call to this response
func add_tool_call(tool_id: String, tool_name: String, arguments: Dictionary) -> void:
	tool_calls.append({
		"id": tool_id,
		"name": tool_name,
		"arguments": arguments
	})


## Check if this response carries any reasoning/thinking segments
func has_reasoning() -> bool:
	return not reasoning.is_empty()


## Append a reasoning/thinking segment, preserving arrival order.
func add_reasoning(segment_text: String, kind: String = "thinking", redacted: bool = false) -> void:
	reasoning.append({
		"kind": kind,
		"text": segment_text,
		"redacted": redacted,
		"order": reasoning.size()
	})


func _to_string():
	if not error:
		if has_tool_calls():
			return "Bot Response %s: [%d tool calls]" % [id, tool_calls.size()]
		return "Bot Response %s: %s..." % [id, text.substr(0, 10)]
	else:
		return "Bot Response %s (Invalid): %s..." % [id, error.substr(0, 10)]
