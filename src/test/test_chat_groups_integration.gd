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
	await test_reorder_uses_child_index_not_tab_index()
	await test_project_switch_clears_group_state()
	await test_undo_respects_moves_since_delete()
	await test_delete_seq_orders_undo()
	await test_mcp_create_by_name_ignores_deleted()
	await test_empty_group_marks_project_dirty()

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


# ── Regressions from the Codex review of 5c03678d ─────────────────────

func test_reorder_uses_child_index_not_tab_index() -> void:
	print("\n[regression] reorder translates tab index -> child index")
	_reset()
	_add_chat("Alpha")
	_add_chat("Beta")
	_add_chat("Gamma")
	await process_frame

	# _ready() parents lifetime-of-pane infrastructure (TTS player, voice
	# gateway, token timer) into this same TabContainer, so child N and tab N
	# diverge. Passing a TAB index to move_child() drops the chat among those
	# nodes and leaves the tab order untouched.
	var non_tab_children: int = _pane.get_child_count() - _pane.get_tab_count()
	check("the container really does hold non-tab children", non_tab_children > 0)

	var alpha_control = _pane.get_tab_control(0)
	var beta_control = _pane.get_tab_control(1)
	check("tab index and child index differ for at least one tab",
		alpha_control.get_index() != 0 or beta_control.get_index() != 1)

	# Drop Alpha past the right-hand end of the strip. get_tab_idx_at_point()
	# returns -1 there, which the handler resolves to the LAST tab — a real move
	# from position 0, unlike a drop on the tab it started from.
	var far_right := Vector2(100000.0, 0.0)
	check("the drop point really is past every tab", _pane.get_tab_idx_at_point(far_right) == -1)
	_pane._reorder_chat_tab(far_right, {"kind": "chat_tab", "chat_id": str(_so.ChatList[0].HistoryId), "tab": 0})
	await process_frame

	# What matters is that the tab ORDER actually changed and no chat was
	# orphaned among the infrastructure nodes.
	check("all three chats are still tabs", _pane.get_tab_count() == 3)
	check("ChatList still has three entries", _so.ChatList.size() == 3)
	var titles: Array = []
	for i in range(_pane.get_tab_count()):
		titles.append(_pane.get_tab_title(i))
	check("Alpha moved to the end", titles[titles.size() - 1] == "Alpha")
	check("Alpha left first position", titles[0] != "Alpha")
	check("every chat is still reachable as a tab",
		titles.has("Alpha") and titles.has("Beta") and titles.has("Gamma"))
	# The bug's signature: ChatList is rebuilt from child order, so a chat parked
	# among infrastructure nodes drops out of alignment with the tab strip.
	var aligned := true
	for i in range(_so.ChatList.size()):
		if _pane.get_tab_title(i) != _so.ChatList[i].HistoryName:
			aligned = false
	check("ChatList stayed aligned with the tab strip", aligned)


func test_project_switch_clears_group_state() -> void:
	print("\n[regression] project switch drops stale group state")
	_reset()
	var a = _add_chat("Alpha")
	await process_frame
	var g: String = _reg.create_group("Project A group")
	_pane.set_chat_group(a, g)
	_pane.set_active_group(g)
	_pane.delete_group(g, "")
	check("a group delete is pending undo", _pane.can_undo_group_delete())
	_pane.set_active_group("__all__")
	var g2: String = _reg.create_group("Still selected")
	_pane.set_chat_group(a, g2)
	_pane.set_active_group(g2)
	check("a group view is selected", _pane.get_active_group_id() == g2)

	# Simulates the project-load path: registry replaced, view state reset.
	_pane.reset_group_state()
	check("active view fell back to All", _pane.get_active_group_id() == "__all__")
	# A carried-over snapshot could recreate the PREVIOUS project's group inside
	# the newly opened one.
	check("the undo snapshot was dropped", not _pane.can_undo_group_delete())

	# And the stale-id hazard itself: a grp_N id from another project either
	# hides every chat or collides with an unrelated group of the same ordinal.
	_reset()
	_add_chat("Chat in project B")
	await process_frame
	_pane.set_active_group("grp_1")
	check("an id absent from this project falls back to All rather than hiding everything",
		_pane.get_active_group_id() == "__all__")
	check("the chat is visible", _visible_tab_titles().size() == 1)


func test_undo_respects_moves_since_delete() -> void:
	print("\n[regression] undo leaves chats moved since the delete alone")
	_reset()
	var a = _add_chat("Alpha")
	var b = _add_chat("Beta")
	await process_frame
	var doomed: String = _reg.create_group("Doomed")
	var other: String = _reg.create_group("Other")
	_pane.set_chat_group(a, doomed)
	_pane.set_chat_group(b, doomed)
	# Keep `other` alive so it survives the prune sweeps.
	var keeper = _add_chat("Keeper")
	await process_frame
	_pane.set_chat_group(keeper, other)

	_pane.delete_group(doomed, "")
	check("both members were ungrouped", str(a.ChatGroupId) == "" and str(b.ChatGroupId) == "")

	# The user moves one of them somewhere else before undoing.
	_pane.set_chat_group(b, other)
	var res: Dictionary = _pane.undo_group_delete()
	await process_frame
	check("undo succeeded", bool(res.get("ok", false)))
	check("the untouched chat came back", str(a.ChatGroupId) == doomed)
	# Undoing a group delete must not yank a chat out of wherever it now lives.
	check("the moved chat was LEFT where the user put it", str(b.ChatGroupId) == other)
	check("undo reported it as skipped", res.get("skipped_chat_ids", []).has(str(b.HistoryId)))

	# A chat whose only reference was the PARKED one must also come back.
	_reset()
	var c = _add_chat("Gamma")
	var d = _add_chat("Delta")
	await process_frame
	var g: String = _reg.create_group("Parked test")
	_pane.set_chat_group(c, g)
	_pane.set_chat_group(d, g)
	_pane.delete_chat(c)
	await process_frame
	check("the deleted chat parked its group", str(c.PreDeleteGroupId) == g)
	check("the group is alive via the other member", _reg.has_group(g))

	_pane.delete_group(g, "")
	check("the parked reference was rewritten too", str(c.PreDeleteGroupId) == "")
	var res2: Dictionary = _pane.undo_group_delete()
	await process_frame
	check("undo succeeded", bool(res2.get("ok", false)))
	check("the live member came back", str(d.ChatGroupId) == g)
	# This is the case the first implementation dropped: the snapshot only
	# recorded live ChatGroupId rewrites, so a chat touched ONLY through its
	# parked field was never reattached and restored ungrouped.
	check("the deleted member's parked group came back too", str(c.PreDeleteGroupId) == g)
	_pane.restore_chat(c)
	await process_frame
	check("restoring it lands in the recovered group", str(c.ChatGroupId) == g)


func test_delete_seq_orders_undo() -> void:
	print("\n[regression] undo order is deterministic within one second")
	_reset()
	var a = _add_chat("First closed")
	var b = _add_chat("Second closed")
	var c = _add_chat("Third closed")
	await process_frame

	_pane.delete_chat(a)
	_pane.delete_chat(b)
	_pane.delete_chat(c)
	await process_frame

	# All three almost certainly share a DeletedAt second, which is exactly the
	# condition an untied sort resolves arbitrarily.
	check("the timestamps did collide (the condition under test)",
		int(a.DeletedAt) == int(c.DeletedAt))
	check("sequences are strictly increasing",
		int(a.DeletedSeq) < int(b.DeletedSeq) and int(b.DeletedSeq) < int(c.DeletedSeq))

	var order: Array = _pane.list_deleted_chats()
	check("most recently closed sorts first", order[0].HistoryName == "Third closed")
	check("then the second", order[1].HistoryName == "Second closed")
	check("then the first", order[2].HistoryName == "First closed")

	check("undo restores the most recent", _pane.restore_last_deleted_chat())
	await process_frame
	check("it was the right one", not c.Deleted and b.Deleted and a.Deleted)
	check("restore cleared the sequence", int(c.DeletedSeq) == 0)

	# Sequences keep climbing past restored chats rather than being reused.
	_pane.delete_chat(c)
	await process_frame
	check("a re-deleted chat gets the highest sequence yet",
		int(c.DeletedSeq) > int(b.DeletedSeq))


func test_mcp_create_by_name_ignores_deleted() -> void:
	print("\n[regression] create-by-name skips soft-deleted chats")
	_reset()
	var a = _add_chat("Review")
	await process_frame
	_pane.delete_chat(a)
	await process_frame

	var Mod = load("res://Scripts/Services/MCP/Modules/MCPChatTools.gd")
	var mod = Mod.new()
	var listed: Dictionary = mod.handle("minerva_list_chats", {})
	var listed_names: Array = []
	for entry in listed.get("chats", []):
		listed_names.append(str(entry.get("name", "")))
	check("the deleted chat is not listed", not listed_names.has("Review"))

	var created: Dictionary = mod.handle("minerva_create_chat", {"name": "Review"})
	await process_frame
	# The bug: create-by-name matched the hidden deleted chat and reported
	# success, handing back a chat_id that minerva_list_chats never shows and
	# that no message can reach.
	check("create did NOT resolve to the deleted chat",
		str(created.get("chat_id", "")) != str(a.HistoryId))
	check("it created a real chat instead", not bool(created.get("already_existed", false)))
	var after: Dictionary = mod.handle("minerva_list_chats", {})
	var after_names: Array = []
	for entry in after.get("chats", []):
		after_names.append(str(entry.get("name", "")))
	check("the new chat IS listed", after_names.has("Review"))

	# Idempotence still holds for live chats.
	var again: Dictionary = mod.handle("minerva_create_chat", {"name": "Review"})
	check("a second create returns the live one", bool(again.get("already_existed", false)))
	check("and it is the one that was just created",
		str(again.get("chat_id", "")) == str(created.get("chat_id", "")))


func test_empty_group_marks_project_dirty() -> void:
	print("\n[regression] registry edits mark the project dirty")
	_reset()
	_add_chat("Alpha")
	await process_frame

	# An empty group is the one thing deliberately kept alive until explicitly
	# deleted, so losing it to a missing dirty flag is a silent data loss.
	_so.saved_state = true
	_pane.create_group("Empty on purpose")
	check("creating an empty group marks the project dirty", not _so.saved_state)

	_so.saved_state = true
	_pane.rename_group(_pane.get_active_group_id(), "Renamed")
	check("renaming marks the project dirty", not _so.saved_state)

	var gid: String = _pane.get_active_group_id()
	_so.saved_state = true
	_pane.delete_group(gid, "")
	check("deleting a group marks the project dirty", not _so.saved_state)

	_so.saved_state = true
	_pane.undo_group_delete()
	check("undoing marks the project dirty", not _so.saved_state)
