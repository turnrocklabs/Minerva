# Core chat models and generation options

Discover chat offerings through `minerva_list_models` with `provider: "turnrock"`, or through a plugin's `host.models.list_models("turnrock")`. Retain each returned `model_spec`:

```json
{"kind":"core_action","service_client_id":"model-chat","action_name":"qwen3:8b"}
```

The service/action tuple is identity. Display labels may repeat. A disabled, disconnected, missing or ambiguous selection fails explicitly; it does not choose another model. TurnRock's chat toggle applies to all chat callers, and plugin callers also need permission to use that provider. Speech/storage service access remains independent.

Each offering advertises `generation_options`, including supported types, constraints and defaults. Current canonical keys are `temperature`, `max_tokens`, `num_ctx` and `num_gpu`; an offering may advertise a subset. Explicit unsupported, fractional integer, nonfinite or out-of-range values fail before dispatch. Temperature `0` and GPU layers `0` are valid. Context `0` and GPU layers `-1` mean inherit and are never transmitted.

Resolution order is defaults < saved model settings < chat overrides < request overrides. Aliases are normalized within each layer before merging: nested `options.temperature`, `options.num_predict`, `options.num_ctx` and `options.num_gpu` win over the corresponding canonical field in that same layer. Consequently, request `max_tokens: 10` overrides a saved `options.num_predict: 200`; request `options.num_predict: 20` wins over request `max_tokens: 10`. The final payload contains temperature/output limit at the top level and context/GPU under `options`, with no contradictory duplicates.

## MCP and UI

Use `minerva_get_generation_options` with either `chat_id` or `model_spec` to inspect supported schema, explicit model/chat layers, effective values and their sources. Its optional `request_options` previews a request without saving it.

Use `minerva_set_generation_options` with `scope: "model"` or `"chat"` and an `options` object to replace that layer. Chat scope requires `chat_id`. An empty object clears that layer to inherited values. Include existing values you want to retain. A successful write can return a separate `effective_error` if another pre-existing layer is invalid; the write has still succeeded.

`minerva_send_message` accepts `generation_options` for one Core chat request. These overrides accompany regeneration and continuation of that turn; they do not become model/chat preferences. The AI Settings generation panel offers the same model/chat layers. Turning off **Custom** inherits; opening the panel does not create overrides.

Modern histories save an explicit map, including empty inheritance. Legacy histories had no provenance: a present `Temperature` value (including `0` or `1`) is migrated as intent. Modern empty maps do not re-import that scalar. A modern model-options map is authoritative, including after clearing it; older context/GPU preferences cannot reappear after reset.

## Council/plugin callers

Pass the discovered tuple in `host.providers.chat` together with messages and desired request overrides:

```json
{
  "model_spec": {"kind":"core_action","service_client_id":"model-chat","action_name":"qwen3:8b"},
  "messages": [{"role":"user","text":"Summarize the alternatives."}],
  "temperature": 0,
  "max_tokens": 512
}
```

Plugins may supply the four canonical keys or supported nested aliases. Private host layers and arbitrary native engine options are refused. MCP/GUI can select registered plugin chat entries using `provider: "plugin:council:council"` or the discovered plugin spec. Those entries are excluded from plugin member-model discovery and invocation, preventing Council from selecting itself recursively.

These are host-side payload guarantees. Backend alias translation and deployed engine behavior are verified separately in the service-contract integration checks.
