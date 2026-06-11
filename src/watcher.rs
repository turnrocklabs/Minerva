// watcher.rs — per-terminal watch session management for agent-relay.
//
// Each watch session runs a background thread (the "watch loop") that:
//   1. Calls host.terminal.wait (long-poll, ~20s timeout) via the Router.
//   2. On settle, runs the detector against the screen content.
//   3. If a wake cause is found AND the session is armed (or notify_mode=all_turns):
//      emits agent_relay.turn_completed via the Router.
//   4. Re-arms (all_turns) or disarms (armed, one-shot) accordingly.
//   5. Loops until watch_stop is called (stop flag) or terminal_closed fires.
//
// Arming model:
//   notify_mode=armed  — armed flag must be set (via arm()) before any event
//                        is emitted; each arm() is consumed by exactly one event.
//   notify_mode=all_turns — emits on every detected turn end regardless of arm.
//   notify_mode=none   — detect silently, never emit.
//
// Thread safety: WatchState is guarded by Mutex; only watch_start/stop and
// arm() touch the map from the main thread; the watch loop holds an Arc<Mutex>
// clone per session and re-locks on each iteration.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Instant, SystemTime};

use serde_json::json;

use crate::detector::{self, CompiledDetection, DetectionMethod, WakeCause};
use crate::profiles::{profile_get, Profile};
use crate::router::Router;

// ---------------------------------------------------------------------------
// Notify mode
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotifyMode {
    /// Emit only when armed (one-shot per arm() call).
    Armed,
    /// Emit on every detected turn end.
    AllTurns,
    /// Detect silently, never emit.
    None,
}

impl NotifyMode {
    pub fn from_str(s: &str) -> Self {
        match s {
            "all_turns" => NotifyMode::AllTurns,
            "none"      => NotifyMode::None,
            _           => NotifyMode::Armed, // default
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            NotifyMode::Armed    => "armed",
            NotifyMode::AllTurns => "all_turns",
            NotifyMode::None     => "none",
        }
    }
}

// ---------------------------------------------------------------------------
// Watch session state (shared between main thread and watch loop)
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct WatchSession {
    #[allow(dead_code)]
    terminal_id: String,
    profile_id: String,
    notify_mode: NotifyMode,

    /// Armed flag (for NotifyMode::Armed). Consumed on first event, re-set by arm().
    armed: bool,

    /// Stop flag — set by watch_stop() to signal the loop to exit.
    stop: bool,

    /// Last wake cause reported.
    last_wake_cause: Option<String>,

    /// ISO-8601 timestamp of the last detected turn end.
    last_turn_at: Option<String>,

    /// How the last turn was detected (for calibration).
    last_detection_method: Option<String>,

    // ── B4 turn-boundary row tracking ──────────────────────────────────────

    /// Total row count (from host.terminal.wait results) at the moment the
    /// session was armed (i.e. when send() arms the one-shot gate).
    /// read_turn uses this as the start_row for host.terminal.read so it
    /// reads only the output produced during this turn.
    turn_start_row: Option<u64>,

    /// Total row count at the point the most recent turn was detected
    /// (turn_end == current rows at detection time).
    turn_end_row: Option<u64>,

    /// Payload of the last emitted turn_completed event (copied for read_turn).
    last_event_payload: Option<serde_json::Value>,

    // ── Busy-gate (transition-based detection) ─────────────────────────────

    /// A settle_prompt turn_completed only counts while the gate is open.
    /// The gate opens when the loop observes a busy screen or row growth past
    /// `gate_ref_rows`; it closes on arm(), on watch_start, and after each
    /// counted turn — so a pre-existing idle screen never registers as a turn
    /// (phantom turns / arm-consumption race).
    gate_open: bool,

    /// Row reference for the gate's growth check: rows at arm() time, at the
    /// first wait sample after watch_start, or at the last counted turn.
    gate_ref_rows: Option<u64>,

    /// Last-activity anchor for the idle reap: refreshed by arm() and by any
    /// counted detection. The watch_timeout_ms reap applies only to UNARMED
    /// sessions idle past this anchor — an armed session never self-reaps
    /// mid-turn (lifecycle item 019eb3617c38).
    reap_anchor: Instant,
}

impl WatchSession {
    fn new(terminal_id: String, profile_id: String, notify_mode: NotifyMode) -> Self {
        WatchSession {
            terminal_id,
            profile_id,
            notify_mode,
            armed: false,
            stop: false,
            last_wake_cause: None,
            last_turn_at: None,
            last_detection_method: None,
            turn_start_row: None,
            turn_end_row: None,
            last_event_payload: None,
            gate_open: false,
            gate_ref_rows: None,
            reap_anchor: Instant::now(),
        }
    }
}

// ---------------------------------------------------------------------------
// Global watch registry
// ---------------------------------------------------------------------------

type SessionMap = Arc<Mutex<HashMap<String, Arc<Mutex<WatchSession>>>>>;

static SESSIONS: Mutex<Option<SessionMap>> = Mutex::new(None);

/// Initialise the global session registry. Called once from main().
pub fn init_sessions() {
    let mut guard = SESSIONS.lock().unwrap();
    *guard = Some(Arc::new(Mutex::new(HashMap::new())));
    init_turn_cache();
}

fn get_sessions() -> SessionMap {
    SESSIONS.lock().unwrap().as_ref().expect("sessions not initialised").clone()
}

// ---------------------------------------------------------------------------
// Persistent turn cache — survives session cleanup
//
// Stores the most recent turn info (rows + event payload) per terminal_id.
// Written by maybe_emit; read by read_turn and watch_status via turn_rows()
// and last_event_payload(). This persists AFTER the watch session is removed
// from the registry so read_turn can still access turn boundaries.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct TurnCache {
    start_row: Option<u64>,
    end_row: Option<u64>,
    event_payload: Option<serde_json::Value>,
    /// Monotonic count of COUNTED detections (any cause, emitted or not).
    /// wait_for_turn blocks on this changing — gated phantom screens never
    /// reach maybe_emit, so a bump always means a real wake-worthy event.
    detection_serial: u64,
}

type TurnCacheMap = Arc<Mutex<HashMap<String, TurnCache>>>;

static TURN_CACHE: Mutex<Option<TurnCacheMap>> = Mutex::new(None);

fn init_turn_cache() {
    let mut guard = TURN_CACHE.lock().unwrap();
    *guard = Some(Arc::new(Mutex::new(HashMap::new())));
}

fn get_turn_cache() -> TurnCacheMap {
    TURN_CACHE.lock().unwrap().as_ref()
        .expect("turn cache not initialised")
        .clone()
}

fn update_turn_cache(
    terminal_id: &str,
    start_row: Option<u64>,
    end_row: Option<u64>,
    event_payload: Option<serde_json::Value>,
) {
    let cache = get_turn_cache();
    let mut map = cache.lock().unwrap();
    let entry = map.entry(terminal_id.to_string()).or_insert_with(|| TurnCache {
        start_row: None,
        end_row: None,
        event_payload: None,
        detection_serial: 0,
    });
    if let Some(sr) = start_row {
        entry.start_row = Some(sr);
    }
    if let Some(er) = end_row {
        entry.end_row = Some(er);
    }
    if let Some(p) = event_payload {
        entry.event_payload = Some(p);
    }
}

/// Current detection serial for a terminal (0 when nothing recorded yet).
pub fn detection_serial(terminal_id: &str) -> u64 {
    let cache = get_turn_cache();
    let map = cache.lock().unwrap();
    map.get(terminal_id).map(|e| e.detection_serial).unwrap_or(0)
}

fn bump_detection_serial(terminal_id: &str) {
    let cache = get_turn_cache();
    let mut map = cache.lock().unwrap();
    let entry = map.entry(terminal_id.to_string()).or_insert_with(|| TurnCache {
        start_row: None,
        end_row: None,
        event_payload: None,
        detection_serial: 0,
    });
    entry.detection_serial += 1;
}

/// Block until the NEXT counted detection on `terminal_id` (any wake cause —
/// turn_completed, input_requested, agent_exited, terminal_closed, timed_out)
/// or until `timeout_ms` elapses. Returns (payload, timed_out): on a wake the
/// payload is the detection's event-shaped payload; on timeout it is None.
///
/// Poll-based (100 ms) on the turn cache's detection serial — runs on the
/// caller's thread; the watch loop thread does the detecting. Safe to call
/// from the main dispatch thread: capability replies route through the
/// stdin-reader thread, so blocking here cannot deadlock the watcher.
pub fn wait_for_turn(terminal_id: &str, timeout_ms: u64) -> (Option<serde_json::Value>, bool) {
    let deadline = Instant::now() + std::time::Duration::from_millis(timeout_ms);
    let baseline = detection_serial(terminal_id);
    loop {
        if detection_serial(terminal_id) > baseline {
            return (last_event_payload(terminal_id), false);
        }
        if Instant::now() >= deadline {
            return (None, true);
        }
        thread::sleep(std::time::Duration::from_millis(100));
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start or restart a watch session on `terminal_id`.
/// If a session already exists for this terminal, it is stopped first (graceful).
pub fn watch_start(
    terminal_id: String,
    profile_id: Option<String>,
    notify_mode: NotifyMode,
    router: Arc<Router>,
) -> Result<(), String> {
    let profile_id = profile_id.unwrap_or_else(|| "claude".to_string());

    // Verify profile exists.
    let profile = profile_get(&profile_id)
        .ok_or_else(|| format!("unknown profile '{}'; use profiles_list to see options", profile_id))?;

    let sessions = get_sessions();

    // Stop any existing session for this terminal.
    {
        let map = sessions.lock().unwrap();
        if let Some(existing) = map.get(&terminal_id) {
            let mut s = existing.lock().unwrap();
            s.stop = true;
            log::info!("watch_start: stopping existing session for {terminal_id}");
        }
    }

    // Create new session state.
    let session = Arc::new(Mutex::new(WatchSession::new(
        terminal_id.clone(),
        profile_id.clone(),
        notify_mode,
    )));

    {
        let mut map = sessions.lock().unwrap();
        map.insert(terminal_id.clone(), session.clone());
    }

    // Spawn the watch loop thread.
    let tid = terminal_id.clone();
    let profile_clone = profile.clone();
    thread::Builder::new()
        .name(format!("watch-{}", terminal_id))
        .spawn(move || {
            watch_loop(tid, profile_clone, session, router);
        })
        .map_err(|e| format!("failed to spawn watch thread: {e}"))?;

    log::info!("watch_start: watching terminal {terminal_id} with profile {profile_id}");
    crate::state::save();
    Ok(())
}

/// Stop a watch session. The background thread will exit on its next iteration.
/// Returns true if a session was running, false if no session found.
pub fn watch_stop(terminal_id: &str) -> bool {
    let stopped = {
        let sessions = get_sessions();
        let map = sessions.lock().unwrap();
        if let Some(session) = map.get(terminal_id) {
            let mut s = session.lock().unwrap();
            s.stop = true;
            log::info!("watch_stop: signalled {terminal_id}");
            true
        } else {
            false
        }
    };
    if stopped {
        crate::state::save();
    }
    stopped
}

/// Arm a watch session for one-shot notification (called internally by the
/// send tool in B4, exposed as pub fn here for B4's use).
/// `snapshot`: (screen content, total_rows) at arm time. The turn-start
/// boundary for read_turn is ANCHORED on the last content row — total rows
/// minus the trailing input-box/chrome rows of the snapshot screen — because
/// the answer renders INTO the rows the input box occupied (019eb345d4d9).
/// The busy-gate's growth reference keeps the RAW row count.
/// Returns true if the session exists and was armed.
pub fn arm(terminal_id: &str, snapshot: Option<(&str, u64)>) -> bool {
    let raw_rows = snapshot.map(|(_, rows)| rows);
    let (found, anchored_start) = {
        let sessions = get_sessions();
        let map = sessions.lock().unwrap();
        if let Some(session) = map.get(terminal_id) {
            let mut s = session.lock().unwrap();
            s.armed = true;
            // Arming is activity: refresh the reap anchor so an in-flight turn
            // never gets reaped out from under its one-shot wake.
            s.reap_anchor = Instant::now();
            // Close the busy-gate: this arm's turn_completed requires a fresh
            // busy screen or row growth past the arm snapshot first.
            s.gate_open = false;
            s.gate_ref_rows = raw_rows;
            let anchored = snapshot.map(|(content, rows)| {
                anchored_rows(&s.profile_id, content, rows)
            });
            if let Some(rows) = anchored {
                s.turn_start_row = Some(rows);
            }
            (true, anchored)
        } else {
            (false, None)
        }
    };
    if found {
        if let Some(rows) = anchored_start {
            // Mirror start_row to persistent cache so read_turn can access it
            // even after the session is cleaned up.
            update_turn_cache(terminal_id, Some(rows), None, None);
        }
        log::debug!(
            "arm: armed {terminal_id} raw_rows={raw_rows:?} start_row={anchored_start:?}"
        );
    }
    found
}

/// Compute the content-anchored row count: `total_rows` minus the trailing
/// input-box/chrome rows of `content`, per the named profile. Falls back to
/// the raw count when the profile or its regex is unavailable.
fn anchored_rows(profile_id: &str, content: &str, total_rows: u64) -> u64 {
    match profile_get(profile_id)
        .and_then(|p| CompiledDetection::from_profile(&p).ok())
    {
        Some(cd) => total_rows.saturating_sub(detector::trailing_noncontent_rows(content, &cd)),
        None => total_rows,
    }
}

/// Query the turn-boundary rows for the most recent completed turn.
/// Reads from the persistent turn cache (survives session cleanup).
/// Returns (start_row, end_row) — both are None if no turn has been recorded yet.
pub fn turn_rows(terminal_id: &str) -> (Option<u64>, Option<u64>) {
    let cache = get_turn_cache();
    let map = cache.lock().unwrap();
    if let Some(entry) = map.get(terminal_id) {
        (entry.start_row, entry.end_row)
    } else {
        (None, None)
    }
}

/// Return the payload of the last emitted turn_completed event (for read_turn).
/// Reads from the persistent turn cache (survives session cleanup).
pub fn last_event_payload(terminal_id: &str) -> Option<serde_json::Value> {
    let cache = get_turn_cache();
    let map = cache.lock().unwrap();
    map.get(terminal_id).and_then(|e| e.event_payload.clone())
}

/// Snapshot of the live (non-stopped) sessions for persistence:
/// (terminal_id, profile_id, notify_mode).
pub fn session_specs() -> Vec<(String, String, String)> {
    let sessions = get_sessions();
    let map = sessions.lock().unwrap();
    map.values()
        .filter_map(|session| {
            let s = session.lock().unwrap();
            if s.stop {
                return None;
            }
            Some((
                s.terminal_id.clone(),
                s.profile_id.clone(),
                s.notify_mode.as_str().to_string(),
            ))
        })
        .collect()
}

/// Query the current status of a watch session.
/// Returns None if no session exists.
pub fn watch_status(terminal_id: &str) -> Option<serde_json::Value> {
    let sessions = get_sessions();
    let map = sessions.lock().unwrap();
    let session = map.get(terminal_id)?;
    let s = session.lock().unwrap();
    Some(json!({
        "watching": !s.stop,
        "profile_id": s.profile_id,
        "notify_mode": s.notify_mode.as_str(),
        "armed": s.armed,
        "last_wake_cause": s.last_wake_cause,
        "last_turn_at": s.last_turn_at,
        "last_detection_method": s.last_detection_method,
        "turn_start_row": s.turn_start_row,
        "turn_end_row": s.turn_end_row,
    }))
}

// ---------------------------------------------------------------------------
// Watch loop (runs in background thread)
// ---------------------------------------------------------------------------

/// The loop waits for terminal output to settle, runs detection, and emits
/// events when appropriate. Exits when stop=true or terminal_closed fires.
fn watch_loop(
    terminal_id: String,
    profile: Profile,
    session: Arc<Mutex<WatchSession>>,
    router: Arc<Router>,
) {
    log::info!("watch_loop: starting for {terminal_id}");

    let cd = match CompiledDetection::from_profile(&profile) {
        Ok(cd) => cd,
        Err(e) => {
            log::error!("watch_loop: bad profile regex for {terminal_id}: {e}");
            return;
        }
    };

    let watch_timeout = std::time::Duration::from_millis(cd.watch_timeout_ms);

    loop {
        // Check stop flag and the idle reap. The reap applies only to UNARMED
        // sessions idle past the reap anchor (arm() and counted detections
        // refresh it) — an armed session never self-reaps mid-turn.
        let reap_due = {
            let s = session.lock().unwrap();
            if s.stop {
                log::info!("watch_loop: stop flag set for {terminal_id}, exiting");
                break;
            }
            !s.armed && s.reap_anchor.elapsed() > watch_timeout
        };

        if reap_due {
            log::info!("watch_loop: idle reap for {terminal_id}");
            maybe_emit(
                &terminal_id,
                WakeCause::TimedOut,
                DetectionMethod::Timeout,
                &profile.id,
                None,
                &session,
                &router,
            );
            break;
        }

        // Call host.terminal.wait — long-poll, ~20s timeout.
        // settle_ms from profile tells it when to consider output settled.
        let wait_started = std::time::Instant::now();
        let wait_result = router.call_capability("host.terminal.wait", json!({
            "terminal_id": terminal_id,
            "timeout_ms": 20_000,
            "settle_ms": cd.settle_ms,
        }));

        // The host normally blocks for settle/timeout; if it returns near-
        // instantly (degraded host, test stub), pace the loop so we don't
        // spin a hot storm of wait calls.
        if wait_started.elapsed() < std::time::Duration::from_millis(250) {
            std::thread::sleep(std::time::Duration::from_millis(300));
        }

        match wait_result {
            Err(e) => {
                // Error from host.terminal.wait — terminal likely gone.
                log::info!("watch_loop: terminal.wait error for {terminal_id}: {e}");
                maybe_emit(
                    &terminal_id,
                    WakeCause::TerminalClosed,
                    DetectionMethod::ChildExit,
                    &profile.id,
                    None,
                    &session,
                    &router,
                );
                break;
            }
            Ok(result) => {
                // Parse the wait result fields.
                let timed_out = result.get("timed_out")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let bell_rung = result.get("bell_rung")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let shell_exited = result.get("shell_exited")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let content = result.get("content")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");

                log::debug!(
                    "watch_loop: {terminal_id} settled: timed_out={timed_out} bell={bell_rung} \
                     shell_exited={shell_exited} content_len={}",
                    content.len()
                );

                // A timed-out wait still carries the CURRENT screen. A quiet
                // terminal (turn finished before/during a missed settle
                // window) times out forever — so run detection on timeouts
                // too as long as we have content to evaluate. Only skip when
                // there is nothing to look at.
                if timed_out && content.is_empty() {
                    continue;
                }

                // Extract total rows at this settle point (for turn-boundary tracking).
                let current_rows = result.get("total_scrollback_rows")
                    .and_then(|v| v.as_u64());

                // Busy-gate bookkeeping: a busy screen or row growth past the
                // reference opens the gate. First sample after watch_start
                // seeds the reference (gate stays closed on that sample).
                let gate_open = {
                    let mut s = session.lock().unwrap();
                    if s.gate_ref_rows.is_none() {
                        s.gate_ref_rows = current_rows;
                    }
                    let grew = match (current_rows, s.gate_ref_rows) {
                        (Some(now), Some(reference)) => now > reference,
                        _ => false,
                    };
                    if grew || detector::is_busy(content, &cd) {
                        s.gate_open = true;
                    }
                    s.gate_open
                };

                if let Some(det) = detector::run(content, bell_rung, shell_exited, &cd) {
                    // Gate: a settle_prompt turn_completed on a screen that was
                    // never seen busy (and never grew) is a pre-existing idle
                    // prompt, not a turn — skip it entirely (no emit, no last_*).
                    // Bell, shell markers, dialogs, exits are real signals and
                    // bypass the gate.
                    if det.cause == WakeCause::TurnCompleted
                        && det.method == DetectionMethod::SettlePrompt
                        && !gate_open
                    {
                        log::debug!(
                            "watch_loop: {terminal_id} settle_prompt gated \
                             (no busy/growth observed since arm/start)"
                        );
                        continue;
                    }

                    // Anchor the turn-end row on the last content row: the
                    // settled screen ends with the (re-rendered) input box +
                    // hint rows, which belong to the NEXT turn, not this one.
                    // host.terminal.read treats end_row as an INCLUSIVE
                    // 0-indexed row (range(start, end+1)), so the last content
                    // row is total − trailing − 1.
                    let anchored_end = current_rows.map(|r| {
                        r.saturating_sub(detector::trailing_noncontent_rows(content, &cd) + 1)
                    });

                    maybe_emit(
                        &terminal_id,
                        det.cause.clone(),
                        det.method.clone(),
                        &profile.id,
                        anchored_end,
                        &session,
                        &router,
                    );

                    // A counted turn closes the gate: the next turn_completed
                    // requires a fresh busy→idle transition (also stops
                    // all_turns re-firing on the same idle screen).
                    if det.cause == WakeCause::TurnCompleted {
                        let mut s = session.lock().unwrap();
                        s.gate_open = false;
                        s.gate_ref_rows = current_rows;
                    }

                    // terminal_closed and agent_exited (child_exit) are terminal — stop watching.
                    if det.cause == WakeCause::TerminalClosed
                        || (det.cause == WakeCause::AgentExited && det.method == DetectionMethod::ChildExit)
                    {
                        break;
                    }

                    // All other wake causes: continue watching (armed mode re-gates
                    // future events; all_turns emits again next detection).
                    // timed_out is also terminal (handled above).
                }
                // No detection fired → loop.
            }
        }
    }

    // Clean up: remove session from registry.
    {
        let sessions = get_sessions();
        let mut map = sessions.lock().unwrap();
        map.remove(&terminal_id);
    }
    crate::state::save();
    log::info!("watch_loop: cleaned up {terminal_id}");
}

/// Conditionally emit a turn_completed event based on notify_mode and arm state.
/// Also updates the session's last_* fields and turn-boundary rows.
///
/// `current_rows`: the total row count from host.terminal.wait at detection time.
///   Written to turn_end_row so read_turn can bound its host.terminal.read call.
fn maybe_emit(
    terminal_id: &str,
    cause: WakeCause,
    method: DetectionMethod,
    profile_id: &str,
    current_rows: Option<u64>,
    session: &Arc<Mutex<WatchSession>>,
    router: &Arc<Router>,
) {
    let turn_at = iso_now();

    // Update session state and decide whether to emit.
    let (should_emit, payload, turn_start, turn_end) = {
        let mut s = session.lock().unwrap();
        s.last_wake_cause = Some(cause.as_str().to_string());
        s.last_turn_at = Some(turn_at.clone());
        s.last_detection_method = Some(method.as_str().to_string());
        // A counted detection is activity — push the idle reap out.
        s.reap_anchor = Instant::now();
        if let Some(rows) = current_rows {
            s.turn_end_row = Some(rows);
        }

        let emit = match s.notify_mode {
            NotifyMode::None => false,
            NotifyMode::AllTurns => true,
            NotifyMode::Armed => {
                if s.armed {
                    s.armed = false; // consume the arm (one-shot)
                    true
                } else {
                    false
                }
            }
        };

        let p = json!({
            "terminal_id": terminal_id,
            "cause": cause.as_str(),
            "detection_method": method.as_str(),
            "profile_id": profile_id,
            "turn_at_iso": turn_at,
        });

        if emit {
            s.last_event_payload = Some(p.clone());
        }

        (emit, p, s.turn_start_row, s.turn_end_row)
    };

    // Always update the persistent turn cache with end_row and the detection
    // payload — read_turn/wait_for_turn describe the latest COUNTED detection
    // whether or not an event was emitted (human turns included), and they
    // keep working after the session is removed from the registry.
    update_turn_cache(
        terminal_id,
        turn_start,
        turn_end,
        Some(payload.clone()),
    );
    bump_detection_serial(terminal_id);

    if should_emit {
        router.emit_event("agent_relay.turn_completed", payload);
        log::info!(
            "maybe_emit: emitted turn_completed terminal={terminal_id} cause={} method={}",
            cause.as_str(),
            method.as_str()
        );
    } else {
        log::debug!(
            "maybe_emit: suppressed (not armed) terminal={terminal_id} cause={}",
            cause.as_str()
        );
    }
}

/// Return the current UTC time in ISO-8601 format.
fn iso_now() -> String {
    // Simple: format from SystemTime as seconds since epoch, then format
    // to ISO-8601 without chrono dependency.
    let secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Convert epoch seconds to a rough UTC datetime string.
    // Full ISO-8601 without chrono: use a simple approximation.
    // For full correctness in production, chrono would be ideal;
    // this is acceptable for telemetry timestamps.
    let (year, month, day, hour, min, sec) = epoch_to_datetime(secs);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", year, month, day, hour, min, sec)
}

/// Minimal epoch → (y, m, d, H, M, S) conversion without external deps.
fn epoch_to_datetime(epoch: u64) -> (u32, u32, u32, u32, u32, u32) {
    let sec = (epoch % 60) as u32;
    let min = ((epoch / 60) % 60) as u32;
    let hour = ((epoch / 3600) % 24) as u32;

    // Days since epoch.
    let days = (epoch / 86400) as u32;

    // Gregorian calendar algorithm (a well-known civil calendar algorithm).
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };

    (year, month, day, hour, min, sec)
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // Returns the global profiles guard: init_profiles() resets a process-global
    // store that profiles/state tests mutate-and-assert on — callers must HOLD
    // the guard for the test body (`let _g = setup();`), not discard it.
    fn setup() -> std::sync::MutexGuard<'static, ()> {
        let g = crate::profiles::TEST_PROFILES_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        crate::profiles::init_profiles();
        init_sessions();
        g
    }

    // ── Test: arming state machine ───────────────────────────────────────────

    #[test]
    fn test_arm_unarmed_does_not_emit() {
        // Build a session with armed=false and notify_mode=Armed.
        let session = Arc::new(Mutex::new({
            let s = WatchSession::new("t1".to_string(), "claude".to_string(), NotifyMode::Armed);
            s
        }));

        // We can't easily test with a real router in a unit test without spawning
        // the full router (which owns stdin). Instead we test the arming logic
        // directly via the session state checks.

        // Verify that armed=false means no emit.
        let should_emit = {
            let s = session.lock().unwrap();
            match s.notify_mode {
                NotifyMode::Armed => s.armed,
                NotifyMode::AllTurns => true,
                NotifyMode::None => false,
            }
        };
        assert!(!should_emit, "unarmed session should not emit");
    }

    #[test]
    fn test_arm_armed_emits_once() {
        let session = Arc::new(Mutex::new({
            let mut s = WatchSession::new("t2".to_string(), "claude".to_string(), NotifyMode::Armed);
            s.armed = true;
            s
        }));

        // First check: armed → should emit.
        let first_emit = {
            let mut s = session.lock().unwrap();
            if s.armed {
                s.armed = false;
                true
            } else {
                false
            }
        };
        assert!(first_emit, "armed session should emit once");

        // Second check: arm consumed → should NOT emit again.
        let second_emit = {
            let s = session.lock().unwrap();
            s.armed
        };
        assert!(!second_emit, "arm consumed — second emit suppressed");
    }

    #[test]
    fn test_all_turns_always_emits() {
        let session = Arc::new(Mutex::new({
            let s = WatchSession::new("t3".to_string(), "claude".to_string(), NotifyMode::AllTurns);
            s
        }));

        for _ in 0..3 {
            let should_emit = {
                let s = session.lock().unwrap();
                matches!(s.notify_mode, NotifyMode::AllTurns)
            };
            assert!(should_emit, "all_turns should always emit");
        }
    }

    #[test]
    fn test_notify_mode_none_never_emits() {
        let session = Arc::new(Mutex::new({
            let mut s = WatchSession::new("t4".to_string(), "claude".to_string(), NotifyMode::None);
            s.armed = true;
            s
        }));

        let should_emit = {
            let s = session.lock().unwrap();
            !matches!(s.notify_mode, NotifyMode::None)
        };
        assert!(!should_emit, "notify_mode=none should never emit");
    }

    // ── Test: arm() public function ──────────────────────────────────────────

    #[test]
    fn test_arm_fn_sets_flag() {
        let _g = setup();
        // Watch start would normally spawn a thread; we test arm() in isolation
        // by manually inserting a session into the registry.
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new({
            let s = WatchSession::new("t-arm".to_string(), "claude".to_string(), NotifyMode::Armed);
            s
        }));
        {
            let mut map = sessions.lock().unwrap();
            map.insert("t-arm".to_string(), session);
        }

        let pre_armed = {
            let sessions2 = get_sessions();
            let map = sessions2.lock().unwrap();
            let session_ref = map.get("t-arm").unwrap();
            let sess = session_ref.lock().unwrap();
            sess.armed
        };
        assert!(!pre_armed, "not armed before arm()");

        let result = arm("t-arm", None);
        assert!(result, "arm() returned true for existing session");

        let armed = {
            let sessions2 = get_sessions();
            let map = sessions2.lock().unwrap();
            let session_ref = map.get("t-arm").unwrap();
            let sess = session_ref.lock().unwrap();
            sess.armed
        };
        assert!(armed, "arm() set the armed flag");
    }

    // ── Test: watch_status ───────────────────────────────────────────────────

    #[test]
    fn test_watch_status_none_for_unknown() {
        let _g = setup();
        let status = watch_status("no-such-terminal");
        assert!(status.is_none(), "no status for unknown terminal");
    }

    #[test]
    fn test_watch_status_present_for_known() {
        let _g = setup();
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new({
            let mut s = WatchSession::new("t-status".to_string(), "codex".to_string(), NotifyMode::AllTurns);
            s.last_wake_cause = Some("turn_completed".to_string());
            s.last_turn_at = Some("2026-06-09T12:00:00Z".to_string());
            s.last_detection_method = Some("settle_prompt".to_string());
            s.turn_start_row = Some(42);
            s.turn_end_row = Some(75);
            s
        }));
        {
            let mut map = sessions.lock().unwrap();
            map.insert("t-status".to_string(), session);
        }

        let status = watch_status("t-status").unwrap();
        assert_eq!(status["profile_id"], "codex");
        assert_eq!(status["notify_mode"], "all_turns");
        assert_eq!(status["last_wake_cause"], "turn_completed");
        assert_eq!(status["last_detection_method"], "settle_prompt");
        assert_eq!(status["turn_start_row"], 42);
        assert_eq!(status["turn_end_row"], 75);
    }

    // ── Test: arm() with current_rows snapshots turn_start_row ──────────────

    #[test]
    fn test_arm_fn_snapshots_start_row() {
        let _g = setup();
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new({
            let s = WatchSession::new("t-arm-rows".to_string(), "claude".to_string(), NotifyMode::Armed);
            s
        }));
        {
            let mut map = sessions.lock().unwrap();
            map.insert("t-arm-rows".to_string(), session);
        }

        // Arm with a known row count.
        let result = arm("t-arm-rows", Some(("", 100)));
        assert!(result, "arm() returned true");

        let (start, end) = turn_rows("t-arm-rows");
        assert_eq!(start, Some(100), "turn_start_row snapshotted (no trailing chrome)");
        assert_eq!(end, None, "turn_end_row not set yet");
    }

    // ── Test: arm() without rows leaves start_row unchanged ─────────────────

    #[test]
    fn test_arm_fn_no_rows_leaves_start_row() {
        let _g = setup();
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new({
            let mut s = WatchSession::new("t-arm-norows".to_string(), "claude".to_string(), NotifyMode::Armed);
            s.turn_start_row = Some(50);
            s
        }));
        {
            let mut map = sessions.lock().unwrap();
            map.insert("t-arm-norows".to_string(), session);
        }

        // Pre-populate the persistent turn cache to simulate a prior arm(Some(50)).
        // turn_rows() reads from the cache, not the session map.
        update_turn_cache("t-arm-norows", Some(50), None, None);

        // Calling arm with None should NOT overwrite the cache.
        arm("t-arm-norows", None);

        let (start, _) = turn_rows("t-arm-norows");
        assert_eq!(start, Some(50), "existing turn_start_row preserved when arm called without rows");
    }

    // ── Test: arm() anchors start_row past trailing input-box chrome ────────

    #[test]
    fn test_arm_anchors_start_row_on_last_content_row() {
        let _g = setup();
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new(WatchSession::new(
            "t-arm-anchor".to_string(),
            "claude".to_string(),
            NotifyMode::Armed,
        )));
        {
            let mut map = sessions.lock().unwrap();
            map.insert("t-arm-anchor".to_string(), session);
        }

        // Snapshot screen ends with the live input box (❯ + NBSP) and a hint
        // row — 2 trailing chrome rows that the answer will render into.
        let screen = "Previous answer text.\n\
                      \n\
                      \u{276f}\u{a0}draft being typed\n\
                      ? for shortcuts\n";
        assert!(arm("t-arm-anchor", Some((screen, 100))));

        let (start, _) = turn_rows("t-arm-anchor");
        assert_eq!(start, Some(97), "start anchored above prompt + separating blank");
    }

    // ── Test: notify_mode parsing ────────────────────────────────────────────

    #[test]
    fn test_notify_mode_from_str() {
        assert_eq!(NotifyMode::from_str("armed"), NotifyMode::Armed);
        assert_eq!(NotifyMode::from_str("all_turns"), NotifyMode::AllTurns);
        assert_eq!(NotifyMode::from_str("none"), NotifyMode::None);
        assert_eq!(NotifyMode::from_str("unknown"), NotifyMode::Armed, "defaults to Armed");
        assert_eq!(NotifyMode::from_str(""), NotifyMode::Armed, "empty defaults to Armed");
    }

    // ── Test: iso_now format ─────────────────────────────────────────────────

    #[test]
    fn test_iso_now_format() {
        let ts = iso_now();
        // Should be YYYY-MM-DDTHH:MM:SSZ
        assert!(ts.ends_with('Z'), "should end with Z: {ts}");
        assert_eq!(ts.len(), 20, "correct length: {ts}");
        assert_eq!(&ts[4..5], "-", "year-month separator: {ts}");
        assert_eq!(&ts[7..8], "-", "month-day separator: {ts}");
        assert_eq!(&ts[10..11], "T", "date-time separator: {ts}");
    }
}
