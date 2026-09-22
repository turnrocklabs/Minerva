//! A passthrough turn that outlives one generate call.
//!
//! The host gives each call a budget (wait_budget_ms). A turn still running at
//! the budget comes back {kind:"pending"} and is resumed with the same
//! operation token until it ends. These tests use budgets of a few hundred ms
//! against the real plugin binary and the scripted FakeHost, so "past the old
//! 590 s wall" is a few resumes rather than ten minutes.
//!
//! Oracles: the host-side record of writes (the prompt goes out exactly once),
//! the screen reads (a lost turn is never read), and the replies' kinds.

mod common;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use common::{quiet, settled, FakeHost};

const CLAUDE_IDLE: &str = include_str!("fixtures/real/claude_idle_prompt.txt");
const GENERATE: &str = "minerva_agent_relay_passthrough_generate";

/// A host whose turn runs until `ended` is set, then settles with an answer.
fn long_turn_host(env: &[(&str, &str)]) -> (FakeHost, Arc<AtomicBool>) {
    let mut host = FakeHost::start_with_env(env);
    host.screen = Box::new(|v| (CLAUDE_IDLE.to_string(), 100 + v.writes.len() as u64 * 30));
    let ended = Arc::new(AtomicBool::new(false));
    let e = Arc::clone(&ended);
    host.wait = Box::new(move |v| {
        if e.load(Ordering::SeqCst) && !v.writes.is_empty() {
            settled(
                "\u{276f} long prompt\n\u{25cf} the long answer\n\n\u{276f}\u{a0}\n? for shortcuts\n",
                130,
            )
        } else {
            quiet()
        }
    });
    host.turn = Box::new(|_| "\u{276f} long prompt\n\u{25cf} the long answer\n".to_string());
    (host, ended)
}

fn generate(host: &mut FakeHost, terminal: &str, token: &str, text: &str, budget: u64) -> u64 {
    host.call_tool(GENERATE, json!({
        "chat_id": "chat-long", "terminal_id": terminal, "operation_token": token,
        "text": text, "wait_budget_ms": budget,
    }))
}

fn resume(host: &mut FakeHost, chat: &str, token: &str, budget: u64) -> u64 {
    host.call_tool(GENERATE, json!({
        "chat_id": chat, "operation_token": token, "text": "", "resume": true,
        "wait_budget_ms": budget,
    }))
}

fn reply(host: &mut FakeHost, id: u64) -> Value {
    common::unwrap_tool(&host.await_reply(id))
}

/// Pump the host for `ms` without a reply to wait for.
fn pump_for(host: &mut FakeHost, ms: u64) {
    let until = Instant::now() + Duration::from_millis(ms);
    host.pump_while(&[], |_| Instant::now() < until);
}

#[test]
fn a_turn_longer_than_one_call_is_resumed_to_its_one_answer() {
    let (mut host, ended) = long_turn_host(&[]);
    let terminal = "t-long-turn";
    host.watch_start(terminal, "claude");

    let id = generate(&mut host, terminal, "tok-long", "long prompt", 300);
    let first = reply(&mut host, id);
    assert_eq!(first["kind"], "pending", "{first}");
    assert_eq!(first["operation_token"], "tok-long", "{first}");

    // Still running: another pending, and nothing written again.
    let id = resume(&mut host, "chat-long", "tok-long", 300);
    assert_eq!(reply(&mut host, id)["kind"], "pending");

    // Another chat cannot resume this turn, and trying does not disturb it.
    let id = resume(&mut host, "chat-other", "tok-long", 300);
    assert_eq!(reply(&mut host, id)["kind"], "error");

    // Between calls the parked turn still owns the terminal: a new prompt
    // waits out its budget and writes nothing.
    let id = generate(&mut host, terminal, "tok-intruder", "intruding prompt", 400);
    let intruder = reply(&mut host, id);
    assert_eq!(intruder["kind"], "error", "{intruder}");
    assert!(intruder["text"].as_str().unwrap_or("").contains("nothing was written"), "{intruder}");

    // Two resumes at once: one waits on the turn, the other finds nothing.
    let waiting = resume(&mut host, "chat-long", "tok-long", 5_000);
    pump_for(&mut host, 300);
    let id = resume(&mut host, "chat-long", "tok-long", 300);
    assert_eq!(reply(&mut host, id)["kind"], "error", "a second resume must not share the turn");

    ended.store(true, Ordering::SeqCst);
    let answer = reply(&mut host, waiting);
    assert_eq!(answer["kind"], "answer", "{answer}");
    assert!(answer["text"].as_str().unwrap_or("").contains("the long answer"), "{answer}");
    assert_eq!(host.view().writes, vec!["long prompt".to_string()],
               "the prompt is written once across every call");

    // Finished: the token is spent, and the terminal takes the next prompt.
    let id = resume(&mut host, "chat-long", "tok-long", 300);
    assert_eq!(reply(&mut host, id)["kind"], "error");
    let id = generate(&mut host, terminal, "tok-next", "next prompt", 2_000);
    host.pump_while(&[id], |v| v.writes.len() < 2);
    assert_eq!(host.view().writes.last().map(String::as_str), Some("next prompt"));
}

#[test]
fn a_watch_restarted_during_a_wait_ends_the_turn_unread() {
    let (mut host, ended) = long_turn_host(&[]);
    let terminal = "t-long-restart";
    host.watch_start(terminal, "claude");

    let id = generate(&mut host, terminal, "tok-restart", "long prompt", 300);
    assert_eq!(reply(&mut host, id)["kind"], "pending");

    let waiting = resume(&mut host, "chat-long", "tok-restart", 10_000);
    pump_for(&mut host, 300);
    // The turn ends on screen, but the watch is replaced before the resume can
    // read it: the new watch's turn window does not describe this turn.
    ended.store(true, Ordering::SeqCst);
    host.watch_start(terminal, "claude");
    let lost = reply(&mut host, waiting);
    assert_eq!(lost["kind"], "error", "{lost}");
    assert!(lost["text"].as_str().unwrap_or("").contains("stopped or restarted"), "{lost}");
    assert_eq!(host.view().turn_reads, 0, "a lost turn is never read");
    assert!(!host.view().writes.iter().any(|w| w == "\u{1b}"), "and never interrupted");

    let id = resume(&mut host, "chat-long", "tok-restart", 300);
    assert_eq!(reply(&mut host, id)["kind"], "error", "the operation is over");
}

/// A Stop that arrives while the turn is parked is written at once — a host
/// that cancelled never resumes — and the in-place Stop's resume reports it.
#[test]
fn an_interrupt_between_calls_is_written_at_once_and_reported_by_the_resume() {
    let (mut host, ended) = long_turn_host(&[]);
    let terminal = "t-long-interrupt";
    host.watch_start(terminal, "claude");

    let id = generate(&mut host, terminal, "tok-stop", "long prompt", 300);
    assert_eq!(reply(&mut host, id)["kind"], "pending");
    let latched = host.tool("minerva_agent_relay_passthrough_interrupt",
                            json!({"chat_id": "chat-long", "operation_token": "tok-stop"}));
    assert_eq!(latched["accepted"], true, "a parked turn's token is still live: {latched}");
    assert!(host.view().writes.iter().any(|w| w == "\u{1b}"), "written by the Stop itself");

    let waiting = resume(&mut host, "chat-long", "tok-stop", 5_000);
    ended.store(true, Ordering::SeqCst);
    let answer = reply(&mut host, waiting);
    assert_eq!(answer["kind"], "answer", "{answer}");
    assert!(answer["text"].as_str().unwrap_or("").contains("[Interrupted]"), "{answer}");
    let escapes = host.view().writes.iter().filter(|w| *w == "\u{1b}").count();
    assert_eq!(escapes, 1);
}

/// A cancelled chat: the host sends Stop and never resumes. The ESC still
/// reaches the terminal, and the terminal takes the next prompt once the
/// interrupted turn has ended.
#[test]
fn a_stop_without_a_resume_still_interrupts_and_frees_the_terminal() {
    let (mut host, ended) = long_turn_host(&[]);
    let terminal = "t-long-cancelled";
    host.watch_start(terminal, "claude");

    let id = generate(&mut host, terminal, "tok-cancel", "long prompt", 300);
    assert_eq!(reply(&mut host, id)["kind"], "pending");
    let latched = host.tool("minerva_agent_relay_passthrough_interrupt",
                            json!({"chat_id": "chat-long", "operation_token": "tok-cancel"}));
    assert_eq!(latched["accepted"], true, "{latched}");
    let escapes = host.view().writes.iter().filter(|w| *w == "\u{1b}").count();
    assert_eq!(escapes, 1, "the Stop writes its ESC without waiting for a resume");

    // The ESC ends the turn; no resume ever comes; the next prompt goes out.
    ended.store(true, Ordering::SeqCst);
    let id = generate(&mut host, terminal, "tok-after-cancel", "next prompt", 15_000);
    host.pump_while(&[id], |v| !v.writes.iter().any(|w| w == "next prompt"));
    assert!(host.view().writes.iter().any(|w| w == "next prompt"));
}

#[test]
fn an_abandoned_pending_turn_releases_the_terminal_when_it_ends() {
    let (mut host, ended) = long_turn_host(&[("AGENT_RELAY_RESUME_LEASE_MS", "400")]);
    let terminal = "t-long-abandoned";
    host.watch_start(terminal, "claude");

    let id = generate(&mut host, terminal, "tok-gone", "long prompt", 300);
    assert_eq!(reply(&mut host, id)["kind"], "pending");

    // The host never resumes. After the lease the turn is handed to the watch
    // loop: it still owns the terminal while it runs...
    pump_for(&mut host, 1_000);
    let id = resume(&mut host, "chat-long", "tok-gone", 300);
    assert_eq!(reply(&mut host, id)["kind"], "error", "the lapsed operation cannot be resumed");
    assert_eq!(host.view().writes.len(), 1);

    // ...and its counted end frees it for the next prompt.
    ended.store(true, Ordering::SeqCst);
    let id = generate(&mut host, terminal, "tok-after", "next prompt", 5_000);
    host.pump_while(&[id], |v| v.writes.len() < 2);
    assert_eq!(host.view().writes.last().map(String::as_str), Some("next prompt"));
}

/// The host held the parked Stop's ESC behind an in-flight transaction, and no
/// resume will ever come (the chat was cancelled). The relay retries it.
#[test]
fn a_parked_stop_held_by_a_transaction_is_retried_without_a_resume() {
    let (mut host, _ended) = long_turn_host(&[]);
    let terminal = "t-long-stop-held";
    host.refuse_write = Box::new(|v| {
        let escapes = v.writes.iter().filter(|w| *w == "\u{1b}").count();
        (escapes == 1).then(|| json!({
            "success": false, "held": true, "outcome": "refused_transaction_in_flight",
            "error": "a transaction is in flight",
        }))
    });
    host.watch_start(terminal, "claude");

    let id = generate(&mut host, terminal, "tok-held-stop", "long prompt", 300);
    assert_eq!(reply(&mut host, id)["kind"], "pending");
    let latched = host.tool("minerva_agent_relay_passthrough_interrupt",
                            json!({"chat_id": "chat-long", "operation_token": "tok-held-stop"}));
    assert_eq!(latched["accepted"], true, "{latched}");
    let t0 = Instant::now();
    host.pump_while(&[], |v| v.writes.iter().filter(|w| *w == "\u{1b}").count() < 2
        && t0.elapsed() < Duration::from_secs(5));
    assert_eq!(host.view().writes.iter().filter(|w| *w == "\u{1b}").count(), 2,
               "one held ESC, then one delivered — no resume involved");
    pump_for(&mut host, 800);
    assert_eq!(host.view().writes.iter().filter(|w| *w == "\u{1b}").count(), 2, "and no more");
}

/// The turn ends and its read is under way when the watch is replaced: the
/// window the read returns may be the replacement's, so it is not delivered.
#[test]
fn a_read_that_outlives_its_watch_is_not_delivered() {
    let (mut host, ended) = long_turn_host(&[]);
    let terminal = "t-long-read-restart";
    // Only the first windowed read is held; read_turn may read again after it.
    host.hold_turn_reads = Box::new(|v| v.turn_reads == 1);
    host.watch_start(terminal, "claude");

    let id = generate(&mut host, terminal, "tok-read", "long prompt", 10_000);
    host.pump_while(&[id], |v| v.writes.is_empty());
    ended.store(true, Ordering::SeqCst);
    let t0 = Instant::now();
    host.pump_while(&[id], |v| v.turn_reads == 0 && t0.elapsed() < Duration::from_secs(10));
    assert_eq!(host.view().turn_reads, 1, "the turn's read is under way and held");
    let restart = host.call_tool("minerva_agent_relay_watch_start",
        json!({"terminal_id": terminal, "profile": "claude", "notify_mode": "armed"}));
    host.pump_while(&[restart], |_| t0.elapsed() < Duration::from_secs(10));
    assert!(host.has_reply(restart), "the watch restarts while the read is held");
    host.turn = Box::new(|_| "\u{25cf} a foreign turn's text\n".to_string());
    host.release_turn_reads();
    let lost = reply(&mut host, id);
    assert_eq!(lost["kind"], "error", "{lost}");
    assert!(lost["text"].as_str().unwrap_or("").contains("stopped or restarted"), "{lost}");
    assert!(!lost.to_string().contains("foreign"), "{lost}");
}

/// A resume that arrives while the relay is (re)writing a parked turn's Stop
/// waits for the turn instead of calling it gone.
#[test]
fn a_resume_during_a_parked_stop_retry_waits_for_the_turn() {
    let (mut host, ended) = long_turn_host(&[]);
    let terminal = "t-long-resume-during-retry";
    let escapes = |v: &common::HostView| v.writes.iter().filter(|w| *w == "\u{1b}").count();
    // The Stop's own ESC is held off by a transaction; the retry's is held
    // open, pinning the turn out of the store.
    host.refuse_write = Box::new(move |v| (escapes(v) == 1).then(|| json!({
        "success": false, "held": true, "outcome": "refused_transaction_in_flight",
        "error": "a transaction is in flight",
    })));
    host.hold_writes = Box::new(move |v| escapes(v) == 2);
    host.watch_start(terminal, "claude");

    let id = generate(&mut host, terminal, "tok-race", "long prompt", 300);
    assert_eq!(reply(&mut host, id)["kind"], "pending");
    host.tool("minerva_agent_relay_passthrough_interrupt",
              json!({"chat_id": "chat-long", "operation_token": "tok-race"}));
    let t0 = Instant::now();
    host.pump_while(&[], |v| escapes(v) < 2 && t0.elapsed() < Duration::from_secs(5));
    assert_eq!(escapes(&host.view()), 2, "the retry's ESC is in flight");

    // A resume whose budget runs out while the turn is borrowed: still pending.
    let id = resume(&mut host, "chat-long", "tok-race", 150);
    let short = reply(&mut host, id);
    assert_eq!(short["kind"], "pending", "{short}");
    assert_eq!(short["operation_token"], "tok-race", "{short}");

    let waiting = resume(&mut host, "chat-long", "tok-race", 5_000);
    pump_for(&mut host, 300);
    assert!(!host.has_reply(waiting), "the resume waits while the turn is borrowed");
    host.release_writes();
    ended.store(true, Ordering::SeqCst);
    let answer = reply(&mut host, waiting);
    assert_eq!(answer["kind"], "answer", "{answer}");
    assert!(answer["text"].as_str().unwrap_or("").contains("[Interrupted]"), "{answer}");
}
