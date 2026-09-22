//! Passthrough operations: the host's token for one chat turn, its interrupt
//! latch, and — when the turn outlives one generate call — the parked turn
//! that later resume calls wait on.
//!
//! A token's life:
//!   register   a generate call arrives with a token that is not active; the
//!              token belongs to that terminal from then on.
//!   interrupt  passthrough_interrupt latches it; whichever call is waiting on
//!              the turn writes one guarded ESC.
//!   park       the host's per-call budget ran out while the turn still runs:
//!              the turn, with its prompt slot, is parked under the token and
//!              the call answers {kind:"pending"}. The host resumes with the
//!              same token; each resume takes the turn out and re-parks it.
//!   finish     the turn was read, or failed: the token is forgotten.
//!
//! A parked turn is let go without a resume in two cases, both by the sweeper:
//!   * its lease lapses — the host stopped resuming (chat closed, Minerva
//!     gone). The turn is handed to the watch loop exactly like a timed-out
//!     relay_ask: nobody owns it any more, but a turn still running keeps the
//!     terminal until its end is counted or the watch is stopped (an end that
//!     is never counted still needs that explicit watch stop);
//!   * its watch was stopped or restarted (the epoch changed) — nothing can
//!     count that turn's end any more, so it is handed over at once.
//! A call that is waiting notices the same watch change itself
//! (continue_turn's check_watch) and ends the operation with an error.
//! A resume holds the parked turn outside the store while it waits, so two
//! resumes can never wait on, read or release the same turn. A turn taken
//! out only to write its Stop is "borrowed": a resume arriving then waits for
//! it rather than reporting it gone. No I/O happens under the store's lock.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, Once, OnceLock};
use std::time::{Duration, Instant};

use crate::router::Router;
use crate::RunningTurn;

/// A turn whose generate call returned "pending", waiting for its resume.
pub(crate) struct PendingTurn {
    pub(crate) turn: RunningTurn,
    pub(crate) chat_id: String,
    /// The question card this turn answered, if any (retired when it ends).
    pub(crate) filed_region: Option<String>,
    pub(crate) started: Instant,
    parked_at: Instant,
    /// Set once an interrupt was written while parked: the host that asked
    /// may have cancelled and will not resume, so the turn is let go sooner.
    interrupted: bool,
}

impl PendingTurn {
    pub(crate) fn new(turn: RunningTurn, chat_id: &str, filed_region: Option<String>,
                      started: Instant) -> Self {
        PendingTurn { turn, chat_id: chat_id.to_string(), filed_region,
                      started, parked_at: Instant::now(), interrupted: false }
    }
}

#[derive(Default)]
struct Ops {
    owners: HashMap<String, String>, // token → terminal_id
    interrupted: HashSet<String>,
    parked: HashMap<String, PendingTurn>,
    /// Parked turns out of the store for an interrupt write: token →
    /// (chat_id, when the turn started).
    borrowed: HashMap<String, (String, Instant)>,
}

/// What a resume finds under its token.
pub(crate) enum Take {
    Turn(PendingTurn),
    /// Out for a moment to have its Stop written; ask again shortly. Carries
    /// when the turn started, for a pending reply.
    Busy(Instant),
    Gone,
}

static OPS: Mutex<Option<Ops>> = Mutex::new(None);
static SWEEPER: Once = Once::new();
/// What the sweeper writes a parked turn's pending Stop through.
static ROUTER: OnceLock<Arc<Router>> = OnceLock::new();

pub(crate) fn set_router(router: Arc<Router>) {
    let _ = ROUTER.set(router);
}

fn with_ops<R>(f: impl FnOnce(&mut Ops) -> R) -> R {
    let mut guard = OPS.lock().unwrap();
    f(guard.get_or_insert_with(Ops::default))
}

/// How long a parked turn waits for its next resume. The host resumes as soon
/// as a pending reply lands, so this only has to outlast a slow round trip;
/// AGENT_RELAY_RESUME_LEASE_MS overrides it (tests).
fn resume_lease() -> Duration {
    static LEASE: OnceLock<Duration> = OnceLock::new();
    *LEASE.get_or_init(|| {
        let ms = std::env::var("AGENT_RELAY_RESUME_LEASE_MS").ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(120_000);
        Duration::from_millis(ms)
    })
}

/// The lease of a parked turn an interrupt was written into: long enough for
/// an in-place Stop's resume to collect the "[Interrupted]" reply, short
/// enough that a cancelled chat frees its terminal promptly.
const INTERRUPTED_LEASE: Duration = Duration::from_secs(10);

/// Claim `token` for `terminal_id`; false when the token is already active.
pub(crate) fn register(token: &str, terminal_id: &str) -> bool {
    with_ops(|o| {
        if o.owners.contains_key(token) {
            return false;
        }
        o.owners.insert(token.to_string(), terminal_id.to_string());
        true
    })
}

pub(crate) fn owner(token: &str) -> Option<String> {
    with_ops(|o| o.owners.get(token).cloned())
}

/// Latch an interrupt for an active token; false for unknown or repeated ones.
/// A turn parked under the token is taken out and returned, for the caller to
/// write the interrupt into — no resume may ever come to do it (a cancelled
/// host stops resuming). Under the same lock as park(), so an interrupt and a
/// parking never miss each other.
pub(crate) fn latch_interrupt(token: &str) -> (bool, Option<PendingTurn>) {
    with_ops(|o| {
        if token.is_empty() || !o.owners.contains_key(token) || o.interrupted.contains(token) {
            return (false, None);
        }
        o.interrupted.insert(token.to_string());
        let parked = o.parked.remove(token);
        if let Some(p) = &parked {
            o.borrowed.insert(token.to_string(), (p.chat_id.clone(), p.started));
        }
        (true, parked)
    })
}

pub(crate) fn interrupt_latched(token: &str) -> bool {
    with_ops(|o| o.interrupted.contains(token))
}

/// Forget `token` (its turn was read, failed, or was let go).
pub(crate) fn finish(token: &str) {
    with_ops(|o| {
        o.owners.remove(token);
        o.interrupted.remove(token);
        o.parked.remove(token);
        o.borrowed.remove(token);
    });
}

/// Take the parked turn for `token` out of the store, if `chat_id` owns it.
pub(crate) fn take(token: &str, chat_id: &str) -> Take {
    with_ops(|o| match o.parked.get(token) {
        Some(p) if p.chat_id == chat_id => Take::Turn(o.parked.remove(token).expect("present")),
        Some(_) => Take::Gone,
        None => match o.borrowed.get(token) {
            Some((chat, started)) if chat == chat_id => Take::Busy(*started),
            _ => Take::Gone,
        },
    })
}

/// Holds a generate call's token; forgets it when the call ends, unless the
/// call parked its turn under it (keep).
pub(crate) struct OperationGuard(Option<String>);

impl OperationGuard {
    pub(crate) fn new(token: Option<&str>) -> Self {
        OperationGuard(token.map(str::to_string))
    }

    /// Keep the token alive for the resume calls to come.
    pub(crate) fn keep(mut self) {
        self.0 = None;
    }
}

impl Drop for OperationGuard {
    fn drop(&mut self) {
        if let Some(token) = self.0.as_deref() {
            finish(token);
        }
    }
}

/// Park `pending` under `token`, renewing its lease. When an interrupt is
/// latched that this turn has not written yet, it is NOT parked: it comes
/// back for the caller to interrupt and then park_interrupted().
#[must_use]
pub(crate) fn park(token: &str, mut pending: PendingTurn) -> Option<PendingTurn> {
    pending.parked_at = Instant::now();
    let unwritten = with_ops(|o| {
        if o.interrupted.contains(token) && !pending.turn.interrupt_written() {
            o.borrowed.insert(token.to_string(), (pending.chat_id.clone(), pending.started));
            return Some(pending);
        }
        o.parked.insert(token.to_string(), pending);
        None
    });
    start_sweeper();
    unwritten
}

/// Park a turn an interrupt was written into (or tried), on a short lease.
pub(crate) fn park_interrupted(token: &str, mut pending: PendingTurn) {
    pending.parked_at = Instant::now();
    pending.interrupted = true;
    with_ops(|o| {
        o.borrowed.remove(token);
        o.parked.insert(token.to_string(), pending);
    });
    start_sweeper();
}

fn start_sweeper() {
    SWEEPER.call_once(|| {
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_millis(250));
            sweep();
        });
    });
}

/// Retry the Stop of every parked turn it has not reached yet: the host held
/// the ESC for an in-flight transaction, and no resume may come to retry it.
fn retry_interrupts() {
    let Some(router) = ROUTER.get() else { return };
    let waiting: Vec<(String, PendingTurn)> = with_ops(|o| {
        let tokens: Vec<String> = o.parked.iter()
            .filter(|(_, p)| p.interrupted && !p.turn.interrupt_written())
            .map(|(token, _)| token.clone())
            .collect();
        tokens.into_iter()
            .filter_map(|t| o.parked.remove(&t).map(|p| (t, p)))
            .inspect(|(t, p)| { o.borrowed.insert(t.clone(), (p.chat_id.clone(), p.started)); })
            .collect()
    });
    for (token, mut pending) in waiting {
        if !pending.turn.watch_changed() {
            pending.turn.interrupt(router);
        }
        // Back under its token with its lease unchanged; if the lease runs
        // out first, sweep() lets the turn go.
        with_ops(|o| {
            o.borrowed.remove(&token);
            o.parked.insert(token, pending);
        });
    }
}

/// Let go of every parked turn whose lease lapsed or whose watch changed.
fn sweep() {
    retry_interrupts();
    let now = Instant::now();
    let lease = |p: &PendingTurn| if p.interrupted {
        resume_lease().min(INTERRUPTED_LEASE)
    } else {
        resume_lease()
    };
    let expired: Vec<(String, PendingTurn)> = with_ops(|o| {
        let stale: Vec<String> = o.parked.iter()
            .filter(|(_, p)| now.duration_since(p.parked_at) >= lease(p) || p.turn.watch_changed())
            .map(|(token, _)| token.clone())
            .collect();
        stale.into_iter()
            .filter_map(|token| {
                let pending = o.parked.remove(&token)?;
                o.owners.remove(&token);
                o.interrupted.remove(&token);
                Some((token, pending))
            })
            .collect()
    });
    // Outside the lock: handing over touches the send gate and the watcher.
    for (token, pending) in expired {
        if pending.interrupted && !pending.turn.interrupt_written() {
            log::error!("passthrough: the Stop for {token} on {} never reached the terminal",
                        pending.turn.terminal_id());
        }
        log::warn!("passthrough: letting go of parked turn {token} on {} (no resume, or its watch changed)",
                   pending.turn.terminal_id());
        pending.turn.hand_over();
    }
}
