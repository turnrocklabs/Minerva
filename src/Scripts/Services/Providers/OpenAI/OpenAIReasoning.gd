class_name OpenAIReasoning
extends RefCounted
## The API model-list endpoint has no capability metadata. Only advertise
## documented exact identities; an unknown model can use its API default.
## https://developers.openai.com/api/docs/models/gpt-5.2
## https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_new_params_and_tools

static func levels(model: String) -> Array:
	match model:
		"gpt-5.2", "gpt-5.2-2025-12-11":
			return ["none", "low", "medium", "high", "xhigh"]
		"gpt-5", "gpt-5-2025-08-07", "gpt-5-mini", "gpt-5-mini-2025-08-07", "gpt-5-nano", "gpt-5-nano-2025-08-07":
			return ["minimal", "low", "medium", "high"]
	return []
