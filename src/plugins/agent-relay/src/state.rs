// state.rs — single-file persistence for agent-relay runtime state.
//
// File: <exe_dir>/agent_relay_state.json by default. The Minerva host overrides
// this with --state-file pointing at persistent writable user data. Standalone
// launches may use AGENT_RELAY_STATE_FILE or the executable-adjacent fallback;
// an empty environment override disables persistence entirely for tests.
//
// Schema (flat root, version 1, defensive .get() on load — host_owned
// conventions):
// {
//   "version": 1,
//   "profiles": [Profile…],        // only profiles that DIFFER from builtins,
//                                  // so shipped seed improvements still apply
//                                  // to anything the user never touched
//   "filter_rules": [{name, pattern, action, replacement}…],
//   "sessions": [{terminal_id, profile_id, notify_mode,
//                 cwd, start_ms, prompts,     // binder facts; absent in
//                 prompt_ms}…]                // files older relays wrote;
//                                             // prompt_ms aligns by index
//                                             // with prompts
// }
//
// Save is triggered by every mutation (profile_set, filter_set/delete,
// watch_start/stop, watch-loop cleanup). Load runs once at startup; watch
// sessions resume after the router is up. A resumed session whose terminal no
// longer exists self-heals: its first host.terminal.wait errors, the loop
// emits terminal_closed (suppressed when unarmed) and cleans itself up.

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use serde_json::{json, Value};

use crate::filter_rules::{FilterRule, RuleAction};
use crate::profiles::{self, Profile};
use crate::router::Router;
use crate::terminal_facts::SessionFacts;
use crate::watcher::{self, SessionSpec};

static CLI_STATE_FILE: OnceLock<PathBuf> = OnceLock::new();

pub fn set_cli_state_file(path: PathBuf) -> Result<(), &'static str> {
    CLI_STATE_FILE.set(path).map_err(|_| "state file was already configured")
}

/// Resolve the state-file path. None disables persistence.
pub fn state_file_path() -> Option<PathBuf> {
    resolve_state_file_path(
        CLI_STATE_FILE.get().cloned(),
        std::env::var("AGENT_RELAY_STATE_FILE").ok(),
        std::env::current_exe().ok(),
    )
}

fn resolve_state_file_path(
    cli: Option<PathBuf>, env: Option<String>, executable: Option<PathBuf>,
) -> Option<PathBuf> {
    if cli.is_some() {
        return cli;
    }
    if let Some(overridden) = env {
        return if overridden.is_empty() { None } else { Some(PathBuf::from(overridden)) };
    }
    executable?.parent().map(|parent| parent.join("agent_relay_state.json"))
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
        .map(|spec| {
            let mut obj = serde_json::Map::new();
            obj.insert("terminal_id".to_string(), json!(spec.terminal_id));
            obj.insert("profile_id".to_string(), json!(spec.profile_id));
            obj.insert("notify_mode".to_string(), json!(spec.notify_mode));
            spec.facts.write_into(&mut obj);
            Value::Object(obj)
        })
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
pub fn load() -> Vec<SessionSpec> {
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

    let sessions: Vec<SessionSpec> = doc.get("sessions")
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
                    Some(SessionSpec {
                        terminal_id: tid,
                        profile_id: pid,
                        notify_mode: mode,
                        facts: SessionFacts::from_json(s),
                    })
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
pub fn resume_sessions(specs: Vec<SessionSpec>, router: &Arc<Router>) {
    for spec in specs {
        let terminal_id = spec.terminal_id.clone();
        match watcher::watch_start_with_facts(
            terminal_id.clone(),
            Some(spec.profile_id),
            crate::watcher::NotifyMode::from_str(&spec.notify_mode),
            Some(spec.facts),
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

    #[test]
    fn cli_state_path_precedes_environment_and_fallback() {
        let cli = PathBuf::from("/writable/user/agent_relay_state.json");
        assert_eq!(resolve_state_file_path(
            Some(cli.clone()), Some("/legacy/state.json".into()),
            Some(PathBuf::from("/package/agent-relay-plugin"))), Some(cli));
        assert_eq!(resolve_state_file_path(
            None, Some(String::new()), Some(PathBuf::from("/package/agent-relay-plugin"))), None);
        assert_eq!(resolve_state_file_path(
            None, None, Some(PathBuf::from("/package/agent-relay-plugin"))),
            Some(PathBuf::from("/package/agent_relay_state.json")));
    }

    // ONE test owns all AGENT_RELAY_STATE_FILE mutations — Rust runs tests in
    // parallel threads and the env var is process-global.
    #[test]
    fn test_state_path_save_load_roundtrip() {
        // PROFILES is process-global too: profiles tests calling init_profiles()
        // concurrently reset the override this test asserts on.
        let _g = crate::profiles::TEST_PROFILES_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
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
        // Those same watcher tests trigger save-on-mutation, which can clobber
        // this temp file between our save() and load() — restore the captured
        // bytes so load() reads exactly what save() wrote.
        std::fs::write(&file, &raw).unwrap();
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
