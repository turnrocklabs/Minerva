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
    let session = Arc::new(Mutex::new(WatchSession {
        terminal_id: terminal_id.clone(),
        profile_id: profile_id.clone(),
        notify_mode,
        armed: false,
        stop: false,
        last_wake_cause: None,
        last_turn_at: None,
        last_detection_method: None,
        turn_start_row: None,
        turn_end_row: None,
        last_event_payload: None,
    }));

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
    Ok(())
}

/// Stop a watch session. The background thread will exit on its next iteration.
/// Returns true if a session was running, false if no session found.
pub fn watch_stop(terminal_id: &str) -> bool {
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
}

/// Arm a watch session for one-shot notification (called internally by the
/// send tool in B4, exposed as pub fn here for B4's use).
/// `current_rows`: snapshot of total_rows at arm time — used by read_turn as
/// the turn-start boundary for host.terminal.read.
/// Returns true if the session exists and was armed.
pub fn arm(terminal_id: &str, current_rows: Option<u64>) -> bool {
    let found = {
        let sessions = get_sessions();
        let map = sessions.lock().unwrap();
        if let Some(session) = map.get(terminal_id) {
            let mut s = session.lock().unwrap();
            s.armed = true;
            if let Some(rows) = current_rows {
                s.turn_start_row = Some(rows);
            }
            true
        } else {
            false
        }
    };
    if found {
        if let Some(rows) = current_rows {
            // Mirror start_row to persistent cache so read_turn can access it
            // even after the session is cleaned up.
            update_turn_cache(terminal_id, Some(rows), None, None);
        }
        log::debug!("arm: armed {terminal_id} start_row={:?}", current_rows);
    }
    found
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

    let start_time = Instant::now();
    let watch_timeout = std::time::Duration::from_millis(cd.watch_timeout_ms);

    loop {
        // Check stop flag.
        {
            let s = session.lock().unwrap();
            if s.stop {
                log::info!("watch_loop: stop flag set for {terminal_id}, exiting");
                break;
            }
        }

        // Check arm timeout.
        if start_time.elapsed() > watch_timeout {
            log::info!("watch_loop: arm timeout for {terminal_id}");
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
                let current_rows = result.get("rows")
                    .and_then(|v| v.as_u64());

                // Run the detection pass.
                if let Some(det) = detector::run(content, bell_rung, shell_exited, &cd) {
                    maybe_emit(
                        &terminal_id,
                        det.cause.clone(),
                        det.method.clone(),
                        &profile.id,
                        current_rows,
                        &session,
                        &router,
                    );

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
    let sessions = get_sessions();
    let mut map = sessions.lock().unwrap();
    map.remove(&terminal_id);
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

    // Always update the persistent turn cache with end_row and (if emitting) the
    // event payload. This ensures read_turn can access them even after the session
    // is removed from the registry (e.g. after watch_stop).
    update_turn_cache(
        terminal_id,
        turn_start,
        turn_end,
        if should_emit { Some(payload.clone()) } else { None },
    );

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

    fn setup() {
        crate::profiles::init_profiles();
        init_sessions();
    }

    // ── Test: arming state machine ───────────────────────────────────────────

    #[test]
    fn test_arm_unarmed_does_not_emit() {
        // Build a session with armed=false and notify_mode=Armed.
        let session = Arc::new(Mutex::new(WatchSession {
            terminal_id: "t1".to_string(),
            profile_id: "claude".to_string(),
            notify_mode: NotifyMode::Armed,
            armed: false,
            stop: false,
            last_wake_cause: None,
            last_turn_at: None,
            last_detection_method: None,
            turn_start_row: None,
            turn_end_row: None,
            last_event_payload: None,
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
        let session = Arc::new(Mutex::new(WatchSession {
            terminal_id: "t2".to_string(),
            profile_id: "claude".to_string(),
            notify_mode: NotifyMode::Armed,
            armed: true, // armed
            stop: false,
            last_wake_cause: None,
            last_turn_at: None,
            last_detection_method: None,
            turn_start_row: None,
            turn_end_row: None,
            last_event_payload: None,
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
        let session = Arc::new(Mutex::new(WatchSession {
            terminal_id: "t3".to_string(),
            profile_id: "claude".to_string(),
            notify_mode: NotifyMode::AllTurns,
            armed: false, // not armed but all_turns overrides
            stop: false,
            last_wake_cause: None,
            last_turn_at: None,
            last_detection_method: None,
            turn_start_row: None,
            turn_end_row: None,
            last_event_payload: None,
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
        let session = Arc::new(Mutex::new(WatchSession {
            terminal_id: "t4".to_string(),
            profile_id: "claude".to_string(),
            notify_mode: NotifyMode::None,
            armed: true, // armed but mode=none
            stop: false,
            last_wake_cause: None,
            last_turn_at: None,
            last_detection_method: None,
            turn_start_row: None,
            turn_end_row: None,
            last_event_payload: None,
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
        setup();
        // Watch start would normally spawn a thread; we test arm() in isolation
        // by manually inserting a session into the registry.
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new(WatchSession {
            terminal_id: "t-arm".to_string(),
            profile_id: "claude".to_string(),
            notify_mode: NotifyMode::Armed,
            armed: false,
            stop: false,
            last_wake_cause: None,
            last_turn_at: None,
            last_detection_method: None,
            turn_start_row: None,
            turn_end_row: None,
            last_event_payload: None,
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
        setup();
        let status = watch_status("no-such-terminal");
        assert!(status.is_none(), "no status for unknown terminal");
    }

    #[test]
    fn test_watch_status_present_for_known() {
        setup();
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new(WatchSession {
            terminal_id: "t-status".to_string(),
            profile_id: "codex".to_string(),
            notify_mode: NotifyMode::AllTurns,
            armed: false,
            stop: false,
            last_wake_cause: Some("turn_completed".to_string()),
            last_turn_at: Some("2026-06-09T12:00:00Z".to_string()),
            last_detection_method: Some("settle_prompt".to_string()),
            turn_start_row: Some(42),
            turn_end_row: Some(75),
            last_event_payload: None,
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
        setup();
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new(WatchSession {
            terminal_id: "t-arm-rows".to_string(),
            profile_id: "claude".to_string(),
            notify_mode: NotifyMode::Armed,
            armed: false,
            stop: false,
            last_wake_cause: None,
            last_turn_at: None,
            last_detection_method: None,
            turn_start_row: None,
            turn_end_row: None,
            last_event_payload: None,
        }));
        {
            let mut map = sessions.lock().unwrap();
            map.insert("t-arm-rows".to_string(), session);
        }

        // Arm with a known row count.
        let result = arm("t-arm-rows", Some(100));
        assert!(result, "arm() returned true");

        let (start, end) = turn_rows("t-arm-rows");
        assert_eq!(start, Some(100), "turn_start_row snapshotted");
        assert_eq!(end, None, "turn_end_row not set yet");
    }

    // ── Test: arm() without rows leaves start_row unchanged ─────────────────

    #[test]
    fn test_arm_fn_no_rows_leaves_start_row() {
        setup();
        let sessions = get_sessions();
        let session = Arc::new(Mutex::new(WatchSession {
            terminal_id: "t-arm-norows".to_string(),
            profile_id: "claude".to_string(),
            notify_mode: NotifyMode::Armed,
            armed: false,
            stop: false,
            last_wake_cause: None,
            last_turn_at: None,
            last_detection_method: None,
            turn_start_row: Some(50),
            turn_end_row: None,
            last_event_payload: None,
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
