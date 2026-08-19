extends SceneTree
## Chat tab groups — LIVE integration (DCR 01a017494904).
##
## Run: godot --headless --path src --script test/test_chat_groups_integration.gd
##
## test_chat_groups.gd covers the model and the pure filter decision. This suite
## covers the half that unit tests structurally cannot: a real Chat.tscn with a
## real ChatPane on a real TabContainer, so the ChatList[i] <-> tab i coupling,
## the dock mount, and the actual set_tab_hidden() calls are exercised rather
## than simulated. "Built" is not "wired"; this is what proves the wiring.
##
## SingletonObject cannot be named at compile time in a --script harness (the
## autoload global is not registered when this file is compiled), so it is
## fetched by node path after the tree comes up.

var _pass := 0
var _fail := 0
var _so: Node = null
var _pane = null
var _reg = null


func check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== Chat tab groups — live pane (DCR 01a017494904) ===\n")
	await process_frame
	await process_frame

	_so = root.get_node_or_null("SingletonObject")
	if _so == null:
		printerr("FATAL: SingletonObject autoload not present")
		quit(1)
		return

	var scn = load("res://Scenes/Chat.tscn")
	if scn == null:
		printerr("FATAL: Chat.tscn failed to load")
		quit(1)
		return
	var chat_scene = scn.instantiate()
	root.add_child(chat_scene)
	await process_frame
	await process_frame

	_pane = chat_scene.find_child("tcChats", true, false)
	if _pane == null:
		printerr("FATAL: tcChats not found in Chat.tscn")
		quit(1)
		return
	_reg = _so.chat_groups

	await test_dock_mount()
	await test_tabs_track_chatlist()
	await test_group_filter_hides_without_reparenting()
	await test_new_chat_lands_in_the_active_group()
	await test_delete_is_a_state_not_a_removal()
	await test_empty_group_surfaces_the_buffer_control()
	await test_group_pruning_and_dangling_ids()
	await test_dock_card_row()
	await test_group_delete_and_undo()
	await test_mcp_parity()

	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ── Helpers ───────────────────────────────────────────────────────────

## Add a chat the way every production path does: append to ChatList, then
## render_history(). Going through the real entry point is the point.
func _add_chat(chat_name: String):
	var ChatHistoryScript = load("res://Scripts/Models/ChatHistory.gd")
	var provider = _so.API_MODEL_PROVIDER_SCRIPTS.values()[1].new()
	var history = ChatHistoryScript.new(provider)
	history.HistoryName = chat_name
	_so.ChatList.append(history)
	_pane.render_history(history)
	return history


func _visible_tab_titles() -> Array:
	var out: Array = []
	for i in range(_pane.get_tab_count()):
		if not _pane.is_tab_hidden(i):
			out.append(_pane.get_tab_title(i))
	return out


func _reset() -> void:
	_pane.clear_all_chats()
	_so.ChatList.clear()
	_reg.clear()
	_pane.set_active_group("__all__")


# ── Tests ─────────────────────────────────────────────────────────────

func test_dock_mount() -> void:
	print("\n[live] dock mounts above the tab strip")
	var dock = _pane.get_group_dock()
	check("dock exists", dock != null)
	if dock == null:
		return
	check("dock is a sibling of the tab container", dock.get_parent() == _pane.get_parent())
	check("dock sits ABOVE the tab strip", dock.get_index() < _pane.get_index())
	check("expanded height is 68px", int(dock.custom_minimum_size.y) == 68)
	dock.set_collapsed(true)
	check("collapsed height is 24px", int(dock.custom_minimum_size.y) == 24)
	dock.set_collapsed(false)
	check("re-expands to 68px", int(dock.custom_minimum_size.y) == 68)


func test_tabs_track_chatlist() -> void:
	print("\n[live] ChatList index == tab index")
	_reset()
	_add_chat("Alpha")
	_add_chat("Beta")
	_add_chat("Gamma")
	await process_frame

	check("three tabs exist", _pane.get_tab_count() == 3)
	check("ChatList has three entries", _so.ChatList.size() == 3)
	var aligned := true
	for i in range(_so.ChatList.size()):
		if _pane.get_tab_title(i) != _so.ChatList[i].HistoryName:
			aligned = false
	check("every ChatList[i] matches tab i", aligned)


func test_group_filter_hides_without_reparenting() -> void:
	print("\n[live] filtering hides, never reparents")
	_reset()
	var a = _add_chat("Alpha")
	var b = _add_chat("Beta")
	_add_chat("Gamma")
	await process_frame

	var gid: String = _reg.create_group("Market research")
	check("set_chat_group accepts a real group", _pane.set_chat_group(a, gid))
	check("set_chat_group rejects an unknown group", not _pane.set_chat_group(b, "grp_nope"))
	check("rejected move left Beta ungrouped", str(b.ChatGroupId) == "")

	_pane.set_active_group(gid)
	await process_frame
	check("only the grouped chat is visible", _visible_tab_titles() == ["Alpha"])

	# The invariant the whole design rests on: hidden tabs are still children in
	# the same order, so every ChatList index site keeps working.
	check("tab COUNT is unchanged by filtering", _pane.get_tab_count() == 3)
	check("ChatList is unchanged by filtering", _so.ChatList.size() == 3)
	check("ChatList[1] is still Beta", _so.ChatList[1].HistoryName == "Beta")
	check("current tab is the visible one", _pane.current_tab == 0)

	_pane.set_active_group("__ungrouped__")
	await process_frame
	check("Ungrouped shows the other two", _visible_tab_titles() == ["Beta", "Gamma"])
	check("current tab moved off the hidden tab", not _pane.is_tab_hidden(_pane.current_tab))

	_pane.set_active_group("__all__")
	await process_frame
	check("All shows everything again", _visible_tab_titles().size() == 3)

	check("count_in_group counts the group", _pane.count_in_group(gid) == 1)
	check("count_in_group counts ungrouped", _pane.count_in_group("__ungrouped__") == 2)
	check("count_in_group counts all", _pane.count_in_group("__all__") == 3)


func test_new_chat_lands_in_the_active_group() -> void:
	print("\n[live] a chat created under a group stays visible")
	_reset()
	_add_chat("Alpha")
	var gid: String = _reg.create_group("Smart remote v2")
	_pane.set_chat_group(_so.ChatList[0], gid)
	_pane.set_active_group(gid)
	await process_frame

	# The failure this guards: an agent-spawned chat landing in Ungrouped while a
	# group is selected is hidden the instant it appears, so it looks like it was
	# never created.
	var spawned = _add_chat("Spawned by agent")
	await process_frame
	check("new chat inherited the active group", str(spawned.ChatGroupId) == gid)
	check("new chat is visible, not silently filtered out", _visible_tab_titles().has("Spawned by agent"))

	# A clone belongs beside its original regardless of the active view.
	_pane.set_active_group("__all__")
	await process_frame
	_pane.clone_chat(0)
	await process_frame
	var clone = _so.ChatList[_so.ChatList.size() - 1]
	check("clone inherited the ORIGINAL's group, not the active view", str(clone.ChatGroupId) == gid)


func test_delete_is_a_state_not_a_removal() -> void:
	print("\n[live] delete-as-state round trip")
	_reset()
	var a = _add_chat("Alpha")
	_add_chat("Beta")
	await process_frame
	var gid: String = _reg.create_group("Q3 planning")
	_pane.set_chat_group(a, gid)
	a.HistoryItemList.append(load("res://Scripts/Models/ChatHistoryItem.gd").new())
	var msg_count: int = a.HistoryItemList.size()

	check("delete_chat reports success", _pane.delete_chat(a))
	await process_frame
	check("the tab was NOT removed", _pane.get_tab_count() == 2)
	check("ChatList still holds the chat", _so.ChatList.size() == 2)
	check("the deleted chat is hidden", not _visible_tab_titles().has("Alpha"))
	check("its history survives intact", a.HistoryItemList.size() == msg_count)
	check("its group was parked, not kept", str(a.ChatGroupId) == "" and str(a.PreDeleteGroupId) == gid)
	check("the emptied group was pruned", not _reg.has_group(gid))
	check("deleting again is refused", not _pane.delete_chat(a))

	_pane.set_active_group("__deleted__")
	await process_frame
	check("the Deleted view shows it", _visible_tab_titles() == ["Alpha"])
	check("the Deleted view hides live chats", not _visible_tab_titles().has("Beta"))

	check("list_deleted_chats finds it", _pane.list_deleted_chats().size() == 1)
	check("restore_last_deleted_chat succeeds", _pane.restore_last_deleted_chat())
	await process_frame
	check("chat is live again", not a.Deleted)
	# Its group was pruned while it was away, so it comes back ungrouped rather
	# than pointing at an id that no longer exists.
	check("restored into Ungrouped after the group was pruned", str(a.ChatGroupId) == "")
	check("parked group was cleared", str(a.PreDeleteGroupId) == "")

	_pane.set_active_group("__all__")
	await process_frame
	check("it is visible again in All", _visible_tab_titles().has("Alpha"))

	# Purge is the only thing that actually frees a chat, and it is explicit.
	check("purge with nothing deleted frees nothing", _pane.purge_deleted_chats(-1) == 0)
	_pane.delete_chat(a)
	await process_frame
	check("purge frees the deleted chat", _pane.purge_deleted_chats(-1) == 1)
	await process_frame
	check("purged chat left the tab strip", _pane.get_tab_count() == 1)
	check("purged chat left ChatList", _so.ChatList.size() == 1)
	check("the survivor is Beta", _so.ChatList[0].HistoryName == "Beta")


func test_empty_group_surfaces_the_buffer_control() -> void:
	print("\n[live] an empty group does not strand the pane")
	_reset()
	_add_chat("Alpha")
	await process_frame
	var gid: String = _reg.create_group("Nothing in here")
	_pane.set_active_group(gid)
	await process_frame

	check("no tab is visible", _visible_tab_titles().is_empty())
	# The old archive-only filter's "switch to first visible" loop silently did
	# nothing here, leaving the previous chat's content under an empty strip.
	check("the buffer control is showing instead", _pane.buffer_control_chats.visible)

	_pane.set_active_group("__all__")
	await process_frame
	check("returning to All hides the buffer control again", not _pane.buffer_control_chats.visible)


func test_group_pruning_and_dangling_ids() -> void:
	print("\n[live] pruning and dangling ids")
	_reset()
	var a = _add_chat("Alpha")
	await process_frame
	var gid: String = _reg.create_group("Temp")
	_pane.set_chat_group(a, gid)
	check("group is live while a chat holds it", _reg.has_group(gid))

	_pane.set_active_group(gid)
	_pane.set_chat_group(a, "")
	await process_frame
	check("group vanished when its last chat left", not _reg.has_group(gid))
	# The active view pointed at the group that just disappeared; it must fall
	# back rather than leave the user in a view that can never contain a tab.
	check("active view fell back to All", _pane.get_active_group_id() == "__all__")
	check("the chat is visible again", _visible_tab_titles() == ["Alpha"])

	# A chat naming a group that no longer exists must resolve as ungrouped, not
	# become unreachable in every view.
	a.ChatGroupId = "grp_ghost"
	_pane._apply_tab_filters()
	await process_frame
	check("dangling id is still visible in All", _visible_tab_titles() == ["Alpha"])
	_pane.set_active_group("__ungrouped__")
	await process_frame
	check("dangling id resolves as Ungrouped", _visible_tab_titles() == ["Alpha"])
	a.ChatGroupId = ""
	_pane.set_active_group("__all__")


func test_dock_card_row() -> void:
	print("\n[live] dock card row")
	_reset()
	_add_chat("Alpha")
	_add_chat("Beta")
	await process_frame
	var g1: String = _reg.create_group("Market research")
	_pane.set_chat_group(_so.ChatList[0], g1)
	_pane._refresh_group_dock()
	await process_frame

	var cards: Array = _pane.build_group_card_snapshot()
	var kinds: Array = []
	var names: Array = []
	for c in cards:
		kinds.append(int(c["kind"]))
		names.append(str(c["name"]))
	# Kind enum: GROUP 0, ALL 1, UNGROUPED 2, DELETED 3, ADD 4.
	check("row starts with All", kinds[0] == 1)
	check("row ends with the + card", kinds[kinds.size() - 1] == 4)
	check("the group has a card", names.has("Market research"))
	check("Ungrouped appears once a group exists", names.has("Ungrouped"))
	check("Deleted is absent while nothing is deleted", not names.has("Deleted"))

	var all_count := 0
	var grp_count := 0
	for c in cards:
		if int(c["kind"]) == 1:
			all_count = int(c["count"])
		elif str(c["name"]) == "Market research":
			grp_count = int(c["count"])
	check("All card counts both chats", all_count == 2)
	check("group card counts its one chat", grp_count == 1)

	_pane.delete_chat(_so.ChatList[1])
	await process_frame
	var names2: Array = []
	for c in _pane.build_group_card_snapshot():
		names2.append(str(c["name"]))
	check("Deleted card appears once something is deleted", names2.has("Deleted"))

	var dock = _pane.get_group_dock()
	check("dock rendered a card per snapshot entry",
		dock != null and dock.get_edge_state().has("max_scroll"))


func test_group_delete_and_undo() -> void:
	print("\n[live] explicit group delete + undo")
	_reset()
	var a = _add_chat("Alpha")
	var b = _add_chat("Beta")
	var c = _add_chat("Gamma")
	await process_frame

	var g1: String = _reg.create_group("Doomed")
	var g2: String = _reg.create_group("Survivor")
	_pane.set_chat_group(a, g1)
	_pane.set_chat_group(b, g1)
	_pane.set_chat_group(c, g2)
	await process_frame

	check("nothing to undo before any delete", not _pane.can_undo_group_delete())
	var bad: Dictionary = _pane.undo_group_delete()
	check("undo with no history reports failure", not bool(bad.get("ok", false)))

	check("delete of an unknown group fails", not bool(_pane.delete_group("grp_nope").get("ok", false)))
	check("reassigning a group to itself fails", not bool(_pane.delete_group(g1, g1).get("ok", false)))
	check("unknown reassign target fails", not bool(_pane.delete_group(g1, "grp_nope").get("ok", false)))
	check("failed deletes left the group alone", _reg.has_group(g1))

	_pane.set_active_group(g1)
	var res: Dictionary = _pane.delete_group(g1, "")
	await process_frame
	check("delete reports success", bool(res.get("ok", false)))
	check("the group is gone", not _reg.has_group(g1))
	# The chats are NOT deleted — that is the whole difference between deleting a
	# group and deleting its chats.
	check("its chats survive", _so.ChatList.size() == 3)
	check("its chats are ungrouped", str(a.ChatGroupId) == "" and str(b.ChatGroupId) == "")
	check("both chats reported as moved", res.get("chat_ids", []).size() == 2)
	check("the other group is untouched", _reg.has_group(g2) and str(c.ChatGroupId) == g2)
	check("active view fell back off the deleted group", _pane.get_active_group_id() == "__all__")
	check("all three chats are visible", _visible_tab_titles().size() == 3)

	check("undo is now available", _pane.can_undo_group_delete())
	var undone: Dictionary = _pane.undo_group_delete()
	await process_frame
	check("undo reports success", bool(undone.get("ok", false)))
	# Restoring the ORIGINAL id matters: any chat still carrying it becomes valid
	# again without a rewrite.
	check("group came back with its original id", str(undone.get("group_id", "")) == g1)
	check("group came back with its name", str(undone.get("name", "")) == "Doomed")
	check("members were reattached", str(a.ChatGroupId) == g1 and str(b.ChatGroupId) == g1)
	check("undo is one level deep", not _pane.can_undo_group_delete())

	# Reassignment moves chats into another group rather than orphaning them.
	var res2: Dictionary = _pane.delete_group(g1, g2)
	await process_frame
	check("reassigning delete succeeds", bool(res2.get("ok", false)))
	check("chats landed in the target group", str(a.ChatGroupId) == g2 and str(b.ChatGroupId) == g2)
	check("target group now counts all three", _pane.count_in_group(g2) == 3)

	# A deleted chat's PARKED group must be rewritten too, or restoring it would
	# resurrect a group that no longer exists.
	_reset()
	var d = _add_chat("Delta")
	await process_frame
	var g3: String = _reg.create_group("Parked")
	_pane.set_chat_group(d, g3)
	_pane.delete_chat(d)
	await process_frame
	check("deleting the last chat pruned the group", not _reg.has_group(g3))
	check("the chat parked a now-dead group id", str(d.PreDeleteGroupId) == g3)
	_pane.restore_chat(d)
	await process_frame
	check("restore resolved the dead id to Ungrouped", str(d.ChatGroupId) == "")


func test_mcp_parity() -> void:
	print("\n[live] MCP parity")
	# A capability means a GUI affordance AND an MCP verb. The dock's actions
	# each need a counterpart an agent can call, so pin the whole set.
	#
	# MCPChatTools.gd is load()ed here rather than preload()ed at the top: it
	# names SingletonObject at class level, and a --script harness cannot resolve
	# the autoload global when its OWN file is compiled.
	var Mod = load("res://Scripts/Services/MCP/Modules/MCPChatTools.gd")
	check("MCPChatTools loads", Mod != null)
	if Mod == null:
		return
	var names: Array = Mod.new().get_tool_names()

	var required := {
		"minerva_list_chat_groups": "read groups",
		"minerva_create_chat_group": "create",
		"minerva_rename_chat_group": "update",
		"minerva_delete_chat_group": "delete",
		"minerva_undo_chat_group_delete": "undo delete",
		"minerva_set_chat_group": "move a chat between groups",
		"minerva_select_chat_group": "the dock's card click",
		"minerva_list_deleted_chats": "browse the Deleted group",
		"minerva_restore_chat": "undo a chat delete",
		"minerva_purge_deleted_chats": "empty the Deleted group",
	}
	for verb in required.keys():
		check("MCP verb %s (%s)" % [verb, required[verb]], names.has(verb))

	# Every declared name must actually dispatch, or the tool is registered and
	# then errors at call time.
	var mod = Mod.new()
	var undispatched: Array = []
	for verb in required.keys():
		var res = mod.handle(verb, {})
		if res is Dictionary and str(res.get("error", "")).begins_with("Unknown tool"):
			undispatched.append(verb)
	check("every group verb is dispatched in handle()", undispatched.is_empty())
	if not undispatched.is_empty():
		printerr("    undispatched: %s" % str(undispatched))
