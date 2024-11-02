class_name ChatGPTBase
extends BaseProvider


# this params are only used in chatGPT
var temperature: float = 1
var topP: float = 1
var frecuencyPenalty: float = 0
var presencePenalty: float = 0

# Change the `model_name` and `short_name` in _ready function

func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI

func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response:= BotResponse.new()

	if not response.success:
		bot_response.error = response.message
		return bot_response

	var data: Variant
	if response.http_request_result == HTTPRequest.RESULT_SUCCESS:
		# since the request was completed, construct the data
		data = JSON.parse_string(response.body.get_string_from_utf8())

		# if the request was successful, parse it to bot response
		if (response.response_code >= 200 and response.response_code <= 299):
			bot_response = to_bot_response(data)
		# otherwise extract the error
		else:
			
			if "error" in data:
				bot_response.error = data["error"]["message"]
			else:
				bot_response.error = "Unexpected error occured while generating the response"

	else:
		push_error("Invalid result. Response: %s", response.response_code)
		bot_response.error = "Unexpected error occured with HTTP Client. Code %s" % response.http_request_result
		return

	return bot_response


# https://platform.openai.com/docs/guides/text-generation/chat-completions-api
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):

	var request_body = {
		"model": model_name,
		"messages": prompt,
	}

	request_body.merge(additional_params)
	
	var body_stringified: String = JSON.stringify(request_body)
	
	var response: RequestResults = await make_request(
		"%s/v1/chat/completions" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		[
			"Content-Type: application/json",
			"Authorization: Bearer %s" % API_KEY
		],
	)

	var item = _parse_request_results(response)
	
	SingletonObject.chat_completed.emit(item)

	return item


func Format(chat_item: ChatHistoryItem) -> Variant:
	var role: String

	match chat_item.Role:
		ChatHistoryItem.ChatRole.USER:
			role = "user"
		ChatHistoryItem.ChatRole.ASSISTANT:
			role = "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			role = "system"
		ChatHistoryItem.ChatRole.MODEL:
			role = "assistant"
	
	# Get all image captions in array of strings
	var image_captions_array = chat_item.Images.map(func(img: Image): return img.get_meta("caption", "No caption."))
	var image_captions: String

	# if there are images, construct the image captions into one string for prompt
	if not image_captions_array.is_empty():
		image_captions = "Image Caption: %s" % "\n".join(image_captions_array)
	
	var text_notes = chat_item.InjectedNotes.filter(func(note): return note is String)

	var text = """
		%s
		%s
		%s
	""" % [image_captions, "\n".join(text_notes), chat_item.Message]

	text = text.strip_edges()

	return {
		"role": role,
		"content": text
	}


func wrap_memory(item: MemoryItem) -> Variant:
	var output: String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += item.Content
	output += "### End Reference Information ###\n\n"
	output += "Respond to the user's message: \n\n"
	return output

# {
#   "id": "chatcmpl-9LJ12Ijrr2MAwBtHQdO3xHMut1pAn",
#   "object": "chat.completion",
#   "created": 1714865012,
#   "model": "gpt-3.5-turbo-0125",
#   "choices": [
#     {
#       "index": 0,
#       "message": {
#         "role": "assistant",
#         "content": "Hello! How can I assist you today?"
#       },
#       "logprobs": null,
#       "finish_reason": "stop"
#     }
#   ],
#   "usage": {
#     "prompt_tokens": 8,
#     "completion_tokens": 9,
#     "total_tokens": 17
#   },
#   "system_fingerprint": "fp_3b956da36b"
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	
	# set the used provider so update model name
	response.provider = self

	# the id will be useful if we need to complete the response with second request
	response.id = data["id"]

	var finish_reason = data["choices"][0]["finish_reason"]

	if finish_reason == "length":
		response.complete = false
	
	response.prompt_tokens = data["usage"]["prompt_tokens"]
	response.completion_tokens = data["usage"]["completion_tokens"]

	response.text = data["choices"][0]["message"]["content"]
	
	return response


func estimate_tokens(input) -> int:
	return roundi(input.get_slice_count(" ") * token_cost)
	print(input)


func estimate_tokens_from_prompt(input: Array[Variant]):
	var all_messages: Array[String] = []

	# get all user messages
	for msg: Dictionary in input:
		# if msg["role"] != "user": continue
		all_messages.append(msg["content"])
	
	return estimate_tokens("".join(all_messages))


func continue_partial_response(_partial_chi: ChatHistoryItem):
	var chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	chi.Message = "finish"

	return chi
