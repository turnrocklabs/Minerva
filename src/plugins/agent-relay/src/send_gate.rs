// send_gate.rs — the guard every relay prompt passes through before it
// becomes keystrokes in someone's terminal.
//
// Three jobs, in the order a send meets them:
//
//   1. HOLD — refuse to write while the screen is a modal. detector::hold_reason
//      classifies the screen; the gate re-reads until it clears or the budget
//      runs out, and an expired budget is an ERROR, never a write. A blind
//      Enter on a menu selects whatever is under the caret.
//
//   2. SERIALISE — one outstanding relay prompt per terminal. The second
//      caller waits for the first turn to END before it writes, so the
//      first turn's pre-write screen anchor and submit timestamp still
//      describe exactly one prompt. Ordering BETWEEN harness-side messages is
//      the harness's own (both queue an Enter-submitted message in order);
//      what the gate protects is the relay's per-turn bookkeeping.
//      The slot is released explicitly by a caller that waits for its own turn
//      (relay_ask), once it has READ that turn — the answer window opens at the
//      pre-write screen, so a prompt written while it is being read lands inside
//      it. A caller that does not wait (a bare send) detaches instead, and the
//      next counted detection on the terminal frees the slot.
//
//   3. CONFIRM — sample the screen after the write and classify it. The one
//      measured failure shape (codex, text settled in the composer, no echo,
//      nothing running) is recovered with exactly one extra Enter; every other
//      outcome, confirmed or not, gets no keystroke. A screen that is a HOLD
//      state is classified as held, never as a stuck composer: the modal's
//      selected row wears the composer's caret, and the recovery Enter would
//      answer it.
//
// The gate also publishes what it sees (hold reason, waiter count, whether a
// turn is outstanding) for watch_status.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::detector::{self, CompiledDetection, HoldReason, SubmitState};
use crate::router::Router;
use crate::watcher;

/// How often the gate re-reads the screen while holding or queueing.
pub const POLL_MS: u64 = 250;

/// Samples taken after a write before the gate gives up on confirming, and the
/// gap between them. The corpus was captured ~1 s after the Enter byte; a fast
/// confirmation exits on the first sample that shows evidence.
const CONFIRM_SAMPLES: usize = 6;
const CONFIRM_GAP_MS: u64 = 250;

/// A stuck composer is a SETTLED state (byte-identical 3 s apart), so the gate
/// re-reads once after this pause before spending an extra Enter on it.
const STUCK_RECHECK_MS: u64 = 700;

/// How long the screen is watched after the recovery Enter.
const RECOVERY_SAMPLES: usize = 6;

// ---------------------------------------------------------------------------
// Per-terminal gate state
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct InFlight {
    token: u64,
    /// Detection serial at the moment the prompt was written. The turn is over
    /// once the watch loop counts a detection past this.
    serial_at_write: u64,
    /// True once the writer handed the turn to the watch loop instead of
    /// waiting for it (a bare send, or an ask that stopped waiting). Only such
    /// a slot is freed by a counted detection; a slot whose owner is still
    /// reading its own turn is freed by that owner.
    detached: bool,
}

#[derive(Debug, Default)]
struct Gate {
    in_flight: Option<InFlight>,
    waiters: usize,
    hold_reason: Option<String>,
}

type GateMap = Arc<Mutex<HashMap<String, Gate>>>;

static GATES: Mutex<Option<GateMap>> = Mutex::new(None);
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);

fn gates() -> GateMap {
    let mut guard = GATES.lock().unwrap();
    guard
        .get_or_insert_with(|| Arc::new(Mutex::new(HashMap::new())))
        .clone()
}

fn with_gate<R>(terminal_id: &str, f: impl FnOnce(&mut Gate) -> R) -> R {
    let map = gates();
    let mut guard = map.lock().unwrap();
    f(guard.entry(terminal_id.to_string()).or_default())
}

/// True when nothing holds the terminal's prompt slot any more: no slot, or a
/// detached slot whose turn the watcher has counted the end of.
///
/// A DETACHED slot is freed by the next COUNTED detection, whichever turn it
/// belongs to — a human typing in the same terminal ends a turn the watch loop
/// counts, and that frees the relay's slot as surely as the relay's own turn
/// would. So "one outstanding relay prompt per terminal" holds against other
/// relay sends, not against a terminal someone is also driving by hand. That
/// is the intended trade: the alternative is matching the ended turn to the
/// slot, which the detector cannot do (a detection carries no identity), and
/// a slot that only its own turn could free would outlive every human turn.
///
/// There is deliberately no age here, on EITHER kind of slot. Elapsed time is
/// not evidence that a turn has ended: the harness is still working, an
/// ordinary busy screen is not a hold, and a second prompt written on a clock
/// lands inside the running turn and overwrites its bookkeeping. On an
/// attached slot, time is not evidence the owner has stopped either — a single
/// legitimate host call (a slow host.terminal.read) can outlast any age, and
/// the displaced owner's later progress stamp silently does nothing, because
/// its token is gone.
///
/// So a detached slot has exactly three exits, all of them evidence:
///   * the watcher COUNTS a detection past the write — the turn ended (the
///     terminal's own agent_exited / terminal_closed detections are counted
///     detections too, and so is the idle reap's timed_out);
///   * the watch on the terminal is stopped or restarted — watch_stop and
///     watch_start clear a detached slot, because nothing is left that could
///     ever count that turn's end (`release_detached`);
///   * the plugin restarts.
/// A turn whose end the watcher never counts is therefore cleared by the idle
/// reap: an UNARMED watch idle past watch_timeout_ms (10 min) emits timed_out
/// — a counted detection — and passthrough auto-revive restarts the watch
/// afterwards. A terminal wedged with an armed watch is released by watch_stop.
///
/// An ATTACHED slot — the writer is waiting for this turn and will read its
/// answer — is NEVER free: the end of the turn is the moment its owner starts
/// READING it, and a prompt written then lands inside the window being read.
/// It is freed only by end(), by detach(), or by the owner's thread going away
/// (the guard releases on Drop, including on an unwind). An owner blocked on a
/// host reply that never comes keeps the terminal until the plugin restarts
/// (capability calls have no timeout); its guard drops when the thread unwinds.
fn slot_free(terminal_id: &str, gate: &Gate) -> bool {
    match gate.in_flight {
        None => true,
        Some(ref f) if f.detached => watcher::detection_serial(terminal_id) > f.serial_at_write,
        Some(_) => false,
    }
}

// ---------------------------------------------------------------------------
// The prompt slot
// ---------------------------------------------------------------------------

/// Ownership of a terminal's single outstanding relay prompt.
///
/// The slot is a GUARD: whichever way the owner's thread leaves — end(),
/// detach(), an early return or an unwind — the slot stops being owned. An
/// attached slot is only kept alive by an owner that is still there.
pub struct TurnSlot {
    terminal_id: String,
    token: u64,
    /// True once end() or detach() has decided this slot's fate, so the drop
    /// guard does nothing.
    settled: bool,
}

impl TurnSlot {
    /// Release the slot now — the caller has seen its own turn end and read it.
    pub fn end(mut self) {
        self.release();
    }

    /// Leave the slot outstanding — the caller wrote a prompt but is not
    /// waiting for the turn (a bare send, or an ask that gave up on a turn
    /// that is still running). The turn keeps the terminal until the watcher
    /// counts its end, or until the watch itself is stopped or restarted.
    pub fn detach(mut self) {
        let token = self.token;
        with_gate(&self.terminal_id, |g| {
            if let Some(f) = g.in_flight.as_mut() {
                if f.token == token {
                    f.detached = true;
                }
            }
        });
        self.settled = true;
    }

    fn release(&mut self) {
        if self.settled {
            return;
        }
        self.settled = true;
        let token = self.token;
        with_gate(&self.terminal_id, |g| {
            if g.in_flight.as_ref().map(|f| f.token) == Some(token) {
                g.in_flight = None;
            }
        });
    }

    /// Stamp the write point on the slot: the turn this slot covers is the
    /// first one counted after `serial`, the detection serial as it stood
    /// immediately before the write.
    pub fn mark_written(&self, serial: u64) {
        let token = self.token;
        with_gate(&self.terminal_id, |g| {
            if let Some(f) = g.in_flight.as_mut() {
                if f.token == token {
                    f.serial_at_write = serial;
                }
            }
        });
    }
}

impl Drop for TurnSlot {
    fn drop(&mut self) {
        self.release();
    }
}

/// Take the terminal's prompt slot, waiting for any outstanding relay turn to
/// end first. Returns Err when `budget_ms` runs out with a turn still in
/// flight — the caller must NOT write.
///
/// `budget_ms` is how long THIS call waits for the slot, and it is the only
/// clock in the gate: the slot itself never ages (see slot_free). So the wait
/// here is a wait, never a steal — a caller whose budget lapses errors out and
/// writes nothing.
pub fn begin_turn(terminal_id: &str, budget_ms: u64) -> Result<TurnSlot, String> {
    let deadline = Instant::now() + Duration::from_millis(budget_ms);
    let mut counted_as_waiter = false;

    loop {
        let taken = with_gate(terminal_id, |g| {
            if slot_free(terminal_id, g) {
                if counted_as_waiter {
                    g.waiters = g.waiters.saturating_sub(1);
                }
                let token = NEXT_TOKEN.fetch_add(1, Ordering::SeqCst);
                g.in_flight = Some(InFlight {
                    token,
                    serial_at_write: watcher::detection_serial(terminal_id),
                    detached: false,
                });
                Some(token)
            } else {
                if !counted_as_waiter {
                    g.waiters += 1;
                }
                None
            }
        });

        if let Some(token) = taken {
            return Ok(TurnSlot {
                terminal_id: terminal_id.to_string(),
                token,
                settled: false,
            });
        }
        counted_as_waiter = true;

        if Instant::now() >= deadline {
            with_gate(terminal_id, |g| g.waiters = g.waiters.saturating_sub(1));
            return Err(format!(
                "another relay prompt is still in flight on terminal {terminal_id} \
                 after {budget_ms} ms; nothing was written"
            ));
        }
        std::thread::sleep(Duration::from_millis(POLL_MS));
    }
}

/// Drop a DETACHED slot on this terminal: the watch that would have counted
/// its turn's end is going away (watch_stop) or being replaced (watch_start,
/// including the passthrough auto-revive after an idle reap), so no detection
/// on that turn can ever arrive. An ATTACHED slot is left alone — its owner is
/// alive and still reading its own turn, and send auto-starts a watch from
/// INSIDE the owner's own turn.
pub fn release_detached(terminal_id: &str) {
    with_gate(terminal_id, |g| {
        if g.in_flight.as_ref().is_some_and(|f| f.detached) {
            g.in_flight = None;
        }
    });
}

// ---------------------------------------------------------------------------
// Hold
// ---------------------------------------------------------------------------

/// The phrase every gate refusal ends with: the one thing a caller can rely
/// on to tell "held, retry later" from a failed write.
pub const HOLD_MARK: &str = "nothing was written";

/// Block until the terminal's screen is one a prompt may be written into.
///
/// Returns the last screen read as (content, total_scrollback_rows) so the
/// caller can use it as the pre-write anchor — the anchor must describe the
/// screen the write actually lands on, not one sampled before the hold.
/// Returns Err when the hold outlives `budget_ms`.
pub fn wait_until_writable(
    terminal_id: &str,
    cd: &CompiledDetection,
    router: &Arc<Router>,
    budget_ms: u64,
) -> Result<Option<(String, u64)>, String> {
    let deadline = Instant::now() + Duration::from_millis(budget_ms);

    loop {
        let last_reason = match peek_writable(terminal_id, cd, router) {
            Ok(screen) => return Ok(screen),
            Err(reason) => reason,
        };

        if Instant::now() >= deadline {
            if last_reason == UNREADABLE {
                return Err(format!(
                    "terminal {terminal_id} could not be read, so the gate could \
                     not tell whether a modal owns the keyboard; nothing was \
                     written"
                ));
            }
            return Err(format!(
                "terminal {terminal_id} is showing a {last_reason} that wants a \
                 keystroke; nothing was written. Answer it (or clear it) and \
                 send again"
            ));
        }
        std::thread::sleep(Duration::from_millis(POLL_MS));
    }
}

/// ONE look at the screen: Ok with the screen a prompt may be written into,
/// Err with the reason something else owns the keyboard.
///
/// A screen that cannot be read cannot be classified, and an unclassified
/// screen is NOT writable — the modal the gate exists to protect looks exactly
/// like this from here. So a read error, or a reply with no content at all, is
/// a hold like any other. Never a blind write.
pub fn peek_writable(
    terminal_id: &str,
    cd: &CompiledDetection,
    router: &Arc<Router>,
) -> Result<Option<(String, u64)>, String> {
    let screen = match router
        .call_capability("host.terminal.read", json!({ "terminal_id": terminal_id }))
    {
        Err(_) => None,
        Ok(result) => result
            .get("content")
            .and_then(|v| v.as_str())
            .map(|content| {
                let rows = result.get("total_scrollback_rows").and_then(|v| v.as_u64());
                (content.to_string(), rows)
            }),
    };

    match screen {
        None => {
            note_hold_reason(terminal_id, Some(UNREADABLE));
            Err(UNREADABLE.to_string())
        }
        Some(screen) => match detector::hold_reason(&screen.0, cd) {
            None => {
                note_hold_reason(terminal_id, None);
                Ok(screen.1.map(|rows| (screen.0, rows)))
            }
            Some(reason) => {
                note_hold_reason(terminal_id, Some(reason.as_str()));
                Err(reason.as_str().to_string())
            }
        },
    }
}

/// The hold reason published while the gate cannot read the screen at all.
const UNREADABLE: &str = "unreadable screen";

// ---------------------------------------------------------------------------
// Confirm
// ---------------------------------------------------------------------------

/// Sample the screen until the write is confirmed, recovering the one measured
/// stuck shape with a single extra Enter. Returns the JSON the send result
/// carries: {"state": "...", "evidence": "..."|null, "extra_enter": bool}.
///
/// `baseline` is the PRE-WRITE screen, when one was read. Echo evidence is
/// counted against it, so an echo of the same text left by an EARLIER submit
/// cannot confirm this one (detector::confirm_submit).
///
/// A hold state reached here answers with "held" and evidence `held:<reason>`,
/// and takes the same exit as any unconfirmed write: no keystroke.
pub fn confirm_submitted(
    terminal_id: &str,
    body: &str,
    cd: &CompiledDetection,
    router: &Arc<Router>,
    baseline: Option<&str>,
) -> Value {
    let (state, evidence) =
        sample_until_settled(terminal_id, body, cd, router, CONFIRM_SAMPLES, baseline);
    if state != SubmitState::StuckInComposer {
        return confirmation_json(&state, evidence, false);
    }

    // Settled-state check: the stuck shape does not change on its own, so a
    // screen that moves between these two reads was mid-repaint, not stuck.
    std::thread::sleep(Duration::from_millis(STUCK_RECHECK_MS));
    match read_screen(terminal_id, router) {
        None => return confirmation_json(&SubmitState::Unconfirmed, None, false),
        Some(screen) => {
            let again = detector::confirm_submit(&screen, body, cd, baseline);
            if again != SubmitState::StuckInComposer {
                let evidence = evidence_of(&again);
                return confirmation_json(&again, evidence, false);
            }
        }
    }

    log::info!("send_gate: {terminal_id} composer still holds the message — one extra Enter");
    if router
        .call_capability(
            "host.terminal.write",
            json!({ "terminal_id": terminal_id, "text": "\r", "raw": true }),
        )
        .is_err()
    {
        return confirmation_json(&SubmitState::Unconfirmed, None, false);
    }

    let (state, evidence) =
        sample_until_settled(terminal_id, body, cd, router, RECOVERY_SAMPLES, baseline);
    confirmation_json(&state, evidence, true)
}

/// Poll the screen up to `samples` times, returning as soon as the write is
/// confirmed or the stuck shape appears.
fn sample_until_settled(
    terminal_id: &str,
    body: &str,
    cd: &CompiledDetection,
    router: &Arc<Router>,
    samples: usize,
    baseline: Option<&str>,
) -> (SubmitState, Option<&'static str>) {
    let mut last = SubmitState::Unconfirmed;
    for _ in 0..samples {
        std::thread::sleep(Duration::from_millis(CONFIRM_GAP_MS));
        let Some(screen) = read_screen(terminal_id, router) else {
            continue;
        };
        last = detector::confirm_submit(&screen, body, cd, baseline);
        match last {
            SubmitState::Submitted(_) | SubmitState::StuckInComposer | SubmitState::Held(_) => {
                break
            }
            SubmitState::Unconfirmed => {}
        }
    }
    let evidence = evidence_of(&last);
    (last, evidence)
}

fn evidence_of(state: &SubmitState) -> Option<&'static str> {
    match state {
        SubmitState::Submitted(e) => Some(e),
        SubmitState::Held(reason) => Some(match reason {
            HoldReason::Dialog => "held:dialog",
            HoldReason::Menu => "held:menu",
            HoldReason::ConfirmFooter => "held:confirm_footer",
        }),
        _ => None,
    }
}

fn confirmation_json(state: &SubmitState, evidence: Option<&str>, extra_enter: bool) -> Value {
    let name = match state {
        SubmitState::Submitted(_) => "submitted",
        SubmitState::StuckInComposer => "stuck_in_composer",
        SubmitState::Held(_) => "held",
        SubmitState::Unconfirmed => "unconfirmed",
    };
    json!({
        "state": name,
        "evidence": evidence,
        "extra_enter": extra_enter,
    })
}

fn read_screen(terminal_id: &str, router: &Arc<Router>) -> Option<String> {
    router
        .call_capability("host.terminal.read", json!({ "terminal_id": terminal_id }))
        .ok()
        .map(|r| {
            r.get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        })
}

// ---------------------------------------------------------------------------
// Published state
// ---------------------------------------------------------------------------

/// Record what the last screen classification saw. Called by the watch loop on
/// every settled sample and by the gate while it holds.
pub fn note_hold_reason(terminal_id: &str, reason: Option<&str>) {
    with_gate(terminal_id, |g| {
        g.hold_reason = reason.map(|r| r.to_string());
    });
}

/// The gate's state for watch_status: (hold reason, waiting callers, whether a
/// relay prompt is outstanding).
pub fn status(terminal_id: &str) -> (Option<String>, usize, bool) {
    // Read-only: a status query must not create gate state for a terminal
    // nothing has ever sent to.
    let map = gates();
    let guard = map.lock().unwrap();
    match guard.get(terminal_id) {
        None => (None, 0, false),
        Some(g) => (g.hold_reason.clone(), g.waiters, !slot_free(terminal_id, g)),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// The corpus tests of the two screen judgements this gate makes. They live
// next door so the gate and its fixture harness each stay a readable file.
#[cfg(test)]
#[path = "hold_submit_tests.rs"]
mod corpus_tests;

/// Slot ownership: who may take the terminal's prompt slot, and when an owner
/// stops counting as one. The screen-facing halves of the gate are driven end
/// to end against the real binary in tests/send_gate_integration.rs.
#[cfg(test)]
mod slot_tests {
    use super::*;

    /// The gate reads the watcher's detection serial, whose cache the plugin
    /// initialises at startup; a unit test has no startup.
    fn ready() {
        watcher::init_sessions();
    }

    /// An attached slot has no age: its owner is alive, and only the owner
    /// ends it. Here the owner has been working longer than any budget, with
    /// no sign of life to give — exactly what a slow host.terminal.read looks
    /// like from outside, since nothing can be stamped from INSIDE a blocking
    /// call. A second caller admitted now would write into the window being
    /// read.
    #[test]
    fn an_owner_inside_a_long_host_call_is_not_displaced() {
        ready();
        let terminal = "slot-tests-working-owner";
        let slot = begin_turn(terminal, 400).expect("first caller takes the slot");
        std::thread::sleep(Duration::from_millis(500));

        let second = begin_turn(terminal, 50);
        assert!(
            second.is_err(),
            "an owner in a long host call kept its slot"
        );
        slot.end();
        begin_turn(terminal, 50).expect("the slot is free once the owner ends its turn");
    }

    /// A DETACHED slot has no age either: nobody is waiting for that turn, but
    /// it is still RUNNING, and the next caller's prompt would land inside it.
    /// Only a counted detection says the turn ended.
    #[test]
    fn a_detached_slot_does_not_expire_on_time() {
        ready();
        let terminal = "slot-tests-detached-age";
        begin_turn(terminal, 100)
            .expect("first caller takes the slot")
            .detach();
        std::thread::sleep(Duration::from_millis(400));

        assert!(
            begin_turn(terminal, 50).is_err(),
            "a detached slot was freed by the clock, with the turn still running"
        );
    }

    /// ... and it frees the moment the watcher counts a detection past the
    /// write, whichever turn that detection belongs to.
    #[test]
    fn a_detached_slot_frees_on_a_counted_detection() {
        ready();
        let terminal = "slot-tests-detached-detection";
        begin_turn(terminal, 100)
            .expect("first caller takes the slot")
            .detach();
        assert!(begin_turn(terminal, 0).is_err(), "held until the turn ends");

        watcher::bump_detection_serial_for_tests(terminal);
        begin_turn(terminal, 0).expect("a counted detection frees the detached slot");
    }

    /// Tearing the watch down frees a detached slot: nothing is left that
    /// could ever count that turn's end. An attached slot is untouched — send
    /// auto-starts a watch from inside its owner's own turn.
    #[test]
    fn stopping_the_watch_frees_a_detached_slot_but_not_an_attached_one() {
        ready();
        let terminal = "slot-tests-watch-teardown";
        let owner = begin_turn(terminal, 100).expect("first caller takes the slot");
        release_detached(terminal);
        assert!(
            begin_turn(terminal, 0).is_err(),
            "an attached slot must survive a watch restart"
        );
        owner.detach();
        release_detached(terminal);
        begin_turn(terminal, 0).expect("a torn-down watch frees the detached slot");
    }

    /// A wedged owner is recovered by its GUARD, not by a clock: while the
    /// owner's thread lives the terminal stays held (its own call timeouts
    /// bound that), and the moment the thread leaves — return, error, unwind —
    /// the slot is free again.
    #[test]
    fn a_wedged_owner_is_freed_when_its_guard_drops() {
        ready();
        let terminal = "slot-tests-wedged-owner";
        let slot = begin_turn(terminal, 400).expect("first caller takes the slot");
        std::thread::sleep(Duration::from_millis(500));
        assert!(
            begin_turn(terminal, 50).is_err(),
            "a live owner must not be aged out of its slot"
        );
        drop(slot);
        begin_turn(terminal, 50).expect("a wedged owner's slot frees when its guard drops");
    }

    /// The slot is a guard: an owner thread that goes away without ending its
    /// turn (an early return, an unwind) releases it.
    #[test]
    fn a_dropped_slot_releases() {
        ready();
        let terminal = "slot-tests-dropped";
        {
            let _slot = begin_turn(terminal, 60_000).expect("take the slot");
            assert!(begin_turn(terminal, 0).is_err(), "held while the owner lives");
        }
        begin_turn(terminal, 0).expect("a dropped slot is free again");
    }
}
