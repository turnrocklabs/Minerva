class_name CoreActionCatalog
extends RefCounted

## The one enumeration of TurnRock/Core service actions.
##
## Core has no static model list: its "models" are the live actions of the
## services the session is allowed to use (/root/Core.services[].actions[]).
## Every consumer that needs those actions — the provider chooser's spec
## builder, the MCP model_spec resolver, and the brokered model catalog behind
## host.models.list_models("turnrock") — goes through here, so the display
## string and the `model_spec` dictionary have a single definition.
##
## An entry is {service_client_id, service_name, action_name, display,
## model_spec}, where `model_spec` is exactly what host.providers.chat and
## minerva_set_chat_model accept for that action. With no Core node — or with
## Core present but no services fetched yet — the listing is empty; there is no
## placeholder entry.


## The live Core autoload, or null when it is absent (headless tools, tests).
static func core_node() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null("Core")


## The structured model_spec that identifies one action to every host consumer.
static func spec_for(service: Service, action: Action) -> Dictionary:
	if service == null or action == null:
		return {}
	return {
		"kind": "core_action",
		"service_client_id": service.client_id,
		"service_name": service.name,
		"action_name": action.name,
	}


## Human-readable name for an action — identical to CoreProvider.model_name, so
## a listing and a live provider never disagree about what an action is called.
static func display_for(service: Service, action: Action) -> String:
	if action == null:
		return ""
	return "%s (%s)" % [service.name if service != null else "Core", action.name]


## Every action of every service Core currently exposes, in service order.
## Pass `core` to enumerate a specific node (tests); omit it for the autoload.
static func list_actions(core: Node = null) -> Array:
	var out: Array = []
	var node: Node = core if core != null else core_node()
	if node == null or not ("services" in node):
		return out
	for service: Service in node.services:
		if service == null:
			continue
		for action: Action in service.actions:
			if action == null:
				continue
			out.append({
				"service_client_id": service.client_id,
				"service_name": service.name,
				"action_name": action.name,
				"display": display_for(service, action),
				"model_spec": spec_for(service, action),
			})
	return out


## Whether Core exposes at least one action, for callers that only need the
## yes/no. Deliberately answers from list_actions() rather than counting
## services: a second derivation could say yes where the listing says nothing
## (a service holding only null actions), and the allocation is small.
static func has_actions(core: Node = null) -> bool:
	return not list_actions(core).is_empty()


## Resolve a (service_client_id, action_name) pair to the live Core objects.
## Returns {service, action}, or {} when Core is absent or nothing matches.
static func find_action(service_client_id: String, action_name: String, core: Node = null) -> Dictionary:
	var node: Node = core if core != null else core_node()
	if node == null or not ("services" in node):
		return {}
	for service: Service in node.services:
		if service == null or service.client_id != service_client_id:
			continue
		for action: Action in service.actions:
			if action != null and action.name == action_name:
				return {"service": service, "action": action}
	return {}


## Build the CoreProvider for an action, or null when it cannot be resolved.
## Callers own the returned node (it is not in the scene tree yet).
static func create_provider(service_client_id: String, action_name: String, core: Node = null) -> CoreProvider:
	var found: Dictionary = find_action(service_client_id, action_name, core)
	if found.is_empty():
		return null
	return CoreProvider.new(found["service"], found["action"])
