extends RefCounted
## The class of a notification and the mechanism that carries it to a
## harness. Every ledger record and notify receipt carries `class`,
## `mechanism` and `delivered_at` from here.
##
## Class:
##   routine — a pointer ("come look"); DocketWakeups coalesces these.
##   urgent  — stop or scope steering (DocketWakeups' control:* changes, or
##             minerva_terminal_notify with urgent=true). Never coalesced.
##
## Mechanism, and when the harness gets the line (`delivered_at`):
##   chat_queue         — a passthrough chat is bound to the terminal: the line
##                        waits in that chat's outgoing queue and runs after
##                        the chat's current turn (turn_end). An urgent line is
##                        placed ahead of the routine notifications queued
##                        behind the last message a person queued there.
##   relay_when_idle    — no chat: Minerva holds the line while the harness
##                        shows a running turn (hold_reason busy_turn) and the
##                        relay types it once none shows (turn_end).
##   native_queue       — no chat, a turn showed, and the harness's own input
##                        queue was measured on this platform
##                        (NATIVE_QUEUE_MEASURED). Planned for urgent lines
##                        only; a host caller that does not hold for busy
##                        turns lands here too. The relay types it while the
##                        turn runs and the harness queues it (harness_queue).
##                        Minerva's held routine lines are still held, so they
##                        reach the harness after it. The harness decides when
##                        it runs: codex labels its queue "submitted after
##                        next tool call"; in the measured turns (no tool
##                        calls) both ran it right after the turn.
##   relay_into_turn    — no chat, a turn showed, and the harness's own queue
##                        was NOT measured on this platform, yet the line was
##                        typed (a host caller that does not hold for busy
##                        turns): what the harness does with it is unknown.
##   relay_unclassified — no chat and no harness identified in front (this
##                        platform cannot read the foreground process and no
##                        watch names a profile): no running turn can be seen,
##                        so the relay types it as its own screen gate allows
##                        (unknown).
## Minerva never interrupts a running turn (it sends no Esc or Ctrl+C).

const ROUTINE := "routine"
const URGENT := "urgent"

const CHAT_QUEUE := "chat_queue"
const RELAY_WHEN_IDLE := "relay_when_idle"
const NATIVE_QUEUE := "native_queue"
const RELAY_UNCLASSIFIED := "relay_unclassified"
const RELAY_INTO_TURN := "relay_into_turn"

const AT_TURN_END := "turn_end"
const IN_HARNESS_QUEUE := "harness_queue"
const AT_UNKNOWN := "unknown"

## Harness -> platforms where writing while a turn runs was measured to land
## in the harness's own queue, in order, with nothing lost. Source: the
## agent-relay corpus tests/fixtures/hold_submit/queue/{claude,codex}_queue
## (Claude Code 2.1.278, codex-cli 0.155.1, Linux PTY). A platform is added
## here only with a measurement of its own.
const NATIVE_QUEUE_MEASURED := {
	"claude": ["linux"],
	"codex": ["linux"],
}

## What each harness draws while it holds a queued message, from the same
## corpus (screens/03_queued.txt): Claude Code replaces its composer with this
## placeholder; codex lists each queued message on a row starting with "↳".
const CLAUDE_QUEUED_PLACEHOLDER := "Press up to edit queued messages"
const CODEX_QUEUED_ROW_PREFIX := "↳"

## How much of the envelope is matched on screen: its start fits one row.
const NEEDLE_CHARS := 40


## "linux", "mac", "windows", or the lower-cased OS name elsewhere.
static func platform() -> String:
	match OS.get_name():
		"Linux": return "linux"
		"macOS": return "mac"
		"Windows": return "windows"
	return OS.get_name().to_lower()


static func class_of(urgent: bool) -> String:
	return URGENT if urgent else ROUTINE


static func native_queue_measured(harness: String, on_platform: String) -> bool:
	return on_platform in Array(NATIVE_QUEUE_MEASURED.get(harness, []))


## The mechanism a line of `klass` for `harness` would use here, before any
## screen is read. `has_chat`: a passthrough chat is bound to the terminal.
static func planned(klass: String, harness: String, has_chat: bool, on_platform: String = "") -> String:
	if has_chat:
		return CHAT_QUEUE
	if harness.is_empty():
		return RELAY_UNCLASSIFIED
	var where: String = on_platform if not on_platform.is_empty() else platform()
	if klass == URGENT and native_queue_measured(harness, where):
		return NATIVE_QUEUE
	return RELAY_WHEN_IDLE


static func delivered_at(mechanism: String) -> String:
	match mechanism:
		CHAT_QUEUE, RELAY_WHEN_IDLE: return AT_TURN_END
		NATIVE_QUEUE: return IN_HARNESS_QUEUE
	return AT_UNKNOWN


## Both classes for one terminal, as minerva_terminal_list reports them.
static func plan_for_terminal(harness: String, has_chat: bool) -> Dictionary:
	var routine: String = planned(ROUTINE, harness, has_chat)
	var urgent: String = planned(URGENT, harness, has_chat)
	return {
		"platform": platform(),
		"routine": {"mechanism": routine, "delivered_at": delivered_at(routine)},
		"urgent": {"mechanism": urgent, "delivered_at": delivered_at(urgent)},
	}


## Whether the screen read after a write made while a turn ran shows the
## harness holding `envelope` in its own queue: the harness's queued marker is
## on `after`, and more rows carry the envelope's start than on `before`.
## Claude Code's queued echo is drawn like a sent one, so its placeholder
## decides; codex's queued row is its own shape, so that row must carry it.
static func harness_queued(harness: String, envelope: String, before: String, after: String) -> bool:
	var needle: String = _collapse(envelope).left(NEEDLE_CHARS)
	if needle.is_empty():
		return false
	match harness:
		"claude":
			return after.contains(CLAUDE_QUEUED_PLACEHOLDER) \
				and _rows_with(after, needle) > _rows_with(before, needle)
		"codex":
			for row: String in after.split("\n"):
				var text: String = row.strip_edges()
				if text.begins_with(CODEX_QUEUED_ROW_PREFIX) and _collapse(text).contains(needle):
					return true
	return false


## One line for a view: "urgent · native_queue (harness_queue)".
static func describe(record: Dictionary) -> String:
	var mechanism: String = str(record.get("mechanism", ""))
	var klass: String = str(record.get("class", ROUTINE))
	if mechanism.is_empty():
		return "%s · mechanism not chosen yet" % klass
	return "%s · %s (%s)" % [klass, mechanism, str(record.get("delivered_at", delivered_at(mechanism)))]


static func _rows_with(screen: String, needle: String) -> int:
	var count: int = 0
	for row: String in screen.split("\n"):
		if _collapse(row).contains(needle):
			count += 1
	return count


static func _collapse(text: String) -> String:
	var out: String = ""
	var space: bool = false
	for ch in text:
		if ch == " " or ch == "\t" or ch == " ":
			space = not out.is_empty()
			continue
		if space:
			out += " "
			space = false
		out += ch
	return out
