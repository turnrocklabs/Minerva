// profiles.rs — built-in CLI agent detection profiles for agent-relay.
//
// Each profile describes how to detect turn completion and parse output for a
// specific CLI agent. Values here are calibration-pending first guesses based
// on known TUI conventions; B3 will refine them with real captured output.

use serde::{Deserialize, Serialize};

/// Detection parameters for a CLI agent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Detection {
    /// Regex that matches the prompt-ready input box.
    /// When this pattern appears in the terminal, the agent is waiting for
    /// user input (turn complete).
    pub prompt_box_regex: String,

    /// Spinner characters emitted while the agent is thinking.
    /// Lines that consist only of these glyphs (+ whitespace) indicate
    /// in-progress work.
    pub spinner_glyphs: Vec<String>,

    /// Whether this CLI uses an alternate screen buffer (smcup/rmcup).
    /// Alternate-screen CLIs capture the full viewport on each repaint.
    pub alt_screen: bool,

    /// Whether this CLI rings a terminal bell (BEL, 0x07) on turn completion.
    /// Bell-capable CLIs allow zero-polling detection.
    pub bell_capable: bool,
}

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

/// Return the built-in list of known CLI agent profiles.
/// These are hard-coded defaults; the profile_set tool will allow overrides
/// in B3. Values marked "calibration pending" will be tuned with real captures.
pub fn builtin_profiles() -> Vec<Profile> {
    vec![
        Profile {
            id: "claude".to_string(),
            display_name: "Claude Code".to_string(),
            detection: Detection {
                // Claude Code renders a bordered input box when ready.
                // The bottom-left corner ╰ followed by ─ bars signals input-ready.
                // Calibration pending: verify against real captures.
                prompt_box_regex: r"╰[─]+╯\s*$".to_string(),
                // Claude Code uses Braille spinner dots while thinking.
                spinner_glyphs: vec![
                    "⠋".to_string(), "⠙".to_string(), "⠹".to_string(),
                    "⠸".to_string(), "⠼".to_string(), "⠴".to_string(),
                    "⠦".to_string(), "⠧".to_string(), "⠇".to_string(),
                    "⠏".to_string(),
                ],
                // Claude Code uses the alternate screen buffer.
                // Calibration pending.
                alt_screen: true,
                // Claude Code rings a bell on turn completion (configurable).
                // Calibration pending: default is bell-on.
                bell_capable: true,
            },
        },
        Profile {
            id: "codex".to_string(),
            display_name: "OpenAI Codex CLI".to_string(),
            detection: Detection {
                // Codex CLI uses a ">" prompt prefix when ready.
                // Calibration pending: verify exact prompt box shape.
                prompt_box_regex: r"^\s*>\s*$".to_string(),
                spinner_glyphs: vec![
                    "⠋".to_string(), "⠙".to_string(), "⠹".to_string(),
                    "⠸".to_string(), "⠼".to_string(), "⠴".to_string(),
                    "⠦".to_string(), "⠧".to_string(), "⠇".to_string(),
                    "⠏".to_string(),
                ],
                // Calibration pending.
                alt_screen: true,
                bell_capable: false,
            },
        },
        Profile {
            id: "opencode".to_string(),
            display_name: "OpenCode".to_string(),
            detection: Detection {
                // OpenCode uses a prompt indicator at the start of an input line.
                // Calibration pending: verify against real captures.
                prompt_box_regex: r"^\s*[›>]\s*$".to_string(),
                spinner_glyphs: vec![
                    "⠋".to_string(), "⠙".to_string(), "⠹".to_string(),
                    "⠸".to_string(), "⠼".to_string(), "⠴".to_string(),
                    "⠦".to_string(), "⠧".to_string(), "⠇".to_string(),
                    "⠏".to_string(),
                ],
                // Calibration pending.
                alt_screen: true,
                bell_capable: false,
            },
        },
    ]
}
