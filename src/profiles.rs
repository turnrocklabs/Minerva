// profiles.rs — built-in CLI agent detection profiles for agent-relay.
//
// Each profile describes how to detect turn completion and parse output for a
// specific CLI agent. These are LLM-tunable at runtime via profile_set; the
// values here are the shipped defaults that the tool overrides.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;

/// Detection parameters for a CLI agent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Detection {
    /// Regex that matches the prompt-ready input box near the bottom of the
    /// screen. When this pattern appears in the terminal AND no spinners are
    /// active, the agent is waiting for user input (turn complete).
    pub prompt_box_regex: String,

    /// Regex that matches a permission / question dialog box that appears
    /// mid-turn (agent is blocked waiting for human confirmation). When this
    /// fires, the wake cause is input_requested rather than turn_completed.
    /// None means permission-dialog detection is disabled for this profile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_dialog_regex: Option<String>,

    /// Spinner characters emitted while the agent is thinking.
    /// Any line containing one of these glyphs is treated as "active" and
    /// blocks turn_completed detection (spinners still working = not done).
    pub spinner_glyphs: Vec<String>,

    /// Whether this CLI uses an alternate screen buffer (smcup/rmcup).
    /// Alt-screen CLIs repaint the full viewport on each update; detection
    /// reads the viewport only (no scrollback delta).
    pub alt_screen: bool,

    /// Whether this CLI rings a terminal bell (BEL, 0x07) on turn completion.
    /// Bell-capable CLIs allow zero-polling detection (bell = instant wake).
    /// Note: bell is opportunistic only; it must never be configured on the
    /// CLI by the plugin (NON-INTERFERENCE invariant).
    pub bell_capable: bool,

    /// How long to wait for output to settle (milliseconds) after the last
    /// byte arrives before running the detection pass. Lower = faster but
    /// more prone to false positives on re-rendering TUIs.
    #[serde(default = "default_settle_ms")]
    pub settle_ms: u64,

    /// How long (milliseconds) to wait for a turn to complete before emitting
    /// a timed_out wake. Default 10 minutes. After a timed_out event the arm
    /// is consumed (one-shot behaviour preserved).
    #[serde(default = "default_watch_timeout_ms")]
    pub watch_timeout_ms: u64,
}

fn default_settle_ms() -> u64 { 1_500 }
fn default_watch_timeout_ms() -> u64 { 600_000 } // 10 minutes

/// A complete agent detection profile.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    /// Unique identifier used in watch_start calls (e.g. "claude").
    pub id: String,

    /// Human-readable display name (e.g. "Claude Code").
    pub display_name: String,

    /// Detection configuration.
    pub detection: Detection,
}

// ---------------------------------------------------------------------------
// Built-in profile registry
// ---------------------------------------------------------------------------

/// Global profile store: built-in defaults layered with runtime overrides.
/// Profiles are initialised at startup; profile_set merges overrides on top.
static PROFILES: Mutex<Option<HashMap<String, Profile>>> = Mutex::new(None);

/// Initialise the global profile registry from the built-in defaults.
/// Called once from main().
pub fn init_profiles() {
    let mut guard = PROFILES.lock().unwrap();
    let map: HashMap<String, Profile> = builtin_profiles()
        .into_iter()
        .map(|p| (p.id.clone(), p))
        .collect();
    *guard = Some(map);
}

/// Look up a profile by id. Returns a clone.
pub fn profile_get(id: &str) -> Option<Profile> {
    let guard = PROFILES.lock().unwrap();
    guard.as_ref()?.get(id).cloned()
}

/// Insert or replace a profile.
pub fn profile_set(profile: Profile) {
    let mut guard = PROFILES.lock().unwrap();
    if let Some(map) = guard.as_mut() {
        map.insert(profile.id.clone(), profile);
    }
}

/// Return all profiles sorted by id.
pub fn profiles_list() -> Vec<Profile> {
    let guard = PROFILES.lock().unwrap();
    let mut profiles: Vec<Profile> = guard
        .as_ref()
        .map(|m| m.values().cloned().collect())
        .unwrap_or_default();
    profiles.sort_by(|a, b| a.id.cmp(&b.id));
    profiles
}

/// Return the built-in list of known CLI agent profiles.
/// These are the shipped defaults; profile_set overrides them at runtime.
pub fn builtin_profiles() -> Vec<Profile> {
    vec![
        Profile {
            id: "claude".to_string(),
            display_name: "Claude Code".to_string(),
            detection: Detection {
                // CALIBRATED against live Claude Code 2026-06 (B5 HITL,
                // tests/fixtures/real/). The input prompt is a `❯` followed
                // by U+00A0 NO-BREAK SPACE — `\s` (Unicode in Rust regex)
                // matches both NBSP and the ASCII space of echoed prompts.
                // The old ╰─╯ box style no longer exists.
                prompt_box_regex: r"^❯\s".to_string(),

                // Claude Code permission dialogs show a "Do you want to proceed?"
                // style prompt, or a "run this command?" confirmation box.
                permission_dialog_regex: Some(
                    r"(?i)(?:do you want to|allow claude|proceed\?|yes/no|\[y/n\]|❯ 1\. yes)".to_string()
                ),

                // Working indicator: status glyphs like ✻ PERSIST after a turn
                // ("✻ Baked for 3s"), so glyphs are NOT busy-markers. The only
                // reliable in-progress marker is the literal interrupt hint.
                spinner_glyphs: vec!["esc to interrupt".to_string()],

                // Claude Code scrolls the PRIMARY screen (scrollback grows).
                alt_screen: false,

                // Claude Code can ring a bell (config-dependent; opportunistic
                // only). We never change the CLI's config (NON-INTERFERENCE).
                bell_capable: true,

                // 1.5 seconds settle — Claude Code does final repaints after a
                // turn; a short settle avoids false positives on mid-repaint reads.
                settle_ms: 1_500,

                watch_timeout_ms: 600_000,
            },
        },
        Profile {
            id: "codex".to_string(),
            display_name: "OpenAI Codex CLI".to_string(),
            detection: Detection {
                // Codex CLI uses a ">" prompt prefix when ready.
                // The input line appears as a plain ">" at the left margin.
                prompt_box_regex: r"^\s*[>❯]\s*$".to_string(),

                // Codex uses "? (y/N)" style confirms for dangerous actions.
                permission_dialog_regex: Some(
                    r"(?i)\?\s*\(y/[Nn]\)|\?\s*\[y/n\]".to_string()
                ),

                spinner_glyphs: vec![
                    "⠋".to_string(), "⠙".to_string(), "⠹".to_string(),
                    "⠸".to_string(), "⠼".to_string(), "⠴".to_string(),
                    "⠦".to_string(), "⠧".to_string(), "⠇".to_string(),
                    "⠏".to_string(),
                ],

                alt_screen: true,
                bell_capable: false,
                settle_ms: 1_500,
                watch_timeout_ms: 600_000,
            },
        },
        Profile {
            id: "opencode".to_string(),
            display_name: "OpenCode".to_string(),
            detection: Detection {
                // OpenCode uses a "›" or ">" indicator at the start of an input line.
                prompt_box_regex: r"^\s*[›>❯]\s*$".to_string(),

                // OpenCode permission dialogs use "(y/n)" style.
                permission_dialog_regex: Some(
                    r"(?i)\?\s*\(y/n\)|\?\s*\[y/n\]|confirm.*\(y".to_string()
                ),

                spinner_glyphs: vec![
                    "⠋".to_string(), "⠙".to_string(), "⠹".to_string(),
                    "⠸".to_string(), "⠼".to_string(), "⠴".to_string(),
                    "⠦".to_string(), "⠧".to_string(), "⠇".to_string(),
                    "⠏".to_string(),
                ],

                alt_screen: true,
                bell_capable: false,
                settle_ms: 2_000,
                watch_timeout_ms: 600_000,
            },
        },
    ]
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_builtin_profiles_non_empty() {
        let profiles = builtin_profiles();
        assert!(!profiles.is_empty());
        let ids: Vec<&str> = profiles.iter().map(|p| p.id.as_str()).collect();
        assert!(ids.contains(&"claude"), "claude profile present");
        assert!(ids.contains(&"codex"), "codex profile present");
        assert!(ids.contains(&"opencode"), "opencode profile present");
    }

    #[test]
    fn test_init_and_get() {
        init_profiles();
        let p = profile_get("claude");
        assert!(p.is_some(), "claude profile findable after init");
        assert_eq!(p.unwrap().id, "claude");
    }

    #[test]
    fn test_profile_set_override() {
        init_profiles();
        let mut p = builtin_profiles().into_iter().find(|p| p.id == "claude").unwrap();
        p.detection.settle_ms = 9999;
        profile_set(p);
        let fetched = profile_get("claude").unwrap();
        assert_eq!(fetched.detection.settle_ms, 9999, "override persisted");
    }

    #[test]
    fn test_profiles_list_sorted() {
        init_profiles();
        let list = profiles_list();
        let ids: Vec<&str> = list.iter().map(|p| p.id.as_str()).collect();
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(ids, sorted, "profiles_list returns sorted by id");
    }

    #[test]
    fn test_serde_roundtrip() {
        let profiles = builtin_profiles();
        for p in &profiles {
            let json = serde_json::to_string(p).unwrap();
            let back: Profile = serde_json::from_str(&json).unwrap();
            assert_eq!(back.id, p.id);
            assert_eq!(back.detection.settle_ms, p.detection.settle_ms);
        }
    }
}
