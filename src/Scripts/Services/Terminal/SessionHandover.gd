extends RefCounted
## Hands a role over to a replacement session: the one path that
## minerva_session_handover and the Sessions dialog's "Hand role to selected"
## both take.
##
##   1. HarnessSessionRegistry.handover — the replacement takes the role; every
##      other session holding it is marked superseded (nothing routes to it,
##      its container's Docket grant loses the role, and notify addressed to
##      its identity goes to the replacement).
##   2. NotifyDeliveryLedger.retarget — open notifications for the superseded
##      identities or the role move to the replacement and are tried at once.
##      DocketWakeups moves its unsent batches on the registry's handed_over.
##   3. Docket claims — on every open project, the items assigned to the role
##      or to a superseded identity whose W1 claim a superseded identity holds
##      are moved with docket_reassign (reason "handover: ...", override=true),
##      so each move is an event in the item's log and the old holder's next
##      protected write is refused with "not the holder: <replacement>".
##      A claim that cannot be moved is listed under claims.failed, and Docket
##      being unavailable under claims.error; the role moves regardless, so
##      routing is never held hostage by Docket.
##
## Claims are found by assignment, so a claim a superseded identity holds on
## an item assigned to someone else is not seen here.

const HarnessSessionRegistry := preload("res://Scripts/Services/Terminal/HarnessSessionRegistry.gd")
const NotifyDeliveryLedger := preload("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd")

## Docket's claim reassignment tool (Docket app W1).
const REASSIGN_TOOL := "docket_reassign"


## Moves `role` to registered session `to_identity`. `actor` is who asked
## (recorded as the actor of each claim move). Returns the registry's reply
## (success, role, to, superseded, previous_role) plus `pointers`
## ({retargeted, left_in_chat}) and `claims` ({reassigned, failed, checked,
## error?}), or {success:false, error}.
static func run(role: String, to_identity: String, actor: String) -> Dictionary:
	var moved: Dictionary = HarnessSessionRegistry.shared().handover(role, to_identity)
	if not bool(moved.get("success", false)):
		return moved
	var superseded := PackedStringArray(moved["superseded"])
	moved["pointers"] = NotifyDeliveryLedger.shared().retarget(superseded, str(moved["role"]), str(moved["to"]))
	moved["claims"] = await _reassign_claims(str(moved["role"]), superseded, str(moved["to"]),
		actor if not actor.strip_edges().is_empty() else "minerva:handover")
	return moved


static func _reassign_claims(role: String, from: PackedStringArray, to: String, actor: String) -> Dictionary:
	var out: Dictionary = {"reassigned": [], "failed": [], "checked": 0}
	if from.is_empty():
		return out
	var host = _docket_host()
	if host == null or not str(host.state) in ["ready", "degraded"]:
		out["error"] = "Docket is unavailable (%s): claims held by %s were NOT moved; move them with %s" % [
			"no Docket host" if host == null else str(host.state), ", ".join(from), REASSIGN_TOOL]
		return out
	var listed: Dictionary = await host.open_projects()
	if not listed.has("projects"):
		out["error"] = "Docket's open projects could not be listed (%s): claims held by %s were NOT moved" % [
			str(listed.get("message", listed)), ", ".join(from)]
		return out
	var holders: Dictionary = {}
	for identity: String in from:
		holders[identity.to_lower()] = true
	var principals: Array = [role]
	principals.append_array(Array(from))
	var reason: String = "handover: role %s from %s to %s" % [role, ", ".join(from), to]
	for project: Dictionary in listed["projects"]:
		var name: String = str(project.get("name", ""))
		var query: Dictionary = await host.call_tool("docket_query", {"project": name, "detail": "lean",
			"filter": {"conditions": [{"field": "assigned_to", "op": "in", "value": principals}]}})
		if query.has("error") or not query["value"].get("items") is Array:
			out["failed"].append({"project": name, "error": str(query.get("error", "no items in the reply"))})
			continue
		for item in query["value"]["items"]:
			var id: String = str(item.get("id", "")) if item is Dictionary else ""
			if id.is_empty():
				continue
			out["checked"] = int(out["checked"]) + 1
			var read: Dictionary = await host.call_tool("docket_get", {"id": id, "project": name, "include": []})
			if read.has("error"):
				out["failed"].append({"project": name, "id": id, "error": str(read["error"])})
				continue
			var holder: String = str(read["value"].get("claim_holder", ""))
			if not holders.has(holder.to_lower()):
				continue
			var moved: Dictionary = await host.call_tool(REASSIGN_TOOL, {"id": id, "project": name,
				"to": to, "reason": reason, "actor": actor, "override": true})
			if moved.has("error"):
				out["failed"].append({"project": name, "id": id, "holder": holder, "error": str(moved["error"])})
			else:
				out["reassigned"].append({"project": name, "id": id, "from": holder})
	return out


static func _docket_host():
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var so: Node = tree.root.get_node_or_null("SingletonObject")
	return so.get("docket_host") if so != null else null
