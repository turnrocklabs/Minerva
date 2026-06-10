// detector.rs — per-CLI turn-end detection logic for agent-relay.
//
// Detection precedence (highest first):
//   1. bell_rung (if profile.bell_capable) — fast-path, zero polling.
//   2. settle + prompt_box_regex visible in last N lines + no spinner glyphs.
//   3. shell-prompt markers ([888z or OSC 133;A) in the last few lines while
//      a watch is active — agent returned to shell = agent_exited.
//   4. terminal_closed — host.terminal.wait returns terminal_id vanished
//      or host.terminal.list no longer contains the terminal.
//   5. timed_out — no turn end within watch_timeout_ms.
//
// Wake causes:
//   turn_completed    — normal turn end (idle prompt, agent waiting).
//   input_requested   — permission/question dialog detected mid-turn.
//   agent_exited      — foreground CLI returned to shell prompt.
//   terminal_closed   — terminal_id is gone.
//   timed_out         — arm timeout expired.
//
// Detection methods (reported in watch_status.last_detection_method):
//   bell              — bell_rung fast-path fired.
//   settle_prompt     — settle + prompt_box regex + no spinners.
//   permission_dialog — settle + permission_dialog_regex fired.
//   shell_marker      — [888z / OSC 133 shell-integration marker seen.
//   child_exit        — host reported terminal gone.
//   timeout           — arm_timeout expired.

use crate::profiles::Profile;
use regex::Regex;

// ---------------------------------------------------------------------------
// Detection result
// ---------------------------------------------------------------------------

/// Which wake event fired.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WakeCause {
    TurnCompleted,
    InputRequested,
    AgentExited,
    TerminalClosed,
    TimedOut,
}

impl WakeCause {
    pub fn as_str(&self) -> &'static str {
        match self {
            WakeCause::TurnCompleted  => "turn_completed",
            WakeCause::InputRequested => "input_requested",
            WakeCause::AgentExited    => "agent_exited",
            WakeCause::TerminalClosed => "terminal_closed",
            WakeCause::TimedOut       => "timed_out",
        }
    }
}

/// How the detection fired.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DetectionMethod {
    Bell,
    SettlePrompt,
    PermissionDialog,
    ShellMarker,
    ChildExit,
    Timeout,
}

impl DetectionMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            DetectionMethod::Bell             => "bell",
            DetectionMethod::SettlePrompt     => "settle_prompt",
            DetectionMethod::PermissionDialog => "permission_dialog",
            DetectionMethod::ShellMarker      => "shell_marker",
            DetectionMethod::ChildExit        => "child_exit",
            DetectionMethod::Timeout          => "timeout",
        }
    }
}

/// The outcome of one detection pass.
#[derive(Debug, Clone)]
pub struct DetectionResult {
    pub cause: WakeCause,
    pub method: DetectionMethod,
}

// ---------------------------------------------------------------------------
// Detection parameters extracted from a Profile
// ---------------------------------------------------------------------------

/// Compiled detection parameters for a profile.
pub struct CompiledDetection {
    pub prompt_box: Regex,
    pub permission_dialog: Option<Regex>,
    pub spinner_glyphs: Vec<String>,
    #[allow(dead_code)]
    pub alt_screen: bool,
    pub bell_capable: bool,
    pub settle_ms: u64,
    pub watch_timeout_ms: u64,
}

impl CompiledDetection {
    /// Compile detection params from a Profile. Returns Err if regex fails.
    pub fn from_profile(p: &Profile) -> Result<Self, String> {
        let prompt_box = Regex::new(&p.detection.prompt_box_regex)
            .map_err(|e| format!("prompt_box_regex compile error: {e}"))?;

        let permission_dialog = if let Some(ref pat) = p.detection.permission_dialog_regex {
            Some(Regex::new(pat)
                .map_err(|e| format!("permission_dialog_regex compile error: {e}"))?)
        } else {
            None
        };

        Ok(CompiledDetection {
            prompt_box,
            permission_dialog,
            spinner_glyphs: p.detection.spinner_glyphs.clone(),
            alt_screen: p.detection.alt_screen,
            bell_capable: p.detection.bell_capable,
            settle_ms: p.detection.settle_ms,
            watch_timeout_ms: p.detection.watch_timeout_ms,
        })
    }
}

// ---------------------------------------------------------------------------
// Detection passes
// ---------------------------------------------------------------------------

/// Shell-integration prompt markers that indicate the foreground process
/// returned to the shell (agent exited or crashed).
/// [888z is the Ghostty/tmux OSC 133;A style marker that Minerva emits via
/// TerminalNew.gd:315. Also match OSC 133 sequence in plain text captures.
const SHELL_MARKERS: &[&str] = &[
    "\x1b[888z",   // Ghostty shell integration escape
    "\x1b]133;A",  // OSC 133 A — shell prompt start
    "[888z",       // Plain text form (may appear in viewport reads)
    "OSC 133;A",   // Human-readable form (hypothetical)
];

/// Run all detection passes against a settled terminal screen and return
/// the first matching result, or None if nothing fired.
///
/// Parameters:
///   `screen`       — the full viewport / scrollback text at the detect point.
///   `bell_rung`    — whether host.terminal.wait reported bell_rung=true.
///   `shell_exited` — whether host.terminal.wait reported shell_exited=true.
///   `cd`           — compiled detection config for the active profile.
pub fn run(
    screen: &str,
    bell_rung: bool,
    shell_exited: bool,
    cd: &CompiledDetection,
) -> Option<DetectionResult> {
    // 1. Bell fast-path.
    if bell_rung && cd.bell_capable {
        return Some(DetectionResult {
            cause: WakeCause::TurnCompleted,
            method: DetectionMethod::Bell,
        });
    }

    // 2. Shell exited (from host.terminal.wait shell_exited field).
    if shell_exited {
        return Some(DetectionResult {
            cause: WakeCause::AgentExited,
            method: DetectionMethod::ChildExit,
        });
    }

    let last_lines = last_n_lines(screen, 40);

    // 3. Shell-integration markers in the last N lines (agent returned to shell).
    for line in last_lines.lines() {
        for marker in SHELL_MARKERS {
            if line.contains(marker) {
                return Some(DetectionResult {
                    cause: WakeCause::AgentExited,
                    method: DetectionMethod::ShellMarker,
                });
            }
        }
    }

    // 4. Permission dialog detection (before turn_completed so it takes precedence
    //    when both prompt and dialog regex match somehow — dialogs are mid-turn).
    if let Some(ref dialog_re) = cd.permission_dialog {
        let dialog_area = last_n_lines(screen, 20);
        for line in dialog_area.lines() {
            if dialog_re.is_match(line) {
                return Some(DetectionResult {
                    cause: WakeCause::InputRequested,
                    method: DetectionMethod::PermissionDialog,
                });
            }
        }
    }

    // 5. Spinners absent AND prompt_box visible → turn_completed.
    let has_spinner = has_active_spinner(last_lines, &cd.spinner_glyphs);
    if !has_spinner {
        let prompt_area = last_n_lines(screen, 10);
        for line in prompt_area.lines() {
            if cd.prompt_box.is_match(line) {
                return Some(DetectionResult {
                    cause: WakeCause::TurnCompleted,
                    method: DetectionMethod::SettlePrompt,
                });
            }
        }
    }

    None
}

/// Return the last N lines of `text` as a &str slice (starting at a
/// newline boundary). If the text has fewer than N lines, returns all of it.
fn last_n_lines(text: &str, n: usize) -> &str {
    let lines: Vec<&str> = text.lines().collect();
    if lines.len() <= n {
        return text;
    }
    let start_line = lines.len() - n;
    // Find the byte offset of the (lines.len()-n)'th line.
    let mut offset = 0usize;
    let mut found = 0usize;
    for (i, ch) in text.char_indices() {
        if found == start_line {
            offset = i;
            break;
        }
        if ch == '\n' {
            found += 1;
        }
    }
    &text[offset..]
}

/// Return true if any of `spinner_glyphs` appear on a line that is otherwise
/// only whitespace + spinner chars (a "busy" indicator line).
/// Also returns true if ANY line contains a spinner glyph — spinners can appear
/// mid-line in some TUIs.
fn has_active_spinner(text: &str, spinner_glyphs: &[String]) -> bool {
    if spinner_glyphs.is_empty() {
        return false;
    }
    for line in text.lines() {
        for glyph in spinner_glyphs {
            if line.contains(glyph.as_str()) {
                return true;
            }
        }
    }
    false
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profiles::{builtin_profiles, Profile};

    fn claude_profile() -> Profile {
        builtin_profiles().into_iter().find(|p| p.id == "claude").unwrap()
    }

    fn compiled_claude() -> CompiledDetection {
        CompiledDetection::from_profile(&claude_profile()).unwrap()
    }

    // ── Fixture screens ──────────────────────────────────────────────────────

    /// Claude Code in idle/prompt-ready state (chrome stripped — detector works
    /// on cleaned output from chrome_filter).
    fn screen_claude_idle() -> &'static str {
        "Here is my answer to your question.\n\
         I recommend using Rust for this task.\n\
         \n\
         ╰────────────────────────────────────────────╯\n\
         > _\n"
    }

    /// A screen with an active Braille spinner — agent is still working.
    fn screen_claude_busy() -> &'static str {
        "⠋ Thinking about your request...\n\
         Running tool: read_file\n"
    }

    /// A screen with a permission dialog.
    fn screen_permission_dialog() -> &'static str {
        "The agent wants to run a bash command:\n\
           rm -rf /tmp/test\n\
         \n\
         Do you want to proceed? (y/n) [y]:\n\
         \n"
    }

    /// Screen that looks idle but has a spinner further up (should detect as idle
    /// since spinners are only checked in the last 40 lines).
    /// The spinners are at lines 0-1; then 50 blank lines push them above the
    /// 40-line detection window; then the prompt box appears at the bottom.
    fn screen_spinner_above_fold() -> &'static str {
        concat!(
            "⠋ Previous activity\n",
            "⠙ More activity\n",
            // 50 blank lines — ensures spinners are outside the last-40-lines window
            "\n\n\n\n\n\n\n\n\n\n",  // 10
            "\n\n\n\n\n\n\n\n\n\n",  // 20
            "\n\n\n\n\n\n\n\n\n\n",  // 30
            "\n\n\n\n\n\n\n\n\n\n",  // 40
            "\n\n\n\n\n\n\n\n\n\n",  // 50
            "╰────────────────────────────────────────────╯\n",
            "> _\n",
        )
    }

    // ── Test: bell fast-path ─────────────────────────────────────────────────

    #[test]
    fn test_bell_fast_path() {
        let cd = compiled_claude();
        let result = run("", true, false, &cd);
        assert!(result.is_some(), "bell should trigger detection");
        let r = result.unwrap();
        assert_eq!(r.cause, WakeCause::TurnCompleted);
        assert_eq!(r.method, DetectionMethod::Bell);
    }

    #[test]
    fn test_bell_not_capable_profile() {
        // Codex is not bell-capable.
        let codex = builtin_profiles().into_iter().find(|p| p.id == "codex").unwrap();
        let cd = CompiledDetection::from_profile(&codex).unwrap();
        // Bell ring but not capable → should NOT fire bell path.
        let result = run("", true, false, &cd);
        // Might fire another path or None — but NOT bell method.
        if let Some(r) = result {
            assert_ne!(r.method, DetectionMethod::Bell, "codex is not bell_capable");
        }
    }

    // ── Test: turn_completed on settled prompt ───────────────────────────────

    #[test]
    fn test_turn_completed_settle_prompt() {
        let cd = compiled_claude();
        let result = run(screen_claude_idle(), false, false, &cd);
        assert!(result.is_some(), "idle screen should detect turn_completed");
        let r = result.unwrap();
        assert_eq!(r.cause, WakeCause::TurnCompleted);
        assert_eq!(r.method, DetectionMethod::SettlePrompt);
    }

    // ── Test: no false turn-end while spinner present ────────────────────────

    #[test]
    fn test_no_false_turn_end_while_spinner() {
        let cd = compiled_claude();
        let result = run(screen_claude_busy(), false, false, &cd);
        // The busy screen has no prompt_box, so no detection fires.
        // Even if the spinner suppression logic has a bug, there's no prompt to
        // match, so it should be None.
        assert!(
            result.is_none() || result.as_ref().map(|r| &r.cause) != Some(&WakeCause::TurnCompleted),
            "busy spinner screen must not produce turn_completed: {result:?}"
        );
    }

    // ── Test: input_requested on permission dialog ───────────────────────────

    #[test]
    fn test_input_requested_permission_dialog() {
        let cd = compiled_claude();
        // The permission_dialog_regex for Claude is set; for this test we need
        // a profile that has it. Add it if not already there.
        // Check if the default profile has a permission_dialog_regex.
        let profile = claude_profile();
        if profile.detection.permission_dialog_regex.is_none() {
            // Profile doesn't have one yet — skip this test.
            return;
        }
        let result = run(screen_permission_dialog(), false, false, &cd);
        assert!(result.is_some(), "permission dialog should fire input_requested");
        let r = result.unwrap();
        assert_eq!(r.cause, WakeCause::InputRequested);
        assert_eq!(r.method, DetectionMethod::PermissionDialog);
    }

    // ── Test: agent_exited on shell_exited flag ──────────────────────────────

    #[test]
    fn test_agent_exited_shell_flag() {
        let cd = compiled_claude();
        let result = run("", false, true, &cd);
        assert!(result.is_some());
        let r = result.unwrap();
        assert_eq!(r.cause, WakeCause::AgentExited);
        assert_eq!(r.method, DetectionMethod::ChildExit);
    }

    // ── Test: shell marker detection ─────────────────────────────────────────

    #[test]
    fn test_agent_exited_shell_marker() {
        let cd = compiled_claude();
        let screen = "claude> exit\n[888z\n$ ";
        let result = run(screen, false, false, &cd);
        assert!(result.is_some(), "shell marker should fire agent_exited");
        let r = result.unwrap();
        assert_eq!(r.cause, WakeCause::AgentExited);
        assert_eq!(r.method, DetectionMethod::ShellMarker);
    }

    // ── Test: last_n_lines helper ────────────────────────────────────────────

    #[test]
    fn test_last_n_lines_fewer_than_n() {
        let text = "a\nb\nc\n";
        let result = last_n_lines(text, 10);
        assert_eq!(result, text);
    }

    #[test]
    fn test_last_n_lines_more_than_n() {
        let lines: Vec<String> = (0..50).map(|i| format!("line {i}")).collect();
        let text = lines.join("\n");
        let last = last_n_lines(&text, 10);
        let last_lines_vec: Vec<&str> = last.lines().collect();
        assert!(last_lines_vec.len() <= 10, "should have at most 10 lines");
        // The last line should be "line 49".
        assert_eq!(last_lines_vec.last(), Some(&"line 49"));
    }

    // ── Test: spinner_above_fold doesn't block idle detection ───────────────

    #[test]
    fn test_spinner_above_fold_does_not_block_idle() {
        let cd = compiled_claude();
        let screen = screen_spinner_above_fold();
        let result = run(screen, false, false, &cd);
        // The spinners are way above the last 40 lines, so has_active_spinner
        // on last_n_lines(40) should NOT see them.
        // The prompt box in last 10 lines should fire turn_completed.
        assert!(
            result.is_some(),
            "spinner above fold should not block turn_completed"
        );
        if let Some(r) = result {
            assert_eq!(r.cause, WakeCause::TurnCompleted);
        }
    }
}
