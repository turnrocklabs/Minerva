// state.rs — single-file persistence for agent-relay runtime state.
//
// File: <exe_dir>/agent_relay_state.json (override via AGENT_RELAY_STATE_FILE;
// set it to an empty string to disable persistence entirely — used by tests).
// The executable's directory IS the plugin data directory for both side-loaded
// and marketplace installs (codetools os.Executable() precedent; the host's
// SubProcess cannot chdir, so cwd belongs to Minerva, not the plugin).
//
// Schema (flat root, version 1, defensive .get() on load — host_owned
// conventions):
// {
//   "version": 1,
//   "profiles": [Profile…],        // only profiles that DIFFER from builtins,
//                                  // so shipped seed improvements still apply
//                                  // to anything the user never touched
//   "filter_rules": [{name, pattern, action, replacement}…],
//   "sessions": [{terminal_id, profile_id, notify_mode}…]
// }
//
// Save is triggered by every mutation (profile_set, filter_set/delete,
// watch_start/stop, watch-loop cleanup). Load runs once at startup; watch
// sessions resume after the router is up. A resumed session whose terminal no
// longer exists self-heals: its first host.terminal.wait errors, the loop
// emits terminal_closed (suppressed when unarmed) and cleans itself up.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{json, Value};

use crate::filter_rules::{FilterRule, RuleAction};
use crate::profiles::{self, Profile};
use crate::router::Router;
use crate::watcher;

/// Resolve the state-file path. None disables persistence.
pub fn state_file_path() -> Option<PathBuf> {
    if let Ok(overridden) = std::env::var("AGENT_RELAY_STATE_FILE") {
        if overridden.is_empty() {
            return None;
        }
        return Some(PathBuf::from(overridden));
    }
    let exe = std::env::current_exe().ok()?;
    Some(exe.parent()?.join("agent_relay_state.json"))
}

/// Snapshot the three runtime stores and write the state file (atomic:
/// write to a .tmp sibling, then rename). Failures are logged, never fatal.
pub fn save() {
    let Some(path) = state_file_path() else { return };

    // Profiles: persist only entries that differ from the shipped seeds —
    // untouched profiles keep tracking future seed calibrations.
    let builtins: Vec<Profile> = profiles::builtin_profiles();
    let changed_profiles: Vec<Value> = profiles::profiles_list()
        .into_iter()
        .filter(|p| {
            match builtins.iter().find(|b| b.id == p.id) {
                Some(b) => {
                    serde_json::to_value(p).ok() != serde_json::to_value(b).ok()
                }
                None => true, // user-created profile
            }
        })
        .filter_map(|p| serde_json::to_value(&p).ok())
        .collect();

    let rules: Vec<Value> = crate::with_filter_rules(|rs| {
        rs.iter()
            .filter_map(|r| serde_json::to_value(r.view()).ok())
            .collect()
    });

    let sessions: Vec<Value> = watcher::session_specs()
        .into_iter()
        .map(|(terminal_id, profile_id, notify_mode)| json!({
            "terminal_id": terminal_id,
            "profile_id": profile_id,
            "notify_mode": notify_mode,
        }))
        .collect();

    let doc = json!({
        "version": 1,
        "profiles": changed_profiles,
        "filter_rules": rules,
        "sessions": sessions,
    });

    let tmp = path.with_extension("json.tmp");
    let payload = match serde_json::to_string_pretty(&doc) {
        Ok(s) => s,
        Err(e) => {
            log::warn!("state: serialise failed: {e}");
            return;
        }
    };
    if let Err(e) = std::fs::write(&tmp, payload) {
        log::warn!("state: write {} failed: {e}", tmp.display());
        return;
    }
    if let Err(e) = std::fs::rename(&tmp, &path) {
        log::warn!("state: rename to {} failed: {e}", path.display());
    }
}

/// Load the state file (if any) into the profile + filter stores.
/// Returns the persisted session specs for resume_sessions() — sessions need
/// the router, which is spawned after store init.
pub fn load() -> Vec<(String, String, String)> {
    let Some(path) = state_file_path() else { return Vec::new() };
    let raw = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(_) => return Vec::new(), // no file yet — seeds only
    };
    let doc: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("state: {} unparseable ({e}); ignoring", path.display());
            return Vec::new();
        }
    };

    let mut profile_count = 0usize;
    if let Some(items) = doc.get("profiles").and_then(|v| v.as_array()) {
        for item in items {
            match serde_json::from_value::<Profile>(item.clone()) {
                Ok(p) => {
                    profiles::profile_set(p);
                    profile_count += 1;
                }
                Err(e) => log::warn!("state: bad persisted profile skipped: {e}"),
            }
        }
    }

    let mut rule_count = 0usize;
    if let Some(items) = doc.get("filter_rules").and_then(|v| v.as_array()) {
        for item in items {
            let name = item.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let pattern = item.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
            if name.is_empty() || pattern.is_empty() {
                continue;
            }
            let action = item.get("action")
                .and_then(|v| serde_json::from_value::<RuleAction>(v.clone()).ok())
                .unwrap_or(RuleAction::DropLine);
            let replacement = item.get("replacement").and_then(|v| v.as_str()).unwrap_or("");
            match FilterRule::new(name, pattern, action, replacement) {
                Ok(rule) => {
                    crate::with_filter_rules(|rs| rs.set(rule));
                    rule_count += 1;
                }
                Err(e) => log::warn!("state: bad persisted filter rule skipped: {e}"),
            }
        }
    }

    let sessions: Vec<(String, String, String)> = doc.get("sessions")
        .and_then(|v| v.as_array())
        .map(|items| {
            items.iter()
                .filter_map(|s| {
                    let tid = s.get("terminal_id")?.as_str()?.to_string();
                    let pid = s.get("profile_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("claude")
                        .to_string();
                    let mode = s.get("notify_mode")
                        .and_then(|v| v.as_str())
                        .unwrap_or("armed")
                        .to_string();
                    Some((tid, pid, mode))
                })
                .collect()
        })
        .unwrap_or_default();

    log::info!(
        "state: loaded {} from {} — {profile_count} profile override(s), \
         {rule_count} filter rule(s), {} session(s) to resume",
        path.display(), "agent_relay_state.json", sessions.len()
    );
    sessions
}

/// Resume persisted watch sessions. Call after Router::spawn().
pub fn resume_sessions(specs: Vec<(String, String, String)>, router: &Arc<Router>) {
    for (terminal_id, profile_id, notify_mode) in specs {
        match watcher::watch_start(
            terminal_id.clone(),
            Some(profile_id),
            crate::watcher::NotifyMode::from_str(&notify_mode),
            router.clone(),
        ) {
            Ok(()) => log::info!("state: resumed watch on {terminal_id}"),
            Err(e) => log::warn!("state: resume watch on {terminal_id} failed: {e}"),
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ONE test owns all AGENT_RELAY_STATE_FILE mutations — Rust runs tests in
    // parallel threads and the env var is process-global.
    #[test]
    fn test_state_path_save_load_roundtrip() {
        // Path resolution: override, disable, exe-dir fallback.
        std::env::set_var("AGENT_RELAY_STATE_FILE", "/tmp/agent_relay_test_state.json");
        assert_eq!(
            state_file_path(),
            Some(PathBuf::from("/tmp/agent_relay_test_state.json"))
        );
        std::env::set_var("AGENT_RELAY_STATE_FILE", "");
        assert_eq!(state_file_path(), None, "empty override disables persistence");
        std::env::remove_var("AGENT_RELAY_STATE_FILE");
        let p = state_file_path().expect("falls back to exe dir");
        assert!(p.ends_with("agent_relay_state.json"));

        let dir = std::env::temp_dir().join(format!(
            "agent-relay-state-test-{}", std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("agent_relay_state.json");
        std::env::set_var("AGENT_RELAY_STATE_FILE", file.to_str().unwrap());

        crate::init_filter_rules();
        profiles::init_profiles();
        watcher::init_sessions();

        // Mutate: one profile override + one filter rule.
        let mut p = profiles::profile_get("claude").unwrap();
        p.detection.settle_ms = 4_242;
        profiles::profile_set(p);
        crate::with_filter_rules(|rs| {
            rs.set(FilterRule::new("t-rule", r"^noise", RuleAction::DropLine, "").unwrap())
        });

        save();
        let raw = std::fs::read_to_string(&file).expect("state file written");
        let doc: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(doc["version"], 1);
        assert_eq!(doc["profiles"].as_array().unwrap().len(), 1,
            "only the changed profile persisted");
        assert_eq!(doc["profiles"][0]["id"], "claude");
        assert_eq!(doc["filter_rules"][0]["name"], "t-rule");

        // Fresh stores, then load — override + rule come back.
        crate::init_filter_rules();
        profiles::init_profiles();
        assert_eq!(profiles::profile_get("claude").unwrap().detection.settle_ms, 1_500);

        // NOTE: no assertion on sessions — the watcher registry is a process
        // global shared with concurrently-running watcher unit tests, so the
        // saved file may contain their sessions. Session persistence is
        // covered by test_sessions_resume_after_restart (separate process).
        let _sessions = load();
        assert_eq!(
            profiles::profile_get("claude").unwrap().detection.settle_ms,
            4_242,
            "persisted profile override re-applied over seeds"
        );
        let rule_count = crate::with_filter_rules(|rs| rs.len());
        assert_eq!(rule_count, 1, "persisted filter rule restored");

        std::env::remove_var("AGENT_RELAY_STATE_FILE");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
