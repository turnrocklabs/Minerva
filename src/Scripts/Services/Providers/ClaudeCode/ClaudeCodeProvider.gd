class_name ClaudeCodeProvider
extends BaseProvider
## Provider that wraps the official Claude Code CLI for Max/Pro subscribers.
## Spawns `claude -p` process for each request, parses JSON output.
##
## Benefits:
## - ToS compliant (uses official Anthropic tool)
## - No OAuth hacking required
## - $0 additional cost for Max subscribers
##
## Limitations:
## - No streaming (full response at once)
## - No image input support (CLI limitation)
## - Slightly slower (process spawn overhead)
## - Requires Claude Code CLI installed

## Path to claude CLI executable
var cli_path: String = "claude"


func _init():
	provider_name = "Claude Code"
	PROVIDER = SingletonObject.API_PROVIDER.CLAUDE_CODE
	model_name = "sonnet"  # Default to sonnet, CLI alias
	short_name = "CC"
	display_name = "Claude Code (Max/Pro)"

	# Free for subscribers
	input_token_cost = 0.0
	output_token_cost = 0.0

	# Capability flags
	supports_temperature = false  # CLI doesn't expose this
	supports_top_p = false
	supports_system_prompt = true


func generate_content(prompt: Array[Variant], additional_params: Dictionary = {}) -> BotResponse:
	var bot_response := BotResponse.new()
	bot_response.provider = self

	# Convert prompt array to conversation format
	var prompt_text := _format_conversation(prompt)

	# Add system prompt if present
	var system_text: String = additional_params.get("system", "")
	if not system_text.is_empty():
		prompt_text = "[SYSTEM]: %s\n\n%s" % [system_text, prompt_text]

	# Run CLI (blocking call - runs synchronously)
	var result := _run_claude_cli(prompt_text)

	if result.has("error"):
		bot_response.error = result["error"]
		return bot_response

	# Parse response from Claude Code CLI JSON format:
	# {
	#   "type": "result",
	#   "result": "The response text...",
	#   "session_id": "abc123",
	#   "usage": {"input_tokens": N, "output_tokens": N, ...},
	#   "total_cost_usd": 0.0
	# }
	bot_response.text = result.get("result", "")
	bot_response.id = result.get("session_id", "")

	var usage = result.get("usage", {})
	bot_response.prompt_tokens = usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
	bot_response.completion_tokens = usage.get("output_tokens", 0)

	SingletonObject.chat_completed.emit(bot_response)
	return bot_response


## Format conversation history into a single prompt for CLI
func _format_conversation(prompt: Array[Variant]) -> String:
	var parts := PackedStringArray()

	for msg in prompt:
		var role: String = msg.get("role", "user").to_upper()
		var content = msg.get("content", "")
		var text := _extract_text_content(content)

		if not text.is_empty():
			parts.append("[%s]: %s" % [role, text])

	return "\n\n".join(parts)


## Extract text from content (handles string or array of content blocks)
func _extract_text_content(content: Variant) -> String:
	if content is String:
		return content

	if content is Array:
		var texts := PackedStringArray()
		for block in content:
			if block is Dictionary:
				if block.get("type") == "text":
					texts.append(block.get("text", ""))
		return "\n".join(texts)

	return ""


## Run claude CLI and return parsed result
func _run_claude_cli(prompt_text: String) -> Dictionary:
	# Build arguments - use --print flag (short form -p) for non-interactive mode
	var args := PackedStringArray([
		"--print", prompt_text,
		"--output-format", "json",
		"--max-turns", "1",
		"--no-input",  # Don't wait for user input
	])

	# Add model if not default (sonnet is the CLI default)
	if model_name != "sonnet":
		args.append("--model")
		args.append(model_name)

	print("[ClaudeCode] Prompt length: %d chars" % prompt_text.length())
	print("[ClaudeCode] Running: claude %s" % " ".join(args).left(100))

	# Execute CLI (blocking call)
	var output := []
	var exit_code := OS.execute(cli_path, args, output, true, true)  # read_stderr=true

	print("[ClaudeCode] Exit code: %d, output lines: %d" % [exit_code, output.size()])

	# Combine output lines
	var json_str := ""
	for line in output:
		json_str += str(line)

	if json_str.is_empty():
		return {"error": "CLI returned empty response (exit code %d)" % exit_code}

	print("[ClaudeCode] Raw output: %s" % json_str.left(200))

	# Parse JSON output - CLI may return JSON even on error
	var parsed = JSON.parse_string(json_str)
	if parsed == null:
		return {"error": "Failed to parse CLI JSON: %s" % json_str.left(500)}

	# Check for API errors in the response
	if parsed.get("is_error", false):
		var error_msg: String = parsed.get("result", "Unknown API error")
		return {"error": error_msg}

	return parsed


func wrap_memory(item: Note) -> Variant:
	# Only support text notes - images not supported by CLI
	if item.type == Note.Type.TEXT:
		return (item.get_controls_container() as NoteTextControls).content

	push_warning("[ClaudeCodeProvider] Image notes not supported (CLI limitation)")
	return ""


func Format(chat_item: ChatHistoryItem) -> Variant:
	var role: String

	match chat_item.Role:
		ChatHistoryItem.ChatRole.USER:
			role = "user"
		ChatHistoryItem.ChatRole.ASSISTANT, ChatHistoryItem.ChatRole.MODEL:
			role = "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			role = "system"
		_:
			role = "user"

	# Collect text notes only (no image support)
	var text_notes := PackedStringArray()

	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)
		elif note is Image:
			push_warning("[ClaudeCodeProvider] Skipping image - not supported by CLI")

	var notes_section := ""
	if not text_notes.is_empty():
		notes_section = "### Reference Information ###\n"
		notes_section += "\n\n".join(text_notes)
		notes_section += "\n### End Reference Information ###\n\n"

	var full_text := "%s%s" % [notes_section, chat_item.Message]
	full_text = full_text.strip_edges()

	return {
		"role": role,
		"content": full_text
	}


func estimate_tokens(input) -> int:
	return roundi(input.get_slice_count(" ") * 1.335)


func estimate_tokens_from_prompt(input: Array[Variant]) -> float:
	var all_messages: Array[String] = []
	for msg: Dictionary in input:
		var content = msg.get("content")
		if content is String:
			all_messages.append(content)
	return float(estimate_tokens("".join(all_messages)))


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null


# ============================================================================
# Model Variants
# ============================================================================

## Claude Sonnet via Claude Code CLI
class Sonnet extends ClaudeCodeProvider:
	func _init():
		super()
		model_name = "sonnet"  # CLI alias for latest Sonnet
		short_name = "CCS"
		display_name = "Claude Code Sonnet"


## Claude Opus via Claude Code CLI
class Opus extends ClaudeCodeProvider:
	func _init():
		super()
		model_name = "opus"  # CLI alias for latest Opus
		short_name = "CCO"
		display_name = "Claude Code Opus"
