extends SceneTree
## Chat tab groups — registry, 3-axis filter matrix, and delete-as-state.
## DCR 01a017494904.
##
## Run: godot --headless --path src --script test/test_chat_groups.gd
##
## Deliberately hermetic: it exercises ChatGroupRegistry (a RefCounted with no
## engine coupling) and the STATIC ChatGroupRegistry.should_show(), which is
## where all three filter axes are combined. Booting ChatPane would drag in the
## SingletonObject autoload, the provider stack and a live TabContainer without
## testing anything should_show() does not already decide.

const Registry := preload("res://Scripts/Models/ChatGroupRegistry.gd")

var _pass := 0
var _fail := 0


func check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _init() -> void:
	print("=== Chat tab groups (DCR 01a017494904) ===\n")

	test_registry_create_and_rename()
	test_registry_name_dedupe()
	test_registry_prune_empty()
	test_registry_roundtrip()
	test_registry_deserialize_tolerates_junk()
	test_filter_matrix()
	test_filter_empty_group()
	test_filter_dangling_group_id()
	test_delete_restore_semantics()

	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ── Registry ──────────────────────────────────────────────────────────

func test_registry_create_and_rename() -> void:
	print("\n[registry] create / rename / lookup")
	var r = Registry.new()
	var a: String = r.create_group("Market research")
	var b: String = r.create_group("Q3 planning")

	check("create returns distinct ids", a != b and not a.is_empty())
	check("ids are not view sentinels", not Registry.is_view_sentinel(a))
	check("name lookup works", r.get_name(a) == "Market research")
	check("has_group true for real id", r.has_group(b))
	check("has_group false for unknown id", not r.has_group("grp_nope"))
	check("find_by_name is case-insensitive", r.find_by_name("q3 PLANNING") == b)

	# A rename is ONE write here — the whole point of storing an id on the chat
	# rather than a name. Nothing about the chats changes.
	check("rename succeeds", r.rename_group(a, "Competitive research"))
	check("renamed name reads back", r.get_name(a) == "Competitive research")
	check("id survived the rename", r.has_group(a))
	check("rename of unknown id fails", not r.rename_group("grp_nope", "x"))
	check("rename to blank is refused", not r.rename_group(a, "   "))
	check("blank rename left the name alone", r.get_name(a) == "Competitive research")

	check("colors differ between groups", r.color_for(a) != r.color_for(b))
	check("unknown id gets the neutral color", r.color_for("grp_nope") == Registry.NEUTRAL_COLOR)


func test_registry_name_dedupe() -> void:
	print("\n[registry] name dedupe")
	var r = Registry.new()
	var a: String = r.create_group()
	var b: String = r.create_group()
	var c: String = r.create_group()
	check("first default name", r.get_name(a) == "Untitled group")
	check("second dedupes to ' 2'", r.get_name(b) == "Untitled group 2")
	check("third dedupes to ' 3'", r.get_name(c) == "Untitled group 3")

	# Renaming a group to the name it already has must not append a suffix.
	check("self-rename is a no-op", r.rename_group(b, "Untitled group 2"))
	check("self-rename kept the name", r.get_name(b) == "Untitled group 2")


func test_registry_prune_empty() -> void:
	print("\n[registry] implicit destruction")
	var r = Registry.new()
	var a: String = r.create_group("Keep")
	var b: String = r.create_group("Drop")

	# A brand-new group has never held a chat, so it is NOT prunable yet.
	# Without this, "create a group, then drag chats into it" is impossible: the
	# next prune sweep deletes the group before the first chat arrives.
	check("new groups start unpopulated", not r.is_populated(a))
	check("prune leaves never-populated groups alone", r.prune_empty([]).is_empty())
	check("both groups survived", r.has_group(a) and r.has_group(b))

	r.mark_populated(a)
	r.mark_populated(b)
	check("mark_populated arms the group", r.is_populated(a))
	check("mark_populated on an unknown id fails", not r.mark_populated("grp_nope"))
	check("mark_populated is idempotent", r.mark_populated(a) and r.is_populated(a))

	var removed: Array = r.prune_empty([a])
	check("prune removed the unreferenced group", removed.has(b))
	check("prune kept the referenced group", r.has_group(a))
	check("pruned group is gone", not r.has_group(b))
	check("prune of an already-clean registry removes nothing", r.prune_empty([a]).is_empty())

	# A populated group whose last chat leaves disappears; that is the lifecycle.
	check("prune with no live ids drops the populated group", r.prune_empty([]).size() == 1)
	check("registry is now empty", r.size() == 0)


func test_registry_roundtrip() -> void:
	print("\n[registry] serialize / deserialize round-trip")
	var r = Registry.new()
	var a: String = r.create_group("Market research")
	var b: String = r.create_group("Smart remote v2")
	var color_a: Color = r.color_for(a)

	r.mark_populated(a)
	var blob: Dictionary = r.serialize()
	var r2 = Registry.new()
	r2.deserialize(blob)

	check("group count survives", r2.size() == 2)
	check("id survives", r2.has_group(a) and r2.has_group(b))
	check("name survives", r2.get_name(b) == "Smart remote v2")
	check("color survives", r2.color_for(a) == color_a)
	# The populated flag must survive, or reloading a project makes every group
	# look brand-new and none of them ever prune again.
	check("populated flag survives", r2.is_populated(a) == r.is_populated(a))

	# Minting must not collide with restored ids after a reload.
	var c: String = r2.create_group("New after load")
	check("new id after load is unique", c != a and c != b)


func test_registry_deserialize_tolerates_junk() -> void:
	print("\n[registry] deserialize is defensive")
	var r = Registry.new()
	r.create_group("will be replaced")

	r.deserialize(null)
	check("null blob clears rather than crashes", r.size() == 0)

	r.deserialize({"version": 1, "next_ordinal": 4.0, "groups": [
		{"id": "grp_1", "name": "Good"},
		"not a dictionary",
		{"id": "", "name": "No id"},
		{"id": "grp_1", "name": "Duplicate id"},
		{"id": Registry.VIEW_ALL, "name": "Sentinel id"},
		{"id": "grp_2", "name": "   "},
	]})
	check("valid entry loaded", r.get_name("grp_1") == "Good")
	# Projects saved before the flag existed could not have empty groups, so a
	# missing flag must read as populated — otherwise old groups never prune.
	check("legacy entry defaults to populated", r.is_populated("grp_1"))
	check("non-dictionary entry skipped", r.size() == 2)
	check("blank id skipped", not r.has_group(""))
	check("duplicate id skipped", r.get_name("grp_1") == "Good")
	check("view sentinel rejected as an id", not r.has_group(Registry.VIEW_ALL))
	check("blank name falls back to the default", r.get_name("grp_2") == Registry.DEFAULT_GROUP_NAME)
	# JSON gives every number back as a float; the ordinal must survive as an int.
	check("float ordinal did not break id minting", r.create_group("x").begins_with("grp_"))


# ── The 3-axis filter ─────────────────────────────────────────────────

func test_filter_matrix() -> void:
	print("\n[filter] group x archived x deleted matrix")
	var G := "grp_1"
	var OTHER := "grp_2"

	# The row that catches a two-pass implementation: a chat in a DIFFERENT
	# group, archived, with Show Archived ON, while a specific group is
	# selected. Filtering on archived alone would show it; filtering on group
	# alone would show it if the passes ran in the wrong order. It must hide.
	check("archived + shown + wrong group => hidden",
		not Registry.should_show(G, OTHER, true, false, true))
	check("archived + shown + right group => visible",
		Registry.should_show(G, G, true, false, true))
	check("archived + hidden + right group => hidden",
		not Registry.should_show(G, G, true, false, false))

	# Deleted beats everything except the Deleted view itself.
	check("deleted is hidden in All", not Registry.should_show(Registry.VIEW_ALL, G, false, true, true))
	check("deleted is hidden in its own group", not Registry.should_show(G, G, false, true, true))
	check("deleted is hidden in Ungrouped", not Registry.should_show(Registry.VIEW_UNGROUPED, "", false, true, true))
	check("deleted is visible in the Deleted view", Registry.should_show(Registry.VIEW_DELETED, G, false, true, false))
	check("live chat is NOT visible in the Deleted view", not Registry.should_show(Registry.VIEW_DELETED, G, false, false, true))
	# A chat that is both archived and deleted must still be reachable, or it is
	# lost with no way back.
	check("archived AND deleted is still reachable in Deleted",
		Registry.should_show(Registry.VIEW_DELETED, G, true, true, false))

	# All / Ungrouped views.
	check("All shows a grouped live chat", Registry.should_show(Registry.VIEW_ALL, G, false, false, false))
	check("All shows an ungrouped live chat", Registry.should_show(Registry.VIEW_ALL, "", false, false, false))
	check("All hides an archived chat by default", not Registry.should_show(Registry.VIEW_ALL, G, true, false, false))
	check("Ungrouped shows only ungrouped", Registry.should_show(Registry.VIEW_UNGROUPED, "", false, false, false))
	check("Ungrouped hides a grouped chat", not Registry.should_show(Registry.VIEW_UNGROUPED, G, false, false, false))

	# Group view.
	check("group view shows its own", Registry.should_show(G, G, false, false, false))
	check("group view hides another group", not Registry.should_show(G, OTHER, false, false, false))
	check("group view hides ungrouped", not Registry.should_show(G, "", false, false, false))

	# Exhaustive sweep: every combination decides, and the archived axis can
	# only ever REMOVE visibility (never add it) outside the Deleted view.
	var views := [Registry.VIEW_ALL, Registry.VIEW_UNGROUPED, Registry.VIEW_DELETED, G, OTHER]
	var members := ["", G, OTHER]
	var contradictions := 0
	for v in views:
		for m in members:
			for deleted in [false, true]:
				var shown_when_archived_visible: bool = Registry.should_show(v, m, true, deleted, true)
				var shown_when_not_archived: bool = Registry.should_show(v, m, false, deleted, true)
				if shown_when_archived_visible and not shown_when_not_archived:
					contradictions += 1
	check("archiving never makes a chat MORE visible", contradictions == 0)


func test_filter_empty_group() -> void:
	print("\n[filter] empty group hides everything")
	var G := "grp_1"
	var chats := [
		{"g": "grp_2", "a": false, "d": false},
		{"g": "", "a": false, "d": false},
		{"g": "grp_2", "a": true, "d": false},
	]
	var visible := 0
	for c in chats:
		if Registry.should_show(G, str(c["g"]), bool(c["a"]), bool(c["d"]), true):
			visible += 1
	# The old archive-only filter's "switch to first visible tab" loop silently
	# did nothing in exactly this state, leaving stale content under an empty
	# strip. The pane now shows its buffer control instead; this pins the
	# precondition that makes it necessary.
	check("selecting an empty group leaves NO visible tab", visible == 0)


func test_filter_dangling_group_id() -> void:
	print("\n[filter] a chat naming a pruned group")
	var r = Registry.new()
	var a: String = r.create_group("Gone")
	r.mark_populated(a)
	r.prune_empty([])
	# ChatPane._effective_group_id resolves an unknown id to "" — this pins the
	# registry half of that contract. A dangling id must never leave a chat
	# unreachable in every view.
	check("pruned id is unknown to the registry", not r.has_group(a))
	check("resolved as ungrouped, it shows in All",
		Registry.should_show(Registry.VIEW_ALL, "", false, false, false))
	check("resolved as ungrouped, it shows in Ungrouped",
		Registry.should_show(Registry.VIEW_UNGROUPED, "", false, false, false))
	check("unresolved, it would be stranded",
		not Registry.should_show(Registry.VIEW_UNGROUPED, a, false, false, false))


# ── Delete-as-state ───────────────────────────────────────────────────

## Minimal stand-in for the four ServiceHistory fields the delete/restore
## transition touches. Booting a real ServiceHistory would pull in the provider
## stack and the SingletonObject autoload for four plain properties.
class FakeChat:
	var ChatGroupId: String = ""
	var PreDeleteGroupId: String = ""
	var Deleted: bool = false
	var DeletedAt: int = 0


## Mirror of ChatPane.delete_chat's state transition.
func _delete(chat: FakeChat, now: int) -> void:
	chat.PreDeleteGroupId = chat.ChatGroupId
	chat.ChatGroupId = ""
	chat.DeletedAt = now
	chat.Deleted = true


## Mirror of ChatPane.restore_chat's state transition.
func _restore(chat: FakeChat, registry) -> void:
	var target := chat.PreDeleteGroupId
	if not target.is_empty() and not registry.has_group(target):
		target = ""
	chat.Deleted = false
	chat.DeletedAt = 0
	chat.ChatGroupId = target
	chat.PreDeleteGroupId = ""


func test_delete_restore_semantics() -> void:
	print("\n[delete-as-state] round trip")
	var r = Registry.new()
	var g: String = r.create_group("Market research")
	r.mark_populated(g)

	var chat := FakeChat.new()
	chat.ChatGroupId = g

	_delete(chat, 1000)
	check("delete sets the Deleted flag", chat.Deleted)
	check("delete stamps a timestamp", chat.DeletedAt == 1000)
	check("delete parks the group", chat.PreDeleteGroupId == g)
	# Critical: a deleted chat must NOT keep its group alive, or an emptied group
	# lingers in the dock with a count of zero.
	check("delete clears the live membership", chat.ChatGroupId == "")
	check("the group is now prunable", r.prune_empty([]).has(g))

	# Restoring into a group that has since been pruned falls back to Ungrouped
	# rather than leaving a dangling id.
	_restore(chat, r)
	check("restore clears the Deleted flag", not chat.Deleted)
	check("restore clears the timestamp", chat.DeletedAt == 0)
	check("restore into a pruned group lands Ungrouped", chat.ChatGroupId == "")
	check("restore clears the parked group", chat.PreDeleteGroupId == "")

	# And when the group still exists, restore returns the chat to it.
	var r2 = Registry.new()
	var g2: String = r2.create_group("Still here")
	r2.mark_populated(g2)
	var chat2 := FakeChat.new()
	chat2.ChatGroupId = g2
	_delete(chat2, 2000)
	check("group survives while another chat holds it", r2.prune_empty([g2]).is_empty())
	_restore(chat2, r2)
	check("restore returns the chat to its group", chat2.ChatGroupId == g2)

	# Undo ordering: most-recently-deleted first.
	var order := [FakeChat.new(), FakeChat.new(), FakeChat.new()]
	order[0].DeletedAt = 100
	order[1].DeletedAt = 300
	order[2].DeletedAt = 200
	order.sort_custom(func(a, b): return int(a.DeletedAt) > int(b.DeletedAt))
	check("most recently deleted sorts first", order[0].DeletedAt == 300)
	check("oldest sorts last", order[2].DeletedAt == 100)
