//! Chat passthrough: a Minerva chat whose provider is a watched terminal.
//! generate services one chat turn (resolve the terminal, pick the write mode,
//! run the relay turn, map the outcome to answer/question/error/pending);
//! resume continues a turn that outlived one call. Question-card state lives
//! here; operation tokens and parked turns live in passthrough_ops.

use super::*;

// ---------------------------------------------------------------------------
// Chat-passthrough generate hook (B7, DCR 019eb7f329 #483)
// ---------------------------------------------------------------------------

/// Plugin-side budget for one passthrough call when the host names none
/// (wait_budget_ms): 10s under the registered timeout_sec=600, so the host
/// receives a structured reply instead of a bare call_tool transport timeout.
/// It also caps what a host may ask for.
const PASSTHROUGH_TIMEOUT_MS: u64 = 590_000;

/// The envelope the HOST writes in front of every minerva_terminal_notify
/// line. Shared by convention with MCPTerminalTools.NOTIFY_ENVELOPE_PREFIX
/// (src/Scripts/Services/MCP/Modules/MCPTerminalTools.gd): the same string in
/// both places, and only the host ever writes it.
///
/// A notification is never an answer to a question card. Everything else a
/// passthrough chat sends while a card is pending IS that card's answer — it
/// bypasses the hold and is typed into the card — so an envelope arriving then
/// would be entered into the chooser as a custom answer nobody asked for. A
/// line with this prefix is therefore always a FRESH prompt: held until the
/// card clears, with the card left filed for the answer still to come.
pub(crate) const NOTIFY_ENVELOPE_PREFIX: &str = "[MINERVA NOTIFY from ";
/// How recent a human keystroke in the target holds a notification's write.
/// Shared by convention with MCPTerminalTools.NOTIFY_HUMAN_TYPING_MS.
pub(crate) const NOTIFY_HUMAN_GUARD_MS: u64 = 5000;

/// Per-chat passthrough state. SEAM GAP (filed): the host's PluginProvider
/// sends only {chat_id, text} to the generate tool — no entry/terminal
/// identity — so the plugin must resolve the terminal itself:
///   1. explicit terminal_id arg (tests / future host versions),
///   2. the remembered chat_id → terminal binding,
///   3. the single active watch session (unambiguous),
///   else a kind:"error" asking for terminal_id.
/// `pending_question` tracks terminals whose last passthrough turn ended in a
/// question — the next single-character text is a dialog keystroke, not a
/// message.
#[derive(Default)]
struct PassthroughState {
    bindings: std::collections::HashMap<String, String>, // chat_id → terminal_id
    pending_question: std::collections::HashSet<String>, // terminal_ids
    // Terminals whose pending question is an AskUserQuestion CHOOSER (vs a
    // permission dialog). A chooser is driven by ↑/↓ + Enter — a digit TYPES a
    // custom answer, it does not select (Claude Code v2.1.181) — so a selection
    // is delivered as ChooserNav (arrow keystrokes, then Enter) and a custom
    // answer as Submit, never as a single raw keystroke.
    pending_is_chooser: std::collections::HashSet<String>, // terminal_ids
    // Option numbers OFFERED on a pending chooser (real answers only; the meta
    // affordances are dropped). The card sends a plain number; the send path maps
    // a number that's in this set to a navigation sequence (Down×(K-1)+Enter) and
    // treats anything else as a typed custom answer — control bytes are generated
    // here and written straight to the PTY, never round-tripped through a chat
    // message (which hangs the turn).
    pending_chooser_options: std::collections::HashMap<String, Vec<u32>>, // terminal_id → numbers
    // The "Type something…" option's number on a pending chooser, if present. It
    // opens a free-text editor rather than being a direct answer, so a click on
    // it does NOT navigate — it prompts the user to type a custom answer (which
    // then goes through the free-text path), avoiding the sub-prompt that hangs.
    pending_type_option: std::collections::HashMap<String, u32>, // terminal_id → option number
    // The question region the pending card was built from. A pending question is
    // only answerable while THAT card is still the screen: the human can answer
    // the card in the terminal directly, and the agent then runs on and may draw
    // a different modal. Comparing this text with the region on screen at the
    // next turn separates the live card (its answer bypasses the hold) from a
    // superseded one (stale: drop the pending state and send as a fresh prompt).
    pending_question_region: std::collections::HashMap<String, String>, // terminal_id → region
    // Last-known watch profile per terminal. The idle reap (watch_timeout_ms,
    // 10 min) tears down an UNARMED watch — and a passthrough chat sits unarmed
    // between turns, so an idle chat loses its watch. We cache the profile while
    // the watch is live so auto-revive restores the SAME calibration (codex /
    // opencode differ from the "claude" default).
    profiles: std::collections::HashMap<String, String>, // terminal_id → profile_id
}

static PASSTHROUGH: Mutex<Option<PassthroughState>> = Mutex::new(None);

/// Whether a question card is filed for `terminal_id` (its next text answers it).
pub(crate) fn question_pending(terminal_id: &str) -> bool {
    with_passthrough(|s| s.pending_question.contains(terminal_id))
}

fn with_passthrough<R>(f: impl FnOnce(&mut PassthroughState) -> R) -> R {
    let mut guard = PASSTHROUGH.lock().unwrap();
    f(guard.get_or_insert_with(PassthroughState::default))
}

/// A chat that has resolved to this terminal owns its watch for this plugin
/// process. Minerva currently has no plugin callback when a history is deleted;
/// terminal close, explicit watch_stop, and plugin restart remain the cleanup
/// boundaries. Watches never selected by a chat still use the idle reap.
pub(crate) fn passthrough_terminal_is_bound(terminal_id: &str) -> bool {
    with_passthrough(|s| s.bindings.values().any(|bound| bound == terminal_id))
}

pub(crate) fn clear_passthrough_terminal_bindings(terminal_id: &str) {
    with_passthrough(|s| s.bindings.retain(|_, bound| bound != terminal_id));
}

pub(crate) fn register_passthrough_operation(params: &Value) -> bool {
    let args = params.get("arguments").unwrap_or(params);
    let Some(token) = args.get("operation_token").and_then(|v| v.as_str()).filter(|v| !v.is_empty()) else {
        return true;
    };
    let terminal = args.get("terminal_id")
        .and_then(|v| v.as_str())
        .filter(|v| !v.is_empty())
        .or_else(|| args.get("entry_id").and_then(|v| v.as_str())
            .and_then(|v| v.strip_prefix("terminal-")))
        .unwrap_or("");
    !terminal.is_empty() && passthrough_ops::register(token, terminal)
}

pub(crate) fn passthrough_resume_requested(params: &Value) -> bool {
    let args = params.get("arguments").unwrap_or(params);
    args.get("resume").and_then(Value::as_bool).unwrap_or(false)
}

pub(crate) fn latch_passthrough_interrupt(params: &Value, id: Value, router: &Arc<Router>) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let token = args.get("operation_token").and_then(|v| v.as_str()).unwrap_or("");
    let (accepted, parked) = passthrough_ops::latch_interrupt(token);
    if let Some(pending) = parked {
        interrupt_and_park(token, pending, router);
    }
    ok_response(id, tool_ok(json!({"ok": true, "accepted": accepted})))
}

/// Park a turn that outlived its call; if an interrupt is latched for it that
/// no wait has written yet, write it first.
fn park_turn(token: &str, pending: passthrough_ops::PendingTurn, router: &Arc<Router>) {
    if let Some(unwritten) = passthrough_ops::park(token, pending) {
        interrupt_and_park(token, unwritten, router);
    }
}

fn interrupt_and_park(token: &str, mut pending: passthrough_ops::PendingTurn, router: &Arc<Router>) {
    if !pending.turn.watch_changed() {
        pending.turn.interrupt(router);
    }
    passthrough_ops::park_interrupted(token, pending);
}

/// Drop every trace of a pending question for a terminal: the next text sent
/// there is a fresh prompt, gated like any other.
/// Retire the pending card ONLY while the region still filed is `expected` —
/// the one this caller validated, or None when it had nothing pending.
///
/// Read and clear happen under ONE lock. Two acquisitions would leave a window
/// in which another handler's turn files a NEWER card between them, and this
/// caller would then wipe a filing the chat user is already looking at.
/// Returns true when the card was retired.
fn clear_pending_question_if(terminal_id: &str, expected: Option<&str>) -> bool {
    with_passthrough(|s| {
        if s.pending_question_region.get(terminal_id).map(String::as_str) != expected {
            return false;
        }
        drop_pending(s, terminal_id);
        true
    })
}

/// The field-by-field retire, for callers that already hold the lock.
fn drop_pending(s: &mut PassthroughState, terminal_id: &str) {
    s.pending_question.remove(terminal_id);
    s.pending_is_chooser.remove(terminal_id);
    s.pending_chooser_options.remove(terminal_id);
    s.pending_type_option.remove(terminal_id);
    s.pending_question_region.remove(terminal_id);
}

/// Resolve which terminal a passthrough chat turn targets. See
/// PassthroughState for the resolution ladder and the seam-gap rationale.
pub(crate) fn resolve_passthrough_terminal(
    chat_id: &str,
    explicit: Option<&str>,
) -> Result<String, String> {
    if let Some(tid) = explicit {
        if !chat_id.is_empty() {
            with_passthrough(|s| {
                s.bindings.insert(chat_id.to_string(), tid.to_string())
            });
        }
        return Ok(tid.to_string());
    }

    if !chat_id.is_empty() {
        if let Some(tid) = with_passthrough(|s| s.bindings.get(chat_id).cloned()) {
            return Ok(tid);
        }
    }

    let sessions = watcher::session_specs();
    match sessions.len() {
        1 => {
            let tid = sessions[0].terminal_id.clone();
            if !chat_id.is_empty() {
                with_passthrough(|s| {
                    s.bindings.insert(chat_id.to_string(), tid.clone())
                });
            }
            Ok(tid)
        }
        0 => Err(
            "no watch session is active; call minerva_agent_relay_watch_start \
             on the terminal first (the chat-provider entry follows the watch \
             lifecycle)".to_string(),
        ),
        n => Err(format!(
            "{n} terminals are watched and the host did not identify the \
             provider entry for this chat; pass terminal_id explicitly"
        )),
    }
}

/// If `text` is a single keystroke for a pending dialog, return the byte(s)
/// to write raw. "\n" normalises to "\r" (the PTY Enter key); any other
/// single character (letter/number hints, "\r", ESC) passes through as-is.
fn normalize_keystroke(text: &str) -> Option<String> {
    match text {
        "\r" | "\n" => Some("\r".to_string()),
        _ if text.chars().count() == 1 => Some(text.to_string()),
        _ => None,
    }
}

/// Re-establish a watch that the idle reap (or a non-resumed restart) tore
/// down under a live passthrough chat. Refuses only when the terminal itself
/// is gone — a reaped watch leaves the PTY alive (Minerva background session),
/// but a CLOSED terminal makes host.terminal.read error, and reviving a watch
/// on a dead terminal would just spin to a TerminalClosed detection. Restores
/// the cached profile so the agent's calibration survives the revive.
fn revive_passthrough_watch(terminal_id: &str, router: &Arc<Router>) -> Result<(), String> {
    // Liveness probe: only the terminal-gone case should surface an error.
    if let Err(e) = router.call_capability(
        "host.terminal.read", json!({ "terminal_id": terminal_id }),
    ) {
        return Err(format!(
            "terminal {terminal_id} is no longer available ({e}); its agent's \
             terminal was closed — start a new passthrough chat"
        ));
    }
    let profile = with_passthrough(|s| s.profiles.get(terminal_id).cloned())
        .unwrap_or_else(|| "claude".to_string());
    watcher::watch_start(
        terminal_id.to_string(),
        Some(profile.clone()),
        watcher::NotifyMode::Armed,
        router.clone(),
    )
    .map_err(|e| format!("failed to revive watch for terminal {terminal_id}: {e}"))?;
    log::info!("passthrough: auto-revived reaped watch for {terminal_id} (profile {profile})");
    Ok(())
}

/// B7: passthrough_generate — services ONE chat turn for a terminal-backed
/// chat-provider entry. The relay_ask core does the work (send + arm → block
/// until turn end → read); this handler only resolves the terminal, picks the
/// write mode (message submit vs raw dialog keystroke), and maps the outcome
/// to the seam result shape:
///   {kind:"answer", text} | {kind:"question", text, options} | {kind:"error", text}.
/// Errors are IN-BAND (kind:"error", normal tool content) so the host's
/// PluginProvider can render them uniformly. distill is OFF: passthrough is
/// verbatim (no LLM in the transport path — DCR #479 constraint).
/// Locate the chooser's currently-highlighted option number from the `❯` cursor
/// line on the screen (the only option row prefixed with the selection glyph).
/// Returns None when no cursor+number line is visible.
fn chooser_cursor_option(screen: &str) -> Option<u32> {
    let re = regex::Regex::new(r"^\s*[❯›>]\s*(\d+)[.)]").ok()?;
    for line in screen.lines() {
        if let Some(c) = re.captures(line) {
            if let Some(n) = c.get(1).and_then(|m| m.as_str().parse::<u32>().ok()) {
                return Some(n);
            }
        }
    }
    None
}

/// Build the arrow-key run to move the chooser cursor from its CURRENT option
/// (read live from the screen) to the target option K. Using the live cursor —
/// rather than assuming the top — is robust to scrolling, cancel/retry, and any
/// prior navigation. Empty string when already on the target (Enter alone
/// selects). Falls back to assuming the top option if the cursor isn't readable.
fn chooser_nav_keys(terminal_id: &str, target: u32, router: &Arc<Router>) -> String {
    let screen = router
        .call_capability("host.terminal.read", json!({ "terminal_id": terminal_id }))
        .ok()
        .and_then(|r| r.get("content").and_then(|v| v.as_str()).map(String::from))
        .unwrap_or_default();
    let current = chooser_cursor_option(&screen).unwrap_or(1);
    if target >= current {
        "\u{1b}[B".repeat((target - current) as usize) // Down
    } else {
        "\u{1b}[A".repeat((current - target) as usize) // Up
    }
}

pub(crate) fn handle_passthrough_generate(params: &Value, id: Value, router: &Arc<Router>) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let chat_id = args.get("chat_id").and_then(|v| v.as_str()).unwrap_or("");
    let text = args.get("text").and_then(|v| v.as_str()).unwrap_or("");
    // The host's PluginProvider sends entry_id ("terminal-<tid>") with every
    // generate — the authoritative answer to WHICH watched terminal this chat
    // targets. An explicit terminal_id arg still wins (direct/test use).
    let entry_tid = args.get("entry_id")
        .and_then(|v| v.as_str())
        .and_then(|e| e.strip_prefix("terminal-"))
        .filter(|s| !s.is_empty());
    let explicit_tid = args.get("terminal_id")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .or(entry_tid);
    let operation_token = args.get("operation_token")
        .and_then(|v| v.as_str())
        .filter(|v| !v.is_empty());
    let operation = passthrough_ops::OperationGuard::new(operation_token);
    // One deadline covers the gate's wait for the terminal AND the turn: the
    // host's call times out on their sum, not on each.
    let started = Instant::now();
    let deadline = started + Duration::from_millis(passthrough_budget_ms(args));

    if text.is_empty() {
        return ok_response(id, tool_ok(json!({
            "kind": "error",
            "text": "text is required",
        })));
    }

    let terminal_id = match resolve_passthrough_terminal(chat_id, explicit_tid) {
        Ok(t) => t,
        Err(e) => return ok_response(id, tool_ok(json!({"kind": "error", "text": e}))),
    };
    if operation_token.is_some_and(|token| {
        passthrough_ops::owner(token).as_deref() != Some(terminal_id.as_str())
    }) {
        return ok_response(id, tool_ok(json!({
            "kind": "error",
            "text": "operation token does not belong to this terminal",
        })));
    }

    // A bound chat now owns its watch across idle periods. The watch can still
    // be absent after a relay restart or a bind/cleanup race, while the PTY
    // remains alive, so auto-revive remains the recovery boundary. We only
    // refuse when the terminal itself is gone (genuinely closed).
    match watcher::watch_status(&terminal_id) {
        Some(status) => {
            if let Some(prof) = status.get("profile_id").and_then(|v| v.as_str()) {
                with_passthrough(|s| {
                    s.profiles.insert(terminal_id.clone(), prof.to_string());
                });
            }
        }
        None => {
            if let Err(e) = revive_passthrough_watch(&terminal_id, router) {
                return ok_response(id, tool_ok(json!({"kind": "error", "text": e})));
            }
        }
    }

    // Dialog answer? After a "question" result, a single-keystroke text is
    // written raw with NO Enter — dialog pickers act on the keypress (codex
    // calibration is ambiguous on enter-confirm, so letter/number hints go
    // alone; the Confirm option carries "\r" itself).
    //
    // A pending question only survives while the card that produced it is still
    // the screen. Nothing on the passthrough path sees the human answer that
    // same card in the terminal — the agent then runs on and can draw a NEW
    // modal — so the region on screen is compared with the one the card was
    // built from. A match means this write is the answer that clears the card
    // (bypass the hold); anything else is stale: drop the pending state so the
    // text is sent as a fresh prompt and the gate holds it while a modal owns
    // the keyboard. An unreadable screen also drops the state; the gate then
    // treats the same unreadable terminal as writable, which only a dead
    // terminal produces.
    // A notification answers nothing: it never takes the card's bypass, and it
    // leaves the pending state alone (NOTIFY_ENVELOPE_PREFIX).
    let is_notify = text.starts_with(NOTIFY_ENVELOPE_PREFIX);
    let mut pending_question =
        !is_notify && with_passthrough(|s| s.pending_question.contains(&terminal_id));
    let mut filed_region: Option<String> = None;
    if pending_question {
        let filed = with_passthrough(|s| {
            s.pending_question_region.get(&terminal_id).cloned()
        });
        let live = live_question_region(&terminal_id, router).map(|r| region_identity(&r));
        if live.is_none() || live != filed {
            // Retire only the card read above: a concurrent handler may have
            // filed a newer one during the screen read, and that one stays.
            clear_pending_question_if(&terminal_id, filed.as_deref());
            pending_question = false;
        } else {
            filed_region = filed;
        }
    }
    let pending_chooser =
        with_passthrough(|s| s.pending_is_chooser.contains(&terminal_id));

    // "Type something…" click: this option opens a free-text editor — navigating
    // to it would block the turn waiting on input the card can't supply. So don't
    // touch the terminal: keep the chooser pending and return a prompt telling the
    // user to type their custom answer. Their next message is plain text → the
    // free-text path types it into the chooser and submits it (typing creates a
    // custom answer without pre-selecting "Type something"). Returning early
    // leaves the pending state untouched so that next message routes correctly.
    if pending_question && pending_chooser {
        let type_n = with_passthrough(|s| s.pending_type_option.get(&terminal_id).copied());
        if let Some(tn) = type_n {
            if text.trim().parse::<u32>().ok() == Some(tn) {
                return ok_response(id, tool_ok(json!({
                    "kind": "question",
                    "text": "Type your custom answer in the message box below and send it.",
                    "options": [],
                })));
            }
        }
    }

    // Chooser select: the card sends the option NUMBER as a plain chat message.
    // Translate it to arrow-key navigation HERE — moving from the live cursor
    // position to option K, delivered one keypress at a time (ChooserNav mode) —
    // so raw ESC bytes are generated in the plugin and written straight to the
    // PTY, never round-tripped through a chat message (control bytes in a chat
    // message hang the turn). Only a number that was actually OFFERED maps to
    // navigation; anything else (words, or a number that wasn't an option) is a
    // typed custom answer via the free-text path.
    let chooser_nav: Option<String> = if pending_question && pending_chooser {
        let offered = with_passthrough(|s| {
            s.pending_chooser_options
                .get(&terminal_id)
                .cloned()
                .unwrap_or_default()
        });
        text.trim()
            .parse::<u32>()
            .ok()
            .filter(|k| *k >= 1 && offered.contains(k))
            .map(|k| chooser_nav_keys(&terminal_id, k, router))
    } else {
        None
    };

    // Only a permission-dialog answer is a single raw keystroke (no Enter).
    let keystroke = if pending_question && !pending_chooser {
        normalize_keystroke(text)
    } else {
        None
    };
    // Precedence: chooser navigation (Submit adds Enter) → permission keystroke
    // (raw, no Enter) → Submit (a normal message OR a chooser custom answer, both
    // body + Enter).
    let (send_text, mode): (&str, SendMode) = if let Some(ref nav) = chooser_nav {
        (nav.as_str(), SendMode::ChooserNav)
    } else if let Some(ref k) = keystroke {
        (k.as_str(), SendMode::RawKeystroke)
    } else {
        (text, SendMode::Submit)
    };

    // Anything sent while a question is pending ANSWERS the modal on screen —
    // a chooser's custom free text as much as a permission keystroke or a
    // chooser arrow. The hold guards a FRESH prompt from landing on a screen
    // that owns the keyboard; here the screen is waiting on exactly this write,
    // so holding for it would burn the whole passthrough budget and error.
    let hold = match (pending_question, filed_region.clone()) {
        (true, Some(region)) => GateHold::Bypass(region),
        _ => GateHold::Wait,
    };

    let mut outcome = passthrough_ask(
        &terminal_id, send_text, mode, hold, deadline, operation_token, router,
    );
    // The card was cleared by someone else while this answer queued for the
    // slot, so nothing was written: the text is a fresh prompt now, sent as a
    // plain submit that the gate holds like any other.
    //
    // WHAT IS FILED IS NOT NECESSARILY THIS CALLER'S CARD. The usual reason a
    // bypass goes stale is that the first answer's turn already filed a NEW
    // question card for this terminal. That filing is live — the chat user is
    // looking at it — and dropping it would make their answer to it arrive
    // with no pending state, so it would be sent as a fresh prompt and held by
    // the very card it answers for the whole budget. So the pending state is
    // dropped only when what is filed is still the region THIS caller
    // validated, i.e. nobody has re-filed since.
    if matches!(outcome, Err(ref e) if e.message == STALE_BYPASS) {
        clear_pending_question_if(&terminal_id, filed_region.as_deref());
        // The bypass also goes stale when the WATCH went away under the answer
        // (watch_stop, the idle reap): the card could no longer be confirmed,
        // so nothing was written. The re-send is a fresh prompt and needs the
        // watch back before it goes out — without one the gate has nothing to
        // classify screens with, and the prompt would be written unheld onto
        // the modal that replaced the card, which is the write this refusal
        // just prevented.
        if watcher::watch_status(&terminal_id).is_none() {
            if let Err(e) = revive_passthrough_watch(&terminal_id, router) {
                return ok_response(id, tool_ok(json!({"kind": "error", "text": e})));
            }
        }
        outcome = passthrough_ask(
            &terminal_id, text, SendMode::Submit, GateHold::Wait, deadline, operation_token, router,
        );
    }

    let finished = match outcome {
        Ok(AskProgress::WatchLost(turn)) => {
            turn.hand_over();
            return ok_response(id, tool_ok(watch_lost_result(&terminal_id)));
        }
        Ok(AskProgress::Running(turn)) => {
            // The turn outlived this call. With a token the host can resume
            // it: park the turn, slot and all, and say so. A host that sent no
            // token cannot, so the turn is handed over as it always was.
            let Some(token) = operation_token else {
                turn.hand_over();
                return ok_response(id, tool_ok(json!({
                    "kind": "error",
                    "text": format!(
                        "terminal {terminal_id} did not finish its turn within {}s; \
                         the arm remains set — collect the late reply via \
                         minerva_agent_relay_read_turn",
                        started.elapsed().as_secs()
                    ),
                })));
            };
            let pending = passthrough_ops::PendingTurn::new(turn, chat_id, filed_region, started);
            operation.keep();
            park_turn(token, pending, router);
            return ok_response(id, tool_ok(pending_result(token, started)));
        }
        Ok(AskProgress::Finished(v)) => Ok(v),
        Err(e) => Err(e),
    };
    ok_response(id, tool_ok(passthrough_result(&terminal_id, finished, filed_region.as_deref(), router)))
}

/// The host's per-call budget (wait_budget_ms), capped at PASSTHROUGH_TIMEOUT_MS.
fn passthrough_budget_ms(args: &Value) -> u64 {
    args.get("wait_budget_ms")
        .and_then(Value::as_u64)
        .unwrap_or(PASSTHROUGH_TIMEOUT_MS)
        .clamp(100, PASSTHROUGH_TIMEOUT_MS)
}

/// Send one passthrough write and wait on its turn until `deadline`.
fn passthrough_ask(
    terminal_id: &str,
    text: &str,
    mode: SendMode,
    hold: GateHold,
    deadline: Instant,
    operation_token: Option<&str>,
    router: &Arc<Router>,
) -> Result<AskProgress, SendError> {
    let gate_budget = deadline.saturating_duration_since(Instant::now()).as_millis() as u64;
    let turn = start_turn(terminal_id, text, mode, hold, gate_budget, router)?;
    // distill OFF — passthrough is verbatim; redact stays on: secrets never
    // enter chat history.
    continue_turn(turn, deadline, true, false, true, None, operation_token, router)
}

/// {kind:"pending"}: the turn is still running and parked under `token`.
fn pending_result(token: &str, started: Instant) -> Value {
    json!({
        "kind": "pending",
        "operation_token": token,
        "elapsed_ms": started.elapsed().as_millis() as u64,
    })
}

/// passthrough_resume: wait again on a turn a generate call parked. Nothing is
/// written — the prompt went out once, in generate. The turn is taken out of
/// the store for the wait, so a second resume for the same token finds
/// nothing; it is parked again only if it is still running at this call's
/// deadline.
pub(crate) fn handle_passthrough_resume(params: &Value, id: Value, router: &Arc<Router>) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);
    let chat_id = args.get("chat_id").and_then(|v| v.as_str()).unwrap_or("");
    let token = args.get("operation_token").and_then(|v| v.as_str()).unwrap_or("");
    let deadline = Instant::now() + Duration::from_millis(passthrough_budget_ms(args));
    // A turn borrowed to have its Stop written comes back within one host
    // write; wait for it rather than calling it gone. Still borrowed at this
    // call's deadline, it is still running: pending, for the next resume.
    let pending = loop {
        match passthrough_ops::take(token, chat_id) {
            passthrough_ops::Take::Turn(p) => break p,
            passthrough_ops::Take::Busy(started) => {
                if Instant::now() >= deadline {
                    return ok_response(id, tool_ok(pending_result(token, started)));
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            passthrough_ops::Take::Gone => return ok_response(id, tool_ok(json!({
                "kind": "error",
                "text": "this chat has no running terminal turn to resume: it finished, was \
                         cancelled, or waited too long for its resume. Any reply it produced \
                         is still in the terminal.",
            }))),
        }
    };
    let terminal_id = pending.turn.terminal_id().to_string();
    let passthrough_ops::PendingTurn { turn, filed_region, started, .. } = pending;
    let finished = match continue_turn(turn, deadline, true, false, true, None, Some(token), router) {
        Ok(AskProgress::WatchLost(turn)) => {
            passthrough_ops::finish(token);
            turn.hand_over();
            return ok_response(id, tool_ok(watch_lost_result(&terminal_id)));
        }
        Ok(AskProgress::Running(turn)) => {
            park_turn(token, passthrough_ops::PendingTurn::new(turn, chat_id, filed_region, started),
                      router);
            return ok_response(id, tool_ok(pending_result(token, started)));
        }
        Ok(AskProgress::Finished(v)) => Ok(v),
        Err(e) => Err(e),
    };
    passthrough_ops::finish(token);
    ok_response(id, tool_ok(passthrough_result(&terminal_id, finished, filed_region.as_deref(), router)))
}

/// The watch that would count this turn's end is gone or replaced, so its end
/// can no longer be told apart from the next turn's: the turn is let go.
fn watch_lost_result(terminal_id: &str) -> Value {
    json!({
        "kind": "error",
        "text": format!("the watch on terminal {terminal_id} was stopped or restarted while \
                         this turn ran, so its reply cannot be collected here; it is in the terminal"),
    })
}

/// Map a passthrough turn's outcome to the seam's reply — answer, question or
/// error — and file or retire the terminal's pending question card to match.
fn passthrough_result(
    terminal_id: &str,
    outcome: Result<Value, SendError>,
    filed_region: Option<&str>,
    router: &Arc<Router>,
) -> Value {
    let result = match outcome {
        // The chat path reports the failure the same way the send tools do:
        // held and its outcome ride along, so the host classifies a hold by
        // its keys rather than by the prose it happens to carry.
        Err(e) => {
            let payload = send_error_payload(&e);
            let mut err = json!({"kind": "error", "text": e.message});
            for key in ["held", "hold_reason", "outcome"] {
                if let Some(v) = payload.get(key) {
                    err[key] = v.clone();
                }
            }
            err
        }
        Ok(v) => {
            let cause = v.get("cause").and_then(|c| c.as_str()).unwrap_or("");
            if cause == "input_requested" {
                build_question_result(terminal_id, router)
            } else if cause == "turn_completed" {
                let mut answer = v.get("answer").and_then(|a| a.as_str()).unwrap_or("").to_string();
                if v.get("interrupted").and_then(|x| x.as_bool()).unwrap_or(false) {
                    if !answer.is_empty() {
                        answer.push_str("\n\n");
                    }
                    answer.push_str("[Interrupted]");
                } else if v.get("interrupt_failed").and_then(|x| x.as_bool()).unwrap_or(false) {
                    if !answer.is_empty() {
                        answer.push_str("\n\n");
                    }
                    answer.push_str("[Interrupt request failed]");
                }
                json!({
                    "kind": "answer",
                    "text": answer,
                    "answer_source": v.get("answer_source").cloned()
                        .unwrap_or(json!(answer_backfill::SOURCE_SCREEN)),
                })
            } else {
                json!({
                    "kind": "error",
                    "text": format!(
                        "terminal {terminal_id} turn ended abnormally \
                         (cause={cause}); the terminal session may be gone"
                    ),
                })
            }
        }
    };

    if result.get("kind").and_then(|k| k.as_str()) == Some("question") {
        // The card's own region text identifies the screen this question came
        // from; the next turn compares it with the screen then. pending_is_chooser
        // and the option maps are set by build_question_result (chooser vs
        // permission); leave them as that call decided.
        let region = region_identity(result.get("text").and_then(|t| t.as_str()).unwrap_or(""));
        with_passthrough(|s| {
            s.pending_question.insert(terminal_id.to_string());
            s.pending_question_region.insert(terminal_id.to_string(), region);
        });
    } else {
        // Only the card this caller saw when it started is its to retire. A
        // concurrent caller's turn may have filed a newer card meanwhile; that
        // filing belongs to the answer still to come, so it stays.
        clear_pending_question_if(terminal_id, filed_region);
    }
    result
}

/// The question region a screen draws, and whether it is a CHOOSER.
///
/// Two block shapes need different region anchoring. A permission dialog
/// carries its marker ABOVE its options (anchor top-down via the permission
/// regex). An AskUserQuestion chooser carries its marker — the nav footer —
/// BELOW its options, so the same regex would anchor on the footer and drop
/// every option; extract it header-anchored instead. extract_question_region
/// is chooser-unique ("enter to select"), so the permission path is unchanged.
fn question_region(screen: &str, profile_id: &str) -> (String, bool) {
    let dialog_re = profiles::profile_get(profile_id)
        .and_then(|p| p.detection.permission_dialog_regex)
        .and_then(|pat| regex::Regex::new(&pat).ok());
    match dialog::extract_question_region(screen) {
        Some(region) => (region, true),
        None => (
            dialog::extract_dialog_region(screen, dialog_re.as_ref(), 20),
            false,
        ),
    }
}

/// A dialog region with its volatile marks removed: the highlight caret moves
/// when the human arrows through the same card, so identity keys on the option
/// text alone (leading caret glyphs and indentation dropped on every row).
pub(crate) fn region_identity(region: &str) -> String {
    region
        .lines()
        .map(|l| l.trim_start_matches(|c: char| c.is_whitespace() || matches!(c, '\u{276f}' | '\u{203a}' | '>')))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The profile currently watching a terminal, defaulted like the card builder.
pub(crate) fn watched_profile_id(terminal_id: &str) -> String {
    watcher::watch_status(terminal_id)
        .and_then(|s| s.get("profile_id").and_then(|v| v.as_str()).map(String::from))
        .unwrap_or_else(|| "claude".to_string())
}

/// The question region on the terminal's CURRENT screen, or None when the
/// screen cannot be read.
pub(crate) fn live_question_region(terminal_id: &str, router: &Arc<Router>) -> Option<String> {
    let screen = router.call_capability("host.terminal.read", json!({
        "terminal_id": terminal_id,
    })).ok()?
        .get("content")
        .and_then(|v| v.as_str())?
        .to_string();
    Some(question_region(&screen, &watched_profile_id(terminal_id)).0)
}

/// Build the {kind:"question"} result for an input_requested turn: read the
/// RAW viewport (the cleaned turn window is for prose answers — the chrome /
/// redaction pipeline must not touch the dialog's option lines before
/// parsing), extract the dialog region with the profile's permission regex,
/// and parse the {label, keystroke} options.
fn build_question_result(terminal_id: &str, router: &Arc<Router>) -> Value {
    let screen = match router.call_capability("host.terminal.read", json!({
        "terminal_id": terminal_id,
    })) {
        Ok(r) => r.get("content").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        Err(e) => {
            return json!({
                "kind": "error",
                "text": format!("input requested but screen read failed: {e}"),
            });
        }
    };

    let profile_id = watched_profile_id(terminal_id);
    let (region, is_chooser) = question_region(&screen, &profile_id);
    let parsed = dialog::parse_options(&profile_id, &region);
    // Keep ALL options on the card. A chooser selects via ↑/↓ + Enter (a digit
    // TYPES a custom answer, it does not select — Claude Code v2.1.181). The card
    // keeps the plain option NUMBER as its keystroke; the digit→navigation
    // translation happens in the SEND path, so raw ESC bytes never round-trip
    // through a chat message (that hangs the turn). The "Type something…" option
    // is surfaced too but is NOT navigable (selecting it opens a text editor that
    // blocks the turn) — its number is remembered separately so a click on it
    // prompts the user to type a custom answer (free-text path). Every other
    // option, including "Chat about this", is a normal navigable selection.
    let mut chooser_numbers: Vec<u32> = Vec::new();
    let mut type_option: Option<u32> = None;
    if is_chooser {
        for o in &parsed {
            if let Ok(n) = o.keystroke.parse::<u32>() {
                if dialog::is_type_option(&o.label) {
                    type_option = Some(n);
                } else {
                    chooser_numbers.push(n);
                }
            }
        }
    }
    // Record the shape for the NEXT turn's send routing: a navigable number → nav
    // (ChooserNav: one write per arrow keystroke, then Enter); the type-option
    // number → a "type your answer" prompt (no terminal action); typed text →
    // a custom answer.
    with_passthrough(|s| {
        if is_chooser {
            s.pending_is_chooser.insert(terminal_id.to_string());
            s.pending_chooser_options
                .insert(terminal_id.to_string(), chooser_numbers.clone());
            match type_option {
                Some(n) => {
                    s.pending_type_option.insert(terminal_id.to_string(), n);
                }
                None => {
                    s.pending_type_option.remove(terminal_id);
                }
            }
        } else {
            s.pending_is_chooser.remove(terminal_id);
            s.pending_chooser_options.remove(terminal_id);
            s.pending_type_option.remove(terminal_id);
        }
    });
    let options: Vec<Value> = parsed.iter().map(|o| o.to_json()).collect();

    json!({"kind": "question", "text": region, "options": options})
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A pending card is retired only by the caller whose card it still is.
    /// The read and the clear happen under ONE lock, so a card filed by another
    /// handler between them cannot be wiped — the chat user is already looking
    /// at that newer card, and wiping it would make their answer arrive with no
    /// pending state and be held by the very card it answers.
    #[test]
    fn a_pending_card_is_retired_only_by_the_caller_whose_card_it_is() {
        let terminal = "main-tests-compare-and-clear";
        with_passthrough(|s| {
            s.pending_question.insert(terminal.to_string());
            s.pending_question_region
                .insert(terminal.to_string(), "card one".to_string());
        });

        assert!(
            !clear_pending_question_if(terminal, Some("card zero")),
            "a caller whose card has been replaced must not retire the new one"
        );
        assert!(
            with_passthrough(|s| s.pending_question.contains(terminal)),
            "the newer filing stays answerable"
        );

        assert!(
            !clear_pending_question_if(terminal, None),
            "a caller that had nothing pending must not retire someone's card"
        );

        assert!(
            clear_pending_question_if(terminal, Some("card one")),
            "the caller whose card is still filed retires it"
        );
        assert!(
            with_passthrough(|s| !s.pending_question.contains(terminal)
                && !s.pending_question_region.contains_key(terminal)),
            "and every trace of it is gone"
        );
    }

    #[test]
    fn passthrough_operation_tokens_have_one_owner_and_stale_interrupts_are_noops() {
        let token = "main-tests-operation-owner";
        let first = json!({"arguments": {
            "entry_id": "terminal-owner-a", "operation_token": token,
        }});
        let duplicate = json!({"arguments": {
            "entry_id": "terminal-owner-b", "operation_token": token,
        }});
        assert!(register_passthrough_operation(&first));
        assert!(!register_passthrough_operation(&duplicate));
        assert_eq!(passthrough_ops::owner(token), Some("owner-a".to_string()));

        assert!(passthrough_ops::latch_interrupt(token).0, "the first Stop is accepted");
        assert!(!passthrough_ops::latch_interrupt(token).0, "a repeated Stop is not");

        drop(passthrough_ops::OperationGuard::new(Some(token)));
        assert!(passthrough_ops::owner(token).is_none() && !passthrough_ops::interrupt_latched(token));
        assert!(!passthrough_ops::latch_interrupt(token).0, "a stale token is a no-op");
    }
}
