// send_gate_integration.rs — the send gate driven end to end against the real
// plugin binary and a scripted fake host (tests/common).
//
// The screens are the byte-true captures in tests/fixtures/hold_submit/, and
// each assertion checks the behaviour that corpus's README states the harness
// has: a write must not land on a screen that owns the keyboard, two relay
// prompts on one terminal must not overlap, and the one measured stuck-submit
// shape is worth exactly one extra Enter.

mod common;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use common::{quiet, settled, FakeHost};

// ── Screens ─────────────────────────────────────────────────────────────────

const HOLD_CLAUDE_PERMISSION: &str =
    include_str!("fixtures/hold_submit/hold/claude_permission_dialog/screen.txt");
const HOLD_CLAUDE_CHOOSER: &str =
    include_str!("fixtures/hold_submit/hold/claude_question_chooser/screen.txt");
const HOLD_CLAUDE_TRUST: &str =
    include_str!("fixtures/hold_submit/hold/claude_trust_folder/screen.txt");
const HOLD_CLAUDE_MODEL: &str =
    include_str!("fixtures/hold_submit/hold/claude_model_menu/screen.txt");
const HOLD_CODEX_TRUST: &str =
    include_str!("fixtures/hold_submit/hold/codex_trust_directory/screen.txt");
const HOLD_CODEX_UPDATE: &str =
    include_str!("fixtures/hold_submit/hold/codex_update_available_menu/screen.txt");
const HOLD_CODEX_MODEL: &str =
    include_str!("fixtures/hold_submit/hold/codex_model_menu/screen.txt");

const CLAUDE_IDLE: &str = include_str!("fixtures/real/claude_idle_prompt.txt");
const CODEX_IDLE: &str = include_str!("fixtures/real/codex_idle_prompt.txt");

const CLAUDE_SUBMIT_OK: &str =
    include_str!("fixtures/hold_submit/submit/claude_typed_submit_ok/screen.txt");
const CODEX_SUBMIT_OK: &str =
    include_str!("fixtures/hold_submit/submit/codex_typed_submit_ok/screen.txt");
const CODEX_STUCK: &str =
    include_str!("fixtures/hold_submit/submit/codex_chunk_stuck_in_composer/screen.txt");
const CODEX_AFTER_EXTRA_ENTER: &str =
    include_str!("fixtures/hold_submit/submit/codex_chunk_after_extra_enter/screen.txt");

/// Block until the gate reports exactly one caller queued behind the owner —
/// the queued caller's thread has to reach the gate first, so this polls rather
/// than sampling once.
fn wait_for_one_waiter(host: &mut FakeHost, terminal: &str) {
    let mut status = Value::Null;
    for _ in 0..80 {
        status = host.tool(
            "minerva_agent_relay_watch_status",
            json!({"terminal_id": terminal}),
        );
        if status["status"]["send_waiters"] == json!(1) {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    panic!("no caller queued for the slot: {status}");
}

/// The two messages the submit corpus was driven with — the fixtures echo
/// exactly these, so the confirmation has something to recognise.
const PING: &str = "Reply with exactly the word PING and nothing else.";
const PONG: &str = "Reply with exactly the word PONG and nothing else.";

// ── 1. Every hold screen holds the write until it clears ───────────────────

/// Drive one hold fixture: a send is issued while the screen owns the
/// keyboard, and the screen only clears once the test says so.
///
/// Oracle: meta.json `must_hold: true` for all seven — an Enter on any of them
/// answers a modal (on the codex update offer it starts a global npm install).
/// Before the gate existed the write went out on the first read.
fn hold_case(name: &str, profile: &str, hold_screen: &str, idle_screen: &str) {
    let mut host = FakeHost::start();
    let cleared = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&cleared);
    let hold = hold_screen.to_string();
    let idle = idle_screen.to_string();
    host.screen = Box::new(move |_| {
        if flag.load(Ordering::SeqCst) {
            (idle.clone(), 120)
        } else {
            (hold.clone(), 120)
        }
    });
    host.wait = Box::new(|_| quiet());

    let terminal = format!("t-hold-{name}");
    host.watch_start(&terminal, profile);

    let send = host.call_tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "ping"}),
    );

    // Let the gate re-read the held screen several times.
    host.pump_while(&[send], |v| v.reads < 3);
    assert!(
        host.view().writes.is_empty(),
        "{name}: the gate wrote into a held screen: {:?}",
        host.view().writes
    );

    // watch_status names the hold while it is holding.
    let status = host.tool(
        "minerva_agent_relay_watch_status",
        json!({"terminal_id": terminal}),
    );
    let reason = status["status"]["hold_reason"].as_str().unwrap_or("");
    assert!(
        !reason.is_empty(),
        "{name}: watch_status must name the hold reason, got {status}"
    );

    cleared.store(true, Ordering::SeqCst);
    let reply = host.await_reply(send);
    let payload = common::unwrap_tool(&reply);
    assert_eq!(payload["ok"], true, "{name}: send failed: {payload}");
    assert_eq!(
        host.view().writes,
        vec!["ping".to_string(), "\r".to_string()],
        "{name}: the message must land exactly once, after the screen cleared"
    );
}

#[test]
fn a_write_is_held_on_every_hold_screen_and_lands_after_it_clears() {
    let cases: &[(&str, &str, &str, &str)] = &[
        ("claude-permission", "claude", HOLD_CLAUDE_PERMISSION, CLAUDE_IDLE),
        ("claude-chooser", "claude", HOLD_CLAUDE_CHOOSER, CLAUDE_IDLE),
        ("claude-trust", "claude", HOLD_CLAUDE_TRUST, CLAUDE_IDLE),
        ("claude-model", "claude", HOLD_CLAUDE_MODEL, CLAUDE_IDLE),
        ("codex-trust", "codex", HOLD_CODEX_TRUST, CODEX_IDLE),
        ("codex-update", "codex", HOLD_CODEX_UPDATE, CODEX_IDLE),
        ("codex-model", "codex", HOLD_CODEX_MODEL, CODEX_IDLE),
    ];
    for (name, profile, hold, idle) in cases {
        hold_case(name, profile, hold, idle);
    }
}

// ── 2. Two prompts on one terminal do not overlap ──────────────────────────

/// Oracle: the relay's per-turn bookkeeping. The second prompt must be written
/// only after the first turn has ended AND been read, so that the first turn's
/// pre-write screen anchor and submit timestamp describe one prompt and one
/// answer — which is what the session-log backfill matches on. Each generate
/// must come back with the answer to its OWN prompt.
///
/// The test establishes which prompt is first: two tool calls put on the wire
/// back to back run on their own plugin threads and reach the gate in whatever
/// order the scheduler picks — the relay keeps no queue of its own, so wire
/// order is not an ordering promise it can keep. So prompt one is written, and
/// only then is prompt two issued; what is under test is that prompt two waits
/// for the whole of turn one.
#[test]
fn two_generates_on_one_terminal_serialise_and_keep_their_own_turns() {
    let mut host = FakeHost::start();
    let terminal = "t-serialise";

    // Row count grows with each turn so the turn windows differ.
    host.screen = Box::new(|v| (CLAUDE_IDLE.to_string(), 100 + v.writes.len() as u64));

    // The turn window: whichever prompt is outstanding when it is read.
    host.turn = Box::new(|v| {
        if v.writes.len() >= 4 {
            "\u{276f} prompt two\n\u{25cf} answer two for the second prompt\n".to_string()
        } else {
            "\u{276f} prompt one\n\u{25cf} answer one for the first prompt\n".to_string()
        }
    });

    // Every settle sample that ENDS a turn records how many writes had gone
    // out at that moment — the evidence that prompt two came later.
    // Turn one ends only once the test releases it, so the queued second
    // generate is observable while turn one is still running.
    let writes_at_turn_end: Arc<Mutex<Vec<usize>>> = Arc::new(Mutex::new(Vec::new()));
    let marks = Arc::clone(&writes_at_turn_end);
    let release_first = Arc::new(AtomicBool::new(false));
    let released = Arc::clone(&release_first);
    host.wait = Box::new(move |v| {
        // 2 writes = prompt one submitted; 4 = prompt two submitted.
        match v.writes.len() {
            2 if released.load(Ordering::SeqCst) => {
                marks.lock().unwrap().push(2);
                settled(
                    "\u{276f} prompt one\n\u{25cf} answer one for the first prompt\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                    130,
                )
            }
            n if n >= 4 => {
                marks.lock().unwrap().push(n);
                settled(
                    "\u{276f} prompt two\n\u{25cf} answer two for the second prompt\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                    160,
                )
            }
            _ => quiet(),
        }
    });

    host.watch_start(terminal, "claude");

    let first = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-one", "terminal_id": terminal, "text": "prompt one"}),
    );
    // Prompt one holds the slot from here on: its body and Enter are out and
    // its turn cannot end until the test releases it.
    host.pump_while(&[first], |v| v.writes.len() < 2);

    let second = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-two", "terminal_id": terminal, "text": "prompt two"}),
    );

    // While prompt one is outstanding, the gate must show one caller queued
    // behind it and nothing else written. The second generate's thread has to
    // get as far as the gate first, so poll rather than sample once.
    let mut status = Value::Null;
    for _ in 0..40 {
        status = host.tool(
            "minerva_agent_relay_watch_status",
            json!({"terminal_id": terminal}),
        );
        if status["status"]["send_waiters"] == json!(1) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    assert_eq!(
        status["status"]["send_in_flight"], true,
        "a relay prompt is outstanding: {status}"
    );
    assert_eq!(
        status["status"]["send_waiters"], 1,
        "the second generate is waiting, not writing: {status}"
    );
    assert_eq!(
        host.view().writes.len(),
        2,
        "nothing of prompt two reached the terminal while turn one ran: {:?}",
        host.view().writes
    );

    release_first.store(true, Ordering::SeqCst);
    let first_payload = common::unwrap_tool(&host.await_reply(first));
    let second_payload = common::unwrap_tool(&host.await_reply(second));

    assert_eq!(
        host.view().writes,
        vec![
            "prompt one".to_string(),
            "\r".to_string(),
            "prompt two".to_string(),
            "\r".to_string(),
        ],
        "both prompts written once, in order, with no interleaving"
    );

    let marks = writes_at_turn_end.lock().unwrap().clone();
    assert_eq!(
        marks.first().copied(),
        Some(2),
        "the first turn ended while only prompt one had been written: {marks:?}"
    );

    assert_eq!(first_payload["kind"], "answer", "{first_payload}");
    assert!(
        first_payload["text"].as_str().unwrap_or("").contains("answer one"),
        "first chat got its own answer: {first_payload}"
    );
    assert_eq!(second_payload["kind"], "answer", "{second_payload}");
    assert!(
        second_payload["text"].as_str().unwrap_or("").contains("answer two"),
        "second chat got its own answer: {second_payload}"
    );
}

// ── 3. Submit confirmation, and who earns an extra Enter ───────────────────

/// Oracle: README finding 5 and the submit fixtures. codex leaves a chunked
/// write sitting in its composer; one extra Enter submits it, once. Both
/// *_typed_submit_ok screens show a turn in flight, so neither may earn a
/// keystroke — an extra Enter on a live harness is a blind keypress.
#[test]
fn only_the_stuck_composer_earns_one_extra_enter() {
    // (name, profile, body, screen after the write, screen after recovery,
    //  expected writes, expected extra_enter)
    let idle_for = |profile: &str| match profile {
        "codex" => CODEX_IDLE,
        _ => CLAUDE_IDLE,
    };

    struct Case {
        name: &'static str,
        profile: &'static str,
        body: &'static str,
        after_write: &'static str,
        after_recovery: &'static str,
        expect_writes: usize,
        expect_extra_enter: bool,
    }

    let cases = [
        Case {
            name: "codex-stuck",
            profile: "codex",
            body: PING,
            after_write: CODEX_STUCK,
            after_recovery: CODEX_AFTER_EXTRA_ENTER,
            expect_writes: 3,
            expect_extra_enter: true,
        },
        Case {
            name: "codex-ok",
            profile: "codex",
            body: PONG,
            after_write: CODEX_SUBMIT_OK,
            after_recovery: CODEX_SUBMIT_OK,
            expect_writes: 2,
            expect_extra_enter: false,
        },
        Case {
            name: "claude-ok",
            profile: "claude",
            body: PONG,
            after_write: CLAUDE_SUBMIT_OK,
            after_recovery: CLAUDE_SUBMIT_OK,
            expect_writes: 2,
            expect_extra_enter: false,
        },
    ];

    for case in cases {
        let mut host = FakeHost::start();
        let terminal = format!("t-submit-{}", case.name);
        let idle = idle_for(case.profile).to_string();
        let after_write = case.after_write.to_string();
        let after_recovery = case.after_recovery.to_string();
        host.screen = Box::new(move |v| {
            let screen = match v.writes.len() {
                0..=1 => idle.clone(),
                2 => after_write.clone(),
                _ => after_recovery.clone(),
            };
            (screen, 120)
        });
        host.wait = Box::new(|_| quiet());
        host.watch_start(&terminal, case.profile);

        let payload = host.tool(
            "minerva_agent_relay_send",
            json!({"terminal_id": terminal, "text": case.body}),
        );

        let writes = host.view().writes;
        assert_eq!(
            writes.len(),
            case.expect_writes,
            "{}: wrote {writes:?}",
            case.name
        );
        assert_eq!(writes[0], case.body, "{}: body written first", case.name);
        assert!(
            writes[1..].iter().all(|w| w == "\r"),
            "{}: only Enters follow the body: {writes:?}",
            case.name
        );
        assert_eq!(
            payload["submit"]["extra_enter"],
            case.expect_extra_enter,
            "{}: {payload}",
            case.name
        );
        assert_eq!(
            payload["submit"]["state"], "submitted",
            "{}: the write must end confirmed: {payload}",
            case.name
        );
    }
}

// ── 4. An answer to the card is not held by the card ───────────────────────

/// The prompt whose turn ends on the chooser screen. The fixture echoes it, so
/// the submit confirmation recognises its own write.
const ASK_PROMPT: &str =
    "Use the AskUserQuestion tool to ask me whether I prefer tabs or spaces for indentation.";
/// A free-text answer to that chooser: not one of the offered numbers, so it is
/// typed into the chooser as a custom answer (SendMode::Submit).
const CUSTOM_ANSWER: &str = "Two spaces, always";
const SECOND_ANSWER: &str = "No, four spaces";

/// Oracle: the chooser screen is `must_hold: true` (it is one of the seven),
/// and the hold exists so a FRESH prompt never lands on it. A custom chooser
/// answer is the opposite case — it is what CLEARS that screen — so holding it
/// waits for a screen only this write can change, and the wait ends in the
/// passthrough timeout. The control half is the same text with no question
/// pending: that one must still be held.
#[test]
fn a_custom_chooser_answer_is_written_while_the_same_text_alone_is_held() {
    // ── answering half: drive a real chooser question, then answer it ──
    let mut host = FakeHost::start();
    let terminal = "t-chooser-answer";
    // Idle until the prompt is submitted; the chooser from then on — it stays
    // on screen until the answer lands, exactly as the live harness draws it.
    host.screen = Box::new(|v| {
        if v.writes.len() < 2 {
            (CLAUDE_IDLE.to_string(), 100)
        } else {
            (HOLD_CLAUDE_CHOOSER.to_string(), 130)
        }
    });
    host.wait = Box::new(|v| {
        if v.writes.len() >= 2 {
            settled(HOLD_CLAUDE_CHOOSER, 130)
        } else {
            quiet()
        }
    });
    host.watch_start(terminal, "claude");

    let question = host.tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-q", "terminal_id": terminal, "text": ASK_PROMPT}),
    );
    assert_eq!(
        question["kind"], "question",
        "the turn must end as the question card that makes the answer pending: {question}"
    );
    assert!(
        !question["options"].as_array().map(|o| o.is_empty()).unwrap_or(true),
        "the card must carry the chooser's options: {question}"
    );

    let answer = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-q", "terminal_id": terminal, "text": CUSTOM_ANSWER}),
    );
    // The answer must reach the terminal without the chooser ever clearing.
    host.pump_while(&[answer], |v| v.writes.len() < 4);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
        ],
        "the custom answer must be typed into the chooser that asked for it"
    );
    drop(host);

    // ── control half: the same text with nothing pending is held ──
    let mut host = FakeHost::start();
    let terminal = "t-chooser-fresh";
    let cleared = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&cleared);
    host.screen = Box::new(move |_| {
        if flag.load(Ordering::SeqCst) {
            (CLAUDE_IDLE.to_string(), 120)
        } else {
            (HOLD_CLAUDE_CHOOSER.to_string(), 120)
        }
    });
    host.wait = Box::new(|_| quiet());
    host.watch_start(terminal, "claude");

    let send = host.call_tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": CUSTOM_ANSWER}),
    );
    host.pump_while(&[send], |v| v.reads < 3);
    assert!(
        host.view().writes.is_empty(),
        "a fresh prompt must still be held by the chooser: {:?}",
        host.view().writes
    );

    cleared.store(true, Ordering::SeqCst);
    host.await_reply(send);
    assert_eq!(
        host.view().writes,
        vec![CUSTOM_ANSWER.to_string(), "\r".to_string()],
        "and land once the chooser is gone"
    );
}

// ── 5. A card the human answered in the terminal stops being answerable ────

/// Oracle: the answer-the-card bypass exists for the card that is ON SCREEN.
/// Nothing on the passthrough path sees the human answer that same card in the
/// terminal directly — the agent then runs on and can stop at a DIFFERENT
/// modal. The chooser card is still drawn in chat, so the next message (here
/// the number of an offered option, the shape that reaches the PTY as arrow
/// keys + Enter) would be written onto a permission dialog whose highlighted
/// answer is "Yes". `must_hold: true` for that screen: this message is a fresh
/// prompt now, so it must be held until the dialog clears, and it must land as
/// a plain submit — proof the pending chooser state was dropped, not reused.
#[test]
fn a_card_answered_in_the_terminal_no_longer_bypasses_the_hold() {
    let mut host = FakeHost::start();
    let terminal = "t-stale-card";
    // Screen script: idle until the prompt is submitted; the chooser until the
    // human answers it in the terminal (`answered`); the permission dialog the
    // agent then stops at, until the test clears that too.
    let answered = Arc::new(AtomicBool::new(false));
    let cleared = Arc::new(AtomicBool::new(false));
    let (a, c) = (Arc::clone(&answered), Arc::clone(&cleared));
    host.screen = Box::new(move |v| {
        if v.writes.len() < 2 {
            (CLAUDE_IDLE.to_string(), 100)
        } else if !a.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_CHOOSER.to_string(), 130)
        } else if !c.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_PERMISSION.to_string(), 160)
        } else {
            (CLAUDE_IDLE.to_string(), 180)
        }
    });
    let a = Arc::clone(&answered);
    host.wait = Box::new(move |v| {
        if v.writes.len() < 2 {
            quiet()
        } else if !a.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_CHOOSER, 130)
        } else {
            settled(HOLD_CLAUDE_PERMISSION, 160)
        }
    });
    host.watch_start(terminal, "claude");

    let question = host.tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-stale", "terminal_id": terminal, "text": ASK_PROMPT}),
    );
    assert_eq!(
        question["kind"], "question",
        "the turn must end as the chooser card: {question}"
    );
    let offered: Vec<String> = question["options"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter_map(|o| o["keystroke"].as_str().map(str::to_string))
        .collect();
    let option = offered
        .iter()
        .find(|k| k.parse::<u32>().map(|n| n > 1).unwrap_or(false))
        .cloned()
        .unwrap_or_else(|| panic!("the chooser card must offer a numbered option: {question}"));

    // The human answers that card in the terminal; the agent runs on and stops
    // at a permission dialog. The plugin is told nothing.
    answered.store(true, Ordering::SeqCst);

    let late = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-stale", "terminal_id": terminal, "text": option}),
    );
    // Let the gate re-read the dialog several times.
    let before = host.view().reads;
    host.pump_while(&[late], |v| v.reads < before + 4);
    assert_eq!(
        host.view().writes.len(),
        2,
        "nothing may be written while the permission dialog owns the keyboard: {:?}",
        host.view().writes
    );

    cleared.store(true, Ordering::SeqCst);
    host.pump_while(&[late], |v| v.writes.len() < 4);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            option.clone(),
            "\r".to_string(),
        ],
        "the late message must land as a plain submit once the dialog is gone"
    );
}

// ── 6. A screen the host cannot read is not a writable screen ──────────────

/// Oracle: the hold exists because an Enter on a modal answers it. A screen
/// that cannot be read cannot be classified, so it may be that modal — the
/// only safe reading of "unknown" is "held". The gate must keep trying and
/// end its budget in an error, with nothing written.
#[test]
fn an_unreadable_screen_is_never_treated_as_writable() {
    let mut host = FakeHost::start();
    let terminal = "t-unreadable";
    // A permission dialog is up; the host cannot read the terminal.
    host.screen = Box::new(|_| (HOLD_CLAUDE_PERMISSION.to_string(), 100));
    host.screen_fails = Box::new(|_| true);
    host.wait = Box::new(|_| quiet());
    host.watch_start(terminal, "claude");

    // relay_ask's timeout IS the gate budget: 1 s keeps the test short.
    let ask = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "ping", "timeout_ms": 1000}),
    );
    let reply = host.await_reply(ask);
    let payload = common::unwrap_tool(&reply);

    assert!(
        host.view().writes.is_empty(),
        "nothing may be written to a terminal whose screen cannot be read: {:?}",
        host.view().writes
    );
    let error = payload["error"].as_str().unwrap_or("");
    assert!(
        error.contains("could not be read"),
        "the budget must end in an error naming the unreadable screen: {payload}"
    );
    assert!(
        host.view().reads > 1,
        "the gate must keep re-reading within the budget, not give up on the \
         first failure: {} reads",
        host.view().reads
    );
}

// ── 7. A held prompt must not block the answer that clears the hold ────────

/// Oracle: the screen a fresh prompt is held by is usually a question card,
/// and the answer to that card is the only thing that clears it. Both need the
/// terminal's prompt slot. If the held prompt takes the slot first, the answer
/// queues behind a prompt that cannot move until the answer lands — the card
/// is unanswerable through the relay until the send's budget expires.
#[test]
fn a_held_prompt_does_not_block_the_answer_that_clears_it() {
    let mut host = FakeHost::start();
    let terminal = "t-held-vs-answer";
    let answered = Arc::new(AtomicBool::new(false));
    let a = Arc::clone(&answered);
    // Idle until the first prompt lands; the chooser until it is answered
    // (writes 3 and 4); idle again after.
    host.screen = Box::new(move |v| {
        if v.writes.len() < 2 {
            (CLAUDE_IDLE.to_string(), 100)
        } else if !a.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_CHOOSER.to_string(), 130)
        } else {
            (CLAUDE_IDLE.to_string(), 160)
        }
    });
    let a = Arc::clone(&answered);
    host.wait = Box::new(move |v| {
        if v.writes.len() < 2 {
            quiet()
        } else if !a.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_CHOOSER, 130)
        } else {
            settled(
                "\u{276f} answer\n\u{25cf} done with the question\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                160,
            )
        }
    });
    host.watch_start(terminal, "claude");

    // Drive a real chooser card so an answer is pending.
    let question = host.tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-a", "terminal_id": terminal, "text": ASK_PROMPT}),
    );
    assert_eq!(question["kind"], "question", "{question}");

    // A fresh prompt arrives while the card is up: it must be held.
    let fresh = host.call_tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "fresh prompt"}),
    );
    let before = host.view().reads;
    host.pump_while(&[fresh], |v| v.reads < before + 3);
    assert_eq!(
        host.view().writes.len(),
        2,
        "the fresh prompt must be held by the chooser: {:?}",
        host.view().writes
    );

    // Now the answer to that card. It must be written PROMPTLY — not after the
    // fresh send's 120 s budget.
    let answer = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-a", "terminal_id": terminal, "text": CUSTOM_ANSWER}),
    );
    let before = host.view().reads;
    host.pump_while(&[answer], |v| v.writes.len() < 4 && v.reads < before + 60);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
        ],
        "the answer must reach the card while the fresh prompt waits"
    );

    // The card is answered; the screen clears and the held prompt lands last.
    answered.store(true, Ordering::SeqCst);
    host.await_reply(answer);
    host.await_reply(fresh);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
            "fresh prompt".to_string(),
            "\r".to_string(),
        ],
        "and the held prompt lands after the turn it waited for"
    );
}

// ── 8. Two answers to one card: only the first one is an answer ────────────

/// Oracle: the card's identity is checked when the message arrives, but the
/// write happens later — after the prompt slot is free. Two answers to one
/// card both pass that check; the first clears the card and the agent stops at
/// a DIFFERENT modal. The second must not still believe it is answering the
/// original card: re-checked at the write, it is a fresh prompt, and the
/// permission dialog now on screen (`must_hold: true`) must hold it.
#[test]
fn a_second_answer_to_the_same_card_does_not_write_onto_the_next_modal() {
    let mut host = FakeHost::start();
    let terminal = "t-double-answer";
    let moved_on = Arc::new(AtomicBool::new(false));
    let cleared = Arc::new(AtomicBool::new(false));
    let (m, c) = (Arc::clone(&moved_on), Arc::clone(&cleared));
    host.screen = Box::new(move |v| {
        if v.writes.len() < 2 {
            (CLAUDE_IDLE.to_string(), 100)
        } else if !m.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_CHOOSER.to_string(), 130)
        } else if !c.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_PERMISSION.to_string(), 160)
        } else {
            (CLAUDE_IDLE.to_string(), 190)
        }
    });
    let m = Arc::clone(&moved_on);
    host.wait = Box::new(move |v| {
        if v.writes.len() < 2 {
            quiet()
        } else if !m.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_CHOOSER, 130)
        } else {
            settled(HOLD_CLAUDE_PERMISSION, 160)
        }
    });
    host.watch_start(terminal, "claude");

    let question = host.tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-d", "terminal_id": terminal, "text": ASK_PROMPT}),
    );
    assert_eq!(question["kind"], "question", "{question}");

    // Two answers to that one card, both issued while it is still on screen.
    // WHICH of two calls on the wire reaches the gate first is the scheduler's
    // to decide (see test 2), so the order is ESTABLISHED here rather than
    // assumed: the first answer's write is out — and its turn therefore still
    // holds the slot — before the second answer is issued.
    let first = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-d", "terminal_id": terminal, "text": CUSTOM_ANSWER}),
    );
    host.pump_while(&[first], |v| v.writes.len() < 4);
    let second = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-d2", "terminal_id": terminal, "text": SECOND_ANSWER}),
    );
    // The second answer must be queued for the slot, not writing.
    wait_for_one_waiter(&mut host, terminal);

    // The card is gone — the agent ran on and stopped at a permission dialog.
    moved_on.store(true, Ordering::SeqCst);
    host.await_reply(first);

    let before = host.view().reads;
    host.pump_while(&[second], |v| v.reads < before + 8);
    assert_eq!(
        host.view().writes.len(),
        4,
        "the second answer must not be written onto the permission dialog: {:?}",
        host.view().writes
    );

    cleared.store(true, Ordering::SeqCst);
    host.pump_while(&[second], |v| v.writes.len() < 6);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
            SECOND_ANSWER.to_string(),
            "\r".to_string(),
        ],
        "and lands as a plain submit once the dialog clears"
    );
}

// ── 9. A stale bypass must not wipe the card that replaced it ──────────────

/// Oracle: the usual reason a bypass goes stale is that the FIRST answer's
/// turn already filed a NEW question card — the one the chat user is now
/// looking at. Dropping the pending state on that stale bypass wipes the new
/// filing, so the user's answer to the new card arrives as a fresh prompt and
/// is held by the very card it answers for the whole passthrough budget.
/// After the stale bypass, the new card must still be filed and its answer
/// must still bypass the hold.
#[test]
fn a_stale_bypass_leaves_the_newly_filed_card_answerable() {
    let mut host = FakeHost::start();
    let terminal = "t-stale-refile";
    let moved_on = Arc::new(AtomicBool::new(false));
    let cleared = Arc::new(AtomicBool::new(false));
    let (m, c) = (Arc::clone(&moved_on), Arc::clone(&cleared));
    host.screen = Box::new(move |v| {
        if v.writes.len() < 2 {
            (CLAUDE_IDLE.to_string(), 100)
        } else if !m.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_CHOOSER.to_string(), 130)
        } else if !c.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_PERMISSION.to_string(), 160)
        } else {
            (CLAUDE_IDLE.to_string(), 190)
        }
    });
    let (m, c) = (Arc::clone(&moved_on), Arc::clone(&cleared));
    host.wait = Box::new(move |v| {
        if v.writes.len() < 2 {
            quiet()
        } else if !m.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_CHOOSER, 130)
        } else if !c.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_PERMISSION, 160)
        } else {
            settled(
                "\u{276f} answer\n\u{25cf} done with the question\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                190,
            )
        }
    });
    host.watch_start(terminal, "claude");

    let question = host.tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-r", "terminal_id": terminal, "text": ASK_PROMPT}),
    );
    assert_eq!(question["kind"], "question", "{question}");

    // Two answers to that one card. The order is ESTABLISHED, not assumed: two
    // calls on the wire reach the gate in whatever order the scheduler picks
    // (see test 2), so the first answer's write is out before the second is
    // issued — and the second must have validated the card and QUEUED before
    // the card goes, or its bypass would never be the stale one under test.
    let first = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-r", "terminal_id": terminal, "text": CUSTOM_ANSWER}),
    );
    host.pump_while(&[first], |v| v.writes.len() < 4);
    let second = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-r2", "terminal_id": terminal, "text": SECOND_ANSWER}),
    );
    wait_for_one_waiter(&mut host, terminal);

    // The first answer's turn ends at a NEW card (a permission dialog), which
    // its result files; the second answer's bypass is stale from here on.
    moved_on.store(true, Ordering::SeqCst);
    let first_payload = common::unwrap_tool(&host.await_reply(first));
    assert_eq!(
        first_payload["kind"], "question",
        "the first answer's turn filed a new card: {first_payload}"
    );

    // Give the second answer time to take the slot, find its bypass stale and
    // start over as a held prompt — the point where the new filing was wiped.
    let before = host.view().reads;
    host.pump_while(&[second], |v| v.reads < before + 8);
    assert_eq!(
        host.view().writes.len(),
        4,
        "the stale second answer must be held by the new card, not written: {:?}",
        host.view().writes
    );

    // The chat user answers the NEW card. It is a permission dialog, so the
    // answer is a single raw keystroke — and it must BYPASS the hold, which it
    // can only do while the new card's pending state is still filed.
    let answer_new = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-r", "terminal_id": terminal, "text": "1"}),
    );
    let before = host.view().reads;
    host.pump_while(&[answer_new], |v| v.writes.len() < 5 && v.reads < before + 40);
    assert_eq!(
        host.view().writes.len(),
        5,
        "the answer to the new card must bypass the hold and reach it: {:?}",
        host.view().writes
    );
    assert_eq!(
        host.view().writes[4], "1",
        "and land as the dialog's single keystroke: {:?}",
        host.view().writes
    );

    // Let everything drain: the dialog clears, so the second answer's held
    // re-send finally lands as a plain submit.
    cleared.store(true, Ordering::SeqCst);
    host.await_reply(answer_new);
    host.await_reply(second);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
            "1".to_string(),
            SECOND_ANSWER.to_string(),
            "\r".to_string(),
        ],
        "every write accounted for, in order"
    );
}

// ── 9b. A card answer whose WATCH vanished must not be written ─────────────

/// Oracle: the bypass is the card's IDENTITY check, and a screen's identity
/// does not need a watch — only the hold and the peek classify screens. An
/// answer that validated the card and then queued can reach the front to find
/// both that the watch is gone (watch_stop, the idle reap) and that the
/// terminal has moved on to a different modal. Its keystrokes here are a
/// chooser navigation, and on the permission dialog now drawn they would
/// select whatever is highlighted. Nothing may be written: the answer is
/// refused as stale and starts over as a plain prompt on a revived watch,
/// held by the dialog like any other.
#[test]
fn a_card_answer_whose_watch_vanished_is_not_written_onto_the_next_modal() {
    let mut host = FakeHost::start();
    let terminal = "t-watch-gone-answer";
    let moved_on = Arc::new(AtomicBool::new(false));
    let cleared = Arc::new(AtomicBool::new(false));
    // A's turn is held open by the FAKE HOST, not by timing: while this is set
    // no wait ever settles, so A's turn cannot end however long the test pumps.
    // That is what makes the watch-absence sample below a barrier rather than a
    // race — see the sampling comment.
    let a_turn_open = Arc::new(AtomicBool::new(true));
    let (m, c) = (Arc::clone(&moved_on), Arc::clone(&cleared));
    host.screen = Box::new(move |v| {
        if v.writes.len() < 2 {
            (CLAUDE_IDLE.to_string(), 100)
        } else if !m.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_CHOOSER.to_string(), 130)
        } else if !c.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_PERMISSION.to_string(), 160)
        } else {
            (CLAUDE_IDLE.to_string(), 190)
        }
    });
    let m = Arc::clone(&moved_on);
    let open = Arc::clone(&a_turn_open);
    host.wait = Box::new(move |v| {
        if v.writes.len() < 2 {
            quiet()
        } else if !m.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_CHOOSER, 130)
        } else if open.load(Ordering::SeqCst) {
            quiet()
        } else {
            settled(HOLD_CLAUDE_PERMISSION, 160)
        }
    });
    host.watch_start(terminal, "claude");

    let question = host.tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-w", "terminal_id": terminal, "text": ASK_PROMPT}),
    );
    assert_eq!(question["kind"], "question", "{question}");
    // The number of an offered option: it reaches the PTY as chooser
    // navigation (arrow keys + Enter), the shape that would SELECT on the
    // permission dialog.
    let option = question["options"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter_map(|o| o["keystroke"].as_str())
        .find(|k| k.parse::<u32>().map(|n| n > 1).unwrap_or(false))
        .map(str::to_string)
        .unwrap_or_else(|| panic!("the chooser card must offer a numbered option: {question}"));

    // Answer A (custom text) is written and its turn holds the slot; answer B
    // validates the SAME card and queues behind it. The order is ESTABLISHED,
    // not assumed (see test 2): A's write is out before B is issued.
    let first = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-w", "terminal_id": terminal, "text": CUSTOM_ANSWER}),
    );
    host.pump_while(&[first], |v| v.writes.len() < 4);
    let second = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-w2", "terminal_id": terminal, "text": option}),
    );
    wait_for_one_waiter(&mut host, terminal);

    // The screen advances to a permission dialog and the watch is stopped
    // while B waits: the stop is signalled while the watcher is blocked in its
    // wait, so that wait still counts A's turn end — and the loop then exits
    // and drops the session before A has finished reading its turn.
    moved_on.store(true, Ordering::SeqCst);
    let stopped = host.tool(
        "minerva_agent_relay_watch_stop",
        json!({"terminal_id": terminal}),
    );
    assert_eq!(stopped["was_watching"], true, "{stopped}");
    // The watch must be gone before the queued answer takes the slot, and that
    // check is a real barrier: A's turn is pinned open by `a_turn_open`, so no
    // amount of servicing here can let A finish, let B take the slot and let the
    // stale refusal revive the watch underneath the sample. A sample that merely
    // ran before `await_reply(first)` would still race that revival, because
    // every host.tool and pump_while services capability calls.
    let mut watch_gone = false;
    for _ in 0..100 {
        let status = host.tool(
            "minerva_agent_relay_watch_status",
            json!({"terminal_id": terminal}),
        );
        if status["status"] == Value::Null {
            watch_gone = true;
            break;
        }
        // The watcher needs the host serviced to reach its exit, so each
        // sample is followed by a short pump rather than a bare retry.
        let t = std::time::Instant::now();
        host.pump_while(&[], |_| t.elapsed() < std::time::Duration::from_millis(50));
    }
    assert!(
        watch_gone,
        "the watch must be gone before the queued answer takes the slot"
    );
    // The other half of the barrier: A still owns the slot and B is still
    // queued behind it, so the null above was sampled in the window the oracle
    // is about. (The gate's own send_in_flight/send_waiters cannot say this any
    // more: watch_status reports them off the session, and the session is the
    // thing that just vanished.)
    assert!(
        !host.has_reply(first),
        "the sample must land while A still owns the slot"
    );
    assert!(
        !host.has_reply(second),
        "the sample must land before the queued answer takes the slot"
    );

    // Release A's turn; only now may the queued answer reach the front.
    a_turn_open.store(false, Ordering::SeqCst);
    host.await_reply(first);

    // B now owns the slot with no watch on the terminal. Nothing of its
    // answer — no arrow bytes, no Enter — may reach the dialog.
    let before = host.view().reads;
    host.pump_while(&[second], |v| v.reads < before + 8);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
        ],
        "the queued answer must not be written onto the permission dialog"
    );

    // It starts over as a plain prompt on a revived watch, and lands only once
    // the dialog is gone.
    cleared.store(true, Ordering::SeqCst);
    host.pump_while(&[second], |v| v.writes.len() < 6);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
            option.clone(),
            "\r".to_string(),
        ],
        "and lands as a plain submit once the dialog clears"
    );
}

// ── 10. The hold's clock and the slot's clock are separate ─────────────────

/// Oracle: an attached owner is never displaced, however much of its budget
/// the pre-write hold consumed. A held send waits out the modal BEFORE it takes
/// the prompt slot; the turn that follows still runs on the caller's full
/// budget, and a second caller must wait it out and fail at its own budget,
/// never writing into the window the owner is about to read.
#[test]
fn a_long_hold_does_not_shorten_the_owners_slot() {
    let mut host = FakeHost::start();
    let terminal = "t-hold-vs-slot";
    let cleared = Arc::new(AtomicBool::new(false));
    let c = Arc::clone(&cleared);
    host.screen = Box::new(move |_| {
        if c.load(Ordering::SeqCst) {
            (CLAUDE_IDLE.to_string(), 100)
        } else {
            (HOLD_CLAUDE_CHOOSER.to_string(), 100)
        }
    });
    // The owner's turn never ends: it spends the rest of its budget waiting.
    host.wait = Box::new(|_| quiet());
    host.watch_start(terminal, "claude");

    // A 5 s budget, ~3 s of which goes on the modal.
    let owner = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt A", "timeout_ms": 5000}),
    );
    let start = std::time::Instant::now();
    host.pump_while(&[owner], |_| {
        start.elapsed() < std::time::Duration::from_millis(3000)
    });
    cleared.store(true, Ordering::SeqCst);
    host.pump_while(&[owner], |v| v.writes.len() < 2);

    // The second caller arrives while the owner's turn is running and waits
    // 2.5 s — past what was left of the owner's budget, short of the whole.
    let second = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt B", "timeout_ms": 2500}),
    );
    let payload = common::unwrap_tool(&host.await_reply(second));
    assert_eq!(
        host.view().writes,
        vec!["prompt A".to_string(), "\r".to_string()],
        "the owner's turn was still running: nothing of prompt B may be written"
    );
    assert!(
        payload["error"].as_str().unwrap_or("").contains("still in flight"),
        "the second caller must be refused while the owner works: {payload}"
    );
    host.await_reply(owner);
}

// ── 11. A re-checking caller gives the slot back rather than sit on it ─────

/// Oracle: the hold and the prompt slot are two different resources, and what
/// clears a hold needs BOTH. A caller that passed the hold, queued for the
/// slot, and then finds a question card on screen must not wait for that card
/// WITH the slot in hand: the card's answer needs the slot, so it would queue
/// behind a prompt that cannot move until the answer lands, and the card would
/// be unanswerable through the relay for the whole budget. Pre-waiting only
/// covers cards already on screen when the caller arrived; this one appears
/// while it queues.
#[test]
fn a_caller_that_queued_releases_the_slot_when_the_screen_turns_into_a_card() {
    let mut host = FakeHost::start();
    let terminal = "t-requeue";
    // The card appears only when the first turn ENDS, which is after the
    // queued caller has passed the hold and taken its place in the queue.
    let carded = Arc::new(AtomicBool::new(false));
    let answered = Arc::new(AtomicBool::new(false));
    let (c, a) = (Arc::clone(&carded), Arc::clone(&answered));
    host.screen = Box::new(move |_| {
        if !c.load(Ordering::SeqCst) {
            (CLAUDE_IDLE.to_string(), 100)
        } else if !a.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_CHOOSER.to_string(), 130)
        } else {
            (CLAUDE_IDLE.to_string(), 160)
        }
    });
    let (c, a) = (Arc::clone(&carded), Arc::clone(&answered));
    host.wait = Box::new(move |_| {
        if !c.load(Ordering::SeqCst) {
            quiet()
        } else if !a.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_CHOOSER, 130)
        } else {
            settled(
                "\u{276f} answer\n\u{25cf} done with the question\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                160,
            )
        }
    });
    host.watch_start(terminal, "claude");

    // A holds the slot: its prompt is written and its turn has not ended.
    let asking = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-q", "terminal_id": terminal, "text": ASK_PROMPT}),
    );
    host.pump_while(&[asking], |v| v.writes.len() < 2);

    // B arrives while the screen is still writable: it passes the hold with
    // nothing in hand and queues for the slot.
    let queued = host.call_tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "fresh prompt"}),
    );
    wait_for_one_waiter(&mut host, terminal);

    // A's turn ends at a chooser card. B now takes the slot and sees a hold it
    // never waited out.
    carded.store(true, Ordering::SeqCst);
    let card = common::unwrap_tool(&host.await_reply(asking));
    assert_eq!(card["kind"], "question", "{card}");

    // Let B get past the queue and into its post-acquire re-check before the
    // answer is issued — that is the moment under test.
    let settling = std::time::Instant::now();
    host.pump_while(&[], |_| {
        settling.elapsed() < std::time::Duration::from_millis(600)
    });

    // The answer to that card must reach it PROMPTLY — it cannot while B sits
    // on the slot waiting for the very screen this answer clears.
    let answer = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-q", "terminal_id": terminal, "text": CUSTOM_ANSWER}),
    );
    let before = host.view().reads;
    host.pump_while(&[answer], |v| v.writes.len() < 4 && v.reads < before + 40);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
        ],
        "the answer must reach the card while the queued prompt waits"
    );

    // The card is answered; the screen clears and B's prompt lands last.
    answered.store(true, Ordering::SeqCst);
    host.await_reply(answer);
    host.await_reply(queued);
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            CUSTOM_ANSWER.to_string(),
            "\r".to_string(),
            "fresh prompt".to_string(),
            "\r".to_string(),
        ],
        "and the queued prompt lands after the turn it waited for"
    );
}

// ── 12. An owner is not aged out of its slot while it is still working ────

/// Oracle: an attached slot has no lease. Confirming the submit and waiting on
/// the turn both happen without touching the slot, and ownership ends only by
/// end(), detach() or the guard's drop, so the next caller waits and writes
/// nothing however long the owner's phases take.
fn owner_phase_case(name: &str, timeout_ms: u64, probe_at_ms: u64) {
    let mut host = FakeHost::start();
    let terminal = format!("t-owner-age-{name}");
    host.screen = Box::new(|_| (CLAUDE_IDLE.to_string(), 100));
    // The owner's turn never ends: it spends its whole budget waiting.
    host.wait = Box::new(|_| quiet());
    host.watch_start(&terminal, "claude");

    let owner = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt A", "timeout_ms": timeout_ms}),
    );
    host.pump_while(&[owner], |v| v.writes.len() < 2);
    let written_at = std::time::Instant::now();

    host.pump_while(&[owner], |_| {
        written_at.elapsed() < std::time::Duration::from_millis(probe_at_ms)
    });
    assert!(
        !host.has_reply(owner)
            && written_at.elapsed()
                < std::time::Duration::from_millis(timeout_ms + 500),
        "{name}: the test window was missed — the owner was {:?} into its turn",
        written_at.elapsed()
    );

    let probe = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt B", "timeout_ms": 1000}),
    );
    let payload = common::unwrap_tool(&host.await_reply(probe));
    assert_eq!(
        host.view().writes,
        vec!["prompt A".to_string(), "\r".to_string()],
        "{name}: the owner was still working; nothing of prompt B may be written"
    );
    assert!(
        payload["error"].as_str().unwrap_or("").contains("still in flight"),
        "{name}: the owner must keep its slot while it works: {payload}"
    );
    host.await_reply(owner);
}

#[test]
fn an_owner_still_confirming_its_submit_is_not_displaced() {
    // Probed 1200 ms in, while the confirmation samples run to 1500 ms.
    owner_phase_case("confirming", 1000, 1200);
}

#[test]
fn an_owner_waiting_for_its_own_turn_is_not_displaced() {
    // Probed 1700 ms in: the confirmation has ended and the owner is blocked
    // on its own turn, which runs to 3000 ms.
    owner_phase_case("turn-wait", 1500, 1700);
}

// ── 13. The screen is re-read after EVERY acquisition, queued or not ───────

/// Oracle: the hold's pre-wait and the prompt slot are taken in two steps, and
/// the screen can change in between. The caller ahead may end its turn AT a
/// permission dialog and release the slot, so this caller takes a FREE slot
/// (it never queued) onto a screen that is now `must_hold: true` — an Enter
/// there answers the dialog. The fake host scripts exactly that gap: the
/// pre-wait read is writable, every read after it is the dialog.
#[test]
fn a_screen_that_became_a_dialog_after_the_pre_wait_read_still_holds_the_write() {
    let mut host = FakeHost::start();
    let terminal = "t-recheck-free-slot";
    let reads = Arc::new(AtomicUsize::new(0));
    let r = Arc::clone(&reads);
    host.screen = Box::new(move |_| {
        if r.fetch_add(1, Ordering::SeqCst) == 0 {
            (CLAUDE_IDLE.to_string(), 100)
        } else {
            (HOLD_CLAUDE_PERMISSION.to_string(), 130)
        }
    });
    host.wait = Box::new(|_| quiet());
    host.watch_start(terminal, "claude");
    // Only the send's own reads are scripted; the watch loop polls with waits.
    reads.store(0, Ordering::SeqCst);

    // relay_ask's timeout IS the gate budget: the dialog never clears, so the
    // hold must end in an error rather than a write.
    let ask = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "fresh prompt", "timeout_ms": 1500}),
    );
    let payload = common::unwrap_tool(&host.await_reply(ask));

    assert!(
        host.view().writes.is_empty(),
        "the write landed on a dialog the caller never waited out: {:?}",
        host.view().writes
    );
    assert!(
        payload["error"].as_str().unwrap_or("").contains("wants a keystroke"),
        "the budget must end naming the screen that owns the keyboard: {payload}"
    );
}

// ── 14. An ask that gives up does not hand the terminal to the next prompt ─

/// Oracle: a timeout means THIS caller stopped waiting, not that the turn
/// ended. The harness is still working, and an ordinary busy screen is not a
/// hold — so a slot ENDED on timeout lets the next prompt write straight into
/// the running turn, and the second write overwrites the first turn's
/// bookkeeping. The turn is handed to the watch loop instead, and what frees
/// the slot is the COUNTED END of the turn, however long that takes: the probe
/// here waits out more than twice the ask's timeout (which is what the gate
/// used to age the handed-over slot by) with the turn still running.
#[test]
fn an_ask_that_times_out_does_not_free_the_slot_for_the_next_prompt() {
    let mut host = FakeHost::start();
    let terminal = "t-timeout-detach";
    host.screen = Box::new(|_| (CLAUDE_IDLE.to_string(), 100));
    // The turn runs until the test ends it; only then is a detection counted.
    let ended = Arc::new(AtomicBool::new(false));
    let e = Arc::clone(&ended);
    host.wait = Box::new(move |_| {
        if e.load(Ordering::SeqCst) {
            settled(
                "\u{276f} prompt A\n\u{25cf} answer A for the first prompt\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                130,
            )
        } else {
            quiet()
        }
    });
    host.watch_start(terminal, "claude");

    let owner = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt A", "timeout_ms": 2000}),
    );
    let owner_payload = common::unwrap_tool(&host.await_reply(owner));
    assert_eq!(
        owner_payload["timed_out"], true,
        "the owner must give up on a turn that never ends: {owner_payload}"
    );

    // Sit on the running turn for longer than twice the owner's timeout. A
    // slot that expires on elapsed time is free by now; the turn is not over.
    let handed_over = std::time::Instant::now();
    host.pump_while(&[], |_| {
        handed_over.elapsed() < std::time::Duration::from_millis(4_500)
    });

    // The next prompt arrives while that turn is still running.
    let next = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt B", "timeout_ms": 800}),
    );
    let payload = common::unwrap_tool(&host.await_reply(next));
    assert_eq!(
        host.view().writes,
        vec!["prompt A".to_string(), "\r".to_string()],
        "prompt B must not be written into the turn prompt A is still running"
    );
    assert!(
        payload["error"].as_str().unwrap_or("").contains("still in flight"),
        "the next caller must be refused while the turn runs: {payload}"
    );

    // The turn ends and the watch loop counts it: the terminal is free again.
    ended.store(true, Ordering::SeqCst);
    let after = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt C", "timeout_ms": 4000}),
    );
    host.pump_while(&[after], |v| v.writes.len() < 4);
    assert_eq!(
        host.view().writes,
        vec![
            "prompt A".to_string(),
            "\r".to_string(),
            "prompt C".to_string(),
            "\r".to_string(),
        ],
        "the counted end of prompt A's turn is what frees the terminal"
    );
    host.await_reply(after);
}

// ── 14b. Tearing the watch down releases a handed-over turn ────────────────

/// Oracle: a detached slot waits for a COUNTED detection, and only the watch
/// loop counts one. Restarting (or stopping) the watch means no detection on
/// that turn can ever arrive, so the slot would hold the terminal for the rest
/// of the process — the watch teardown has to release it. This is also what
/// recovers a wedged terminal now that no clock does.
#[test]
fn restarting_the_watch_releases_a_handed_over_turn() {
    let mut host = FakeHost::start();
    let terminal = "t-detach-watch-restart";
    host.screen = Box::new(|_| (CLAUDE_IDLE.to_string(), 100));
    // No detection is EVER counted on this terminal.
    host.wait = Box::new(|_| quiet());
    host.watch_start(terminal, "claude");

    let owner = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt A", "timeout_ms": 1000}),
    );
    let owner_payload = common::unwrap_tool(&host.await_reply(owner));
    assert_eq!(owner_payload["timed_out"], true, "{owner_payload}");

    // The watch is restarted (what the passthrough auto-revive does after an
    // idle reap). The turn it was watching is gone with it.
    host.watch_start(terminal, "claude");

    let next = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt B", "timeout_ms": 1500}),
    );
    host.pump_while(&[next], |v| v.writes.len() < 4);
    assert_eq!(
        host.view().writes,
        vec![
            "prompt A".to_string(),
            "\r".to_string(),
            "prompt B".to_string(),
            "\r".to_string(),
        ],
        "a restarted watch must not leave the terminal blocked by the old turn"
    );
    host.await_reply(next);
}

// ── 15. A notification is not an answer to anything ────────────────────────

/// The envelope the host puts in front of every minerva_terminal_notify line.
const NOTIFY_LINE: &str = "[MINERVA NOTIFY from codex] the board is green";

/// Oracle: everything a passthrough chat sends while a question card is
/// pending is treated as that card's answer — it bypasses the hold and is
/// typed into the card. A notification is not an answer: typed into a chooser
/// it becomes a custom answer nobody asked for, and the card is retired with
/// it. So the envelope is a FRESH prompt, held until the card clears, and the
/// card must still be there to answer afterwards.
#[test]
fn a_notification_is_held_by_a_live_card_and_leaves_it_answerable() {
    let mut host = FakeHost::start();
    let terminal = "t-notify-card";
    let answered = Arc::new(AtomicBool::new(false));
    let a = Arc::clone(&answered);
    host.screen = Box::new(move |v| {
        if v.writes.len() < 2 {
            (CLAUDE_IDLE.to_string(), 100)
        } else if !a.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_CHOOSER.to_string(), 130)
        } else {
            (CLAUDE_IDLE.to_string(), 160)
        }
    });
    let a = Arc::clone(&answered);
    host.wait = Box::new(move |v| {
        if v.writes.len() < 2 {
            quiet()
        } else if !a.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_CHOOSER, 130)
        } else {
            settled(
                "\u{276f} answer\n\u{25cf} done with the question\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                160,
            )
        }
    });
    host.watch_start(terminal, "claude");

    let question = host.tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-n", "terminal_id": terminal, "text": ASK_PROMPT}),
    );
    assert_eq!(question["kind"], "question", "{question}");

    // The notification arrives while the card is live. It must be held.
    let notify = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-n", "terminal_id": terminal, "text": NOTIFY_LINE}),
    );
    let before = host.view().reads;
    host.pump_while(&[notify], |v| v.reads < before + 6);
    assert_eq!(
        host.view().writes.len(),
        2,
        "the notification must not be typed into the card: {:?}",
        host.view().writes
    );

    // The card is still filed: its answer still bypasses the hold and reaches
    // it (option 1 is the cursor's own option, so it is Enter alone).
    let answer = host.call_tool(
        "minerva_agent_relay_passthrough_generate",
        json!({"chat_id": "chat-n", "terminal_id": terminal, "text": "1"}),
    );
    let before = host.view().reads;
    host.pump_while(&[answer], |v| v.writes.len() < 3 && v.reads < before + 40);
    assert_eq!(
        host.view().writes,
        vec![ASK_PROMPT.to_string(), "\r".to_string(), "\r".to_string()],
        "the answer to the card must still bypass the hold"
    );

    // The card is answered; the screen clears and the notification lands as a
    // plain submit of its own.
    answered.store(true, Ordering::SeqCst);
    host.await_reply(answer);
    let notify_payload = common::unwrap_tool(&host.await_reply(notify));
    assert_eq!(
        host.view().writes,
        vec![
            ASK_PROMPT.to_string(),
            "\r".to_string(),
            "\r".to_string(),
            NOTIFY_LINE.to_string(),
            "\r".to_string(),
        ],
        "the notification lands once, after the card it waited for"
    );
    assert_eq!(
        notify_payload["kind"], "answer",
        "and comes back as its own turn: {notify_payload}"
    );
}

// ── 11. The first prompt on an UNWATCHED terminal owns the slot too ─────────

/// The slot, not the detection, is what serialises prompts. A terminal with no
/// watch has no detection to classify screens with, and the send path used to
/// skip the whole gate for it — including the slot. But that very send
/// auto-starts the watch, so the NEXT caller found a detection and a free slot
/// and wrote straight into the first turn.
///
/// relay_ask is the path that reaches the gate unwatched: passthrough_generate
/// starts (or revives) the watch before it sends, so it never gets here with
/// gate_detection == None.
///
/// Oracle: two relay_asks on a terminal that was never watched, back to back.
/// Prompt two must not reach the terminal until turn one has been counted —
/// writes are exactly ["prompt one", "\r", "prompt two", "\r"].
#[test]
fn the_first_prompt_on_an_unwatched_terminal_still_owns_the_slot() {
    let mut host = FakeHost::start();
    let terminal = "t-unwatched-serialise";

    host.screen = Box::new(|v| (CLAUDE_IDLE.to_string(), 100 + v.writes.len() as u64));

    host.turn = Box::new(|v| {
        if v.writes.len() >= 4 {
            "\u{276f} prompt two\n\u{25cf} answer two for the second prompt\n".to_string()
        } else {
            "\u{276f} prompt one\n\u{25cf} answer one for the first prompt\n".to_string()
        }
    });

    // Turn one ends only once the test releases it, so the second ask is
    // observable while turn one is still running.
    let writes_at_turn_end: Arc<Mutex<Vec<usize>>> = Arc::new(Mutex::new(Vec::new()));
    let marks = Arc::clone(&writes_at_turn_end);
    let release_first = Arc::new(AtomicBool::new(false));
    let released = Arc::clone(&release_first);
    host.wait = Box::new(move |v| match v.writes.len() {
        2 if released.load(Ordering::SeqCst) => {
            marks.lock().unwrap().push(2);
            settled(
                "\u{276f} prompt one\n\u{25cf} answer one for the first prompt\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                130,
            )
        }
        n if n >= 4 => {
            marks.lock().unwrap().push(n);
            settled(
                "\u{276f} prompt two\n\u{25cf} answer two for the second prompt\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                160,
            )
        }
        _ => quiet(),
    });

    // NO watch_start: the first send is what starts the watch.
    let first = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt one"}),
    );
    // Prompt one's body and Enter are out, and its auto-started watch is live.
    host.pump_while(&[first], |v| v.writes.len() < 2);

    let second = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt two"}),
    );

    let mut status = Value::Null;
    for _ in 0..40 {
        status = host.tool(
            "minerva_agent_relay_watch_status",
            json!({"terminal_id": terminal}),
        );
        if status["status"]["send_waiters"] == json!(1) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    assert_eq!(
        host.view().writes.len(),
        2,
        "nothing of prompt two reached the terminal while turn one ran: {:?}",
        host.view().writes
    );
    assert_eq!(
        status["status"]["send_in_flight"], true,
        "the first prompt holds the slot even though it started unwatched: {status}"
    );
    assert_eq!(
        status["status"]["send_waiters"], 1,
        "the second ask is waiting, not writing: {status}"
    );

    release_first.store(true, Ordering::SeqCst);
    let first_payload = common::unwrap_tool(&host.await_reply(first));
    let second_payload = common::unwrap_tool(&host.await_reply(second));

    assert_eq!(
        host.view().writes,
        vec![
            "prompt one".to_string(),
            "\r".to_string(),
            "prompt two".to_string(),
            "\r".to_string(),
        ],
        "both prompts written once, in order, with no interleaving"
    );

    let marks = writes_at_turn_end.lock().unwrap().clone();
    assert_eq!(
        marks.first().copied(),
        Some(2),
        "the first turn ended while only prompt one had been written: {marks:?}"
    );

    assert_eq!(first_payload["timed_out"], false, "{first_payload}");
    assert!(
        first_payload["answer"].as_str().unwrap_or("").contains("answer one"),
        "the first ask got its own answer: {first_payload}"
    );
    assert_eq!(second_payload["timed_out"], false, "{second_payload}");
    assert!(
        second_payload["answer"].as_str().unwrap_or("").contains("answer two"),
        "the second ask got its own answer: {second_payload}"
    );
}

// ── 16. A prompt that QUEUED while the terminal was unwatched still holds ──

/// The detection the gate judges a write by has to be read after the slot is
/// taken, not before it is waited for.
///
/// Oracle: prompt A reaches the gate on a terminal nobody watches, so it skips
/// the hold; prompt B arrives a moment later, while A is still writing, and
/// finds no watch either — so B has no detection of its own and queues for the
/// slot. A's send auto-starts the watch, and A's turn ENDS at a permission
/// dialog. When A releases the slot, B is the caller that writes next, and the
/// screen it would write into is that dialog: an Enter there answers a modal.
/// So B must re-read the detection it now has and hold, and its prompt must
/// land only once the dialog is gone — writes are exactly
/// ["prompt A", "\r", "prompt B", "\r"].
#[test]
fn a_prompt_that_queued_unwatched_holds_on_the_dialog_the_turn_ended_at() {
    let mut host = FakeHost::start();
    let terminal = "t-unwatched-queued-dialog";

    // The dialog appears with prompt A's Enter and stays until the test clears
    // it — exactly the screen A's turn ends at.
    let cleared = Arc::new(AtomicBool::new(false));
    let screen_cleared = Arc::clone(&cleared);
    host.screen = Box::new(move |v| {
        if v.writes.len() >= 2 && !screen_cleared.load(Ordering::SeqCst) {
            (HOLD_CLAUDE_PERMISSION.to_string(), 130)
        } else {
            (CLAUDE_IDLE.to_string(), 100 + v.writes.len() as u64)
        }
    });
    let wait_cleared = Arc::clone(&cleared);
    host.wait = Box::new(move |v| {
        if v.writes.len() >= 2 && !wait_cleared.load(Ordering::SeqCst) {
            settled(HOLD_CLAUDE_PERMISSION, 130)
        } else {
            quiet()
        }
    });
    host.turn = Box::new(|_| HOLD_CLAUDE_PERMISSION.to_string());

    // NO watch_start: prompt A is what starts the watch.
    let first = host.call_tool(
        "minerva_agent_relay_relay_ask",
        json!({"terminal_id": terminal, "text": "prompt A", "timeout_ms": 8000}),
    );
    // A's body is out; its Enter, its auto-started watch and its arm are not.
    host.pump_while(&[first], |v| v.writes.is_empty());
    let status = host.tool(
        "minerva_agent_relay_watch_status",
        json!({"terminal_id": terminal}),
    );
    assert_eq!(
        status["status"],
        Value::Null,
        "prompt B has to reach the gate while the terminal is still unwatched: {status}"
    );

    // B arrives inside that window: no watch to give it a detection, so it can
    // only queue for the slot.
    let second = host.call_tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "prompt B", "arm": false}),
    );

    // A's turn ends at the dialog and A gives up the slot.
    let first_payload = common::unwrap_tool(&host.await_reply(first));
    assert_eq!(first_payload["timed_out"], false, "{first_payload}");

    // B now owns the terminal, with the dialog on screen.
    let held_since = std::time::Instant::now();
    host.pump_while(&[second], |_| {
        held_since.elapsed() < std::time::Duration::from_millis(1_500)
    });
    assert_eq!(
        host.view().writes,
        vec!["prompt A".to_string(), "\r".to_string()],
        "prompt B was written into the permission dialog: {:?}",
        host.view().writes
    );

    cleared.store(true, Ordering::SeqCst);
    let second_payload = common::unwrap_tool(&host.await_reply(second));
    assert_eq!(second_payload["ok"], true, "{second_payload}");
    assert_eq!(
        host.view().writes,
        vec![
            "prompt A".to_string(),
            "\r".to_string(),
            "prompt B".to_string(),
            "\r".to_string(),
        ],
        "prompt B must land once, after the dialog cleared"
    );
}

// ── 17. A slot handed over on an UNWATCHED terminal has no keeper ──────────

/// A detached slot is freed by a COUNTED detection, and only a watch loop
/// counts one. An unarmed send starts no watch, so a slot detached there would
/// wait for a keeper that does not exist and wedge the terminal for the rest
/// of the process.
///
/// Oracle: two unarmed sends on a terminal nobody watches. The second must
/// write promptly — writes are ["one", "\r", "two", "\r"] — instead of sitting
/// out the gate budget and erroring "still in flight".
#[test]
fn an_unarmed_send_on_an_unwatched_terminal_leaves_the_terminal_usable() {
    let mut host = FakeHost::start();
    let terminal = "t-unwatched-unarmed-send";
    host.screen = Box::new(|v| (CLAUDE_IDLE.to_string(), 100 + v.writes.len() as u64));
    host.wait = Box::new(|_| quiet());

    let first = host.tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "one", "arm": false}),
    );
    assert_eq!(first["ok"], true, "{first}");

    let second = host.call_tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "two", "arm": false}),
    );
    host.pump_while(&[second], |v| v.writes.len() < 4);
    let second = common::unwrap_tool(&host.await_reply(second));
    assert_eq!(
        second["ok"], true,
        "the second send was refused on a terminal nothing is watching: {second}"
    );
    assert_eq!(
        host.view().writes,
        vec![
            "one".to_string(),
            "\r".to_string(),
            "two".to_string(),
            "\r".to_string(),
        ],
        "both unarmed sends land, in order"
    );
}

/// ... and the ARMED send keeps its handed-over slot: it auto-starts the watch
/// before it gives the slot up, so there IS a keeper, and the turn it started
/// is protected until that watch counts the end.
///
/// Oracle: an armed send on an unwatched terminal, then a second send while
/// the turn still runs. Nothing of the second reaches the terminal until the
/// watch loop counts the first turn's end.
#[test]
fn an_armed_send_on_an_unwatched_terminal_keeps_its_turn_until_it_is_counted() {
    let mut host = FakeHost::start();
    let terminal = "t-unwatched-armed-send";
    host.screen = Box::new(|v| (CLAUDE_IDLE.to_string(), 100 + v.writes.len() as u64));

    let released = Arc::new(AtomicBool::new(false));
    let r = Arc::clone(&released);
    host.wait = Box::new(move |v| {
        if v.writes.len() >= 2 && r.load(Ordering::SeqCst) {
            settled(
                "\u{276f} one\n\u{25cf} the answer to the first prompt\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                130,
            )
        } else {
            quiet()
        }
    });

    let first = host.tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "one", "arm": true}),
    );
    assert_eq!(first["auto_started_watch"], true, "{first}");

    let second = host.call_tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "two", "arm": false}),
    );
    wait_for_one_waiter(&mut host, terminal);
    assert_eq!(
        host.view().writes,
        vec!["one".to_string(), "\r".to_string()],
        "the second send wrote into the turn the first one started: {:?}",
        host.view().writes
    );

    released.store(true, Ordering::SeqCst);
    host.pump_while(&[second], |v| v.writes.len() < 4);
    let second = common::unwrap_tool(&host.await_reply(second));
    assert_eq!(second["ok"], true, "{second}");
    assert_eq!(
        host.view().writes,
        vec![
            "one".to_string(),
            "\r".to_string(),
            "two".to_string(),
            "\r".to_string(),
        ],
        "the counted end of the first turn is what lets the second send write"
    );
}

// ── 9. A modal that appears after the write earns no recovery Enter ────────

/// A codex chooser drawn where the composer was, with the sent word on its
/// SELECTED row. No composer is on screen while the modal owns the keyboard,
/// so that option row is the last `›` row — the shape the stuck-composer rule
/// reads as unsubmitted text.
const MENU_AFTER_WRITE: &str = concat!(
    "\u{2022} Ready to apply the patch?\n",
    "\n",
    "\u{203a} 1. Yes\n",
    "  2. No\n",
    "Press enter to continue\n",
);

/// Oracle: the same `must_hold` ground truth the gate's pre-write hold rests
/// on (README §1) — an Enter on a chooser SELECTS the highlighted option. The
/// harness answering a send with a modal is the case where that keystroke
/// would be spent as a "recovery", so the confirmation must report the hold
/// and write nothing more.
#[test]
fn a_modal_answering_the_write_gets_no_extra_enter() {
    let mut host = FakeHost::start();
    let terminal = "t-submit-modal";
    host.screen = Box::new(|v| match v.writes.len() {
        0..=1 => (CODEX_IDLE.to_string(), 120),
        _ => (MENU_AFTER_WRITE.to_string(), 130),
    });
    host.wait = Box::new(|_| quiet());
    host.watch_start(terminal, "codex");

    let payload = host.tool(
        "minerva_agent_relay_send",
        json!({"terminal_id": terminal, "text": "Yes"}),
    );

    assert_eq!(
        host.view().writes,
        vec!["Yes".to_string(), "\r".to_string()],
        "the modal must not be answered by a recovery Enter: {payload}"
    );
    assert_eq!(payload["submit"]["extra_enter"], false, "{payload}");
    assert_eq!(payload["submit"]["state"], "held", "{payload}");
    assert_eq!(payload["submit"]["evidence"], "held:menu", "{payload}");
}
