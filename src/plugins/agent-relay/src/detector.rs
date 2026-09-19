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
// The dialog pass is hold_reason over the WHOLE screen: the profile's own
// permission_dialog_regex plus two structural rules for the screens no profile
// phrase names (menus, unnumbered choosers). Both structural rules key on the
// chooser's OPTION BLOCK — a caret-selected row and the rows aligned with it —
// because a transcript reproduces every token in isolation: an echoed prompt
// that starts with a number renders as `❯ 1. …` and answer prose names the
// Enter key. Only blocks at or below the live composer row are considered, so
// an echo cannot imitate a chooser. hold_reason is also what the send gate asks
// before it writes: the same classification decides "a human is being asked"
// and "a keystroke here would answer a modal".
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
    /// Whether a single extra Enter is the known recovery for text left
    /// sitting in this CLI's composer after a write (see `confirm_submit`).
    pub composer_enter_recovery: bool,
    /// A caret-SELECTED numbered option line (`❯ 1. Yes`, `› 2. Skip`).
    menu_selected: Regex,
    /// Any numbered option line, marked or not (`  3. Skip until next version`).
    menu_option: Regex,
    /// A modal footer that names Enter as the action key.
    confirm_footer: Regex,
}

/// Longest trimmed line length still treated as modal FOOTER chrome rather
/// than prose. The longest footer in the hold corpus is 49 characters
/// ("Enter to select · ↑/↓ to navigate · Esc to cancel"); the cap keeps
/// headroom for wider variants, and the option-block rule below — not the
/// length — is what separates a footer from prose.
const FOOTER_MAX_LEN: usize = 80;

/// How far below an option block a modal footer may sit. Every footer in the
/// corpus is 2 rows under its last option row; the AskUserQuestion chooser,
/// which draws a rule line and one more option in between, is 4.
const FOOTER_MAX_GAP: usize = 6;

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
            composer_enter_recovery: p.detection.composer_enter_recovery,
            // Constant patterns — the unwraps cannot fail.
            menu_selected: Regex::new(r"^\s*[❯›>]\s*\d+[.)]\s+\S").unwrap(),
            menu_option: Regex::new(r"^\s*[❯›>]?\s*\d+[.)]\s+\S").unwrap(),
            confirm_footer: Regex::new(
                r"(?i)(?:press\s+)?enter\s+to\s+(?:confirm|select|continue)",
            )
            .unwrap(),
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
    //    hold_reason is the single classifier: it scans the whole screen with
    //    the profile regex (a dialog drawn mid-viewport with blank rows below
    //    it sits outside any trailing window) and it recognises menus and
    //    chooser footers structurally, whether or not the profile has a phrase
    //    for them. The same answer decides "a human is being asked" here and
    //    "a keystroke would answer a modal" at the send gate.
    if hold_reason(screen, cd).is_some() {
        return Some(DetectionResult {
            cause: WakeCause::InputRequested,
            method: DetectionMethod::PermissionDialog,
        });
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

/// Return true when the screen shows an active busy indicator (spinner glyph
/// within the last 40 lines). Used by the watcher's busy-gate: a settle_prompt
/// turn_completed only counts after the session has observed a busy screen
/// (or row growth) since arm()/watch_start — transition-based detection.
pub fn is_busy(screen: &str, cd: &CompiledDetection) -> bool {
    has_active_spinner(last_n_lines(screen, 40), &cd.spinner_glyphs)
}

// ---------------------------------------------------------------------------
// Hold states — screens a relay write must never land on
// ---------------------------------------------------------------------------

/// Why a screen currently owns the keyboard. Any variant means a write is
/// unsafe: the keystroke would answer a modal instead of starting a turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HoldReason {
    /// The profile's own permission/question-dialog pattern matched.
    Dialog,
    /// A caret-selected numbered option with at least one sibling — the
    /// structural shape every menu in the corpus shares, including the ones
    /// no profile phrase names (update offers, model pickers).
    Menu,
    /// A short modal footer naming Enter as the action key, which is all an
    /// UNNUMBERED chooser (the trust prompts) puts on screen.
    ConfirmFooter,
}

impl HoldReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            HoldReason::Dialog => "dialog",
            HoldReason::Menu => "menu",
            HoldReason::ConfirmFooter => "confirm_footer",
        }
    }
}

/// Classify a screen as holding the keyboard, or None when a write may land.
///
/// Scans the WHOLE screen, not a trailing window: menus are drawn wherever
/// the TUI has room and the rows below them are blank, so a window measured
/// from the last row is the single reason a dialog goes unnoticed.
pub fn hold_reason(screen: &str, cd: &CompiledDetection) -> Option<HoldReason> {
    let lines: Vec<&str> = screen.lines().collect();
    let blocks = live_option_blocks(&lines, cd);

    // A profile phrase that is itself a structural token — an option row, or a
    // footer naming the Enter key — is the shape a transcript reproduces: a
    // user prompt starting with a number echoes as `❯ 1. …`, and answer prose
    // names the Enter key. Those go through the block rules below, which ask
    // whether the row has aligned siblings. Every other phrase ("would you
    // like to run", "(y/n)") is the dialog's own words and stands on its own.
    if let Some(ref dialog_re) = cd.permission_dialog {
        if lines.iter().any(|l| {
            dialog_re.is_match(l) && !cd.menu_option.is_match(l) && !cd.confirm_footer.is_match(l)
        }) {
            return Some(HoldReason::Dialog);
        }
    }

    // A caret-selected numbered row whose own block holds a numbered sibling.
    // The block — not a screen-wide count — is what separates a menu from a
    // numbered list inside an answer several rows below an echoed prompt.
    if blocks.iter().any(|b| {
        b.options.len() >= 2
            && cd.menu_selected.is_match(lines[b.anchor])
            && b.options.iter().filter(|&&i| cd.menu_option.is_match(lines[i])).count() >= 2
    }) {
        return Some(HoldReason::Menu);
    }

    // An UNNUMBERED chooser puts nothing on screen but its options and this
    // footer, so the footer has to carry the verdict — bounded to the rows
    // just under an option block, since prose names the Enter key too.
    if lines.iter().enumerate().any(|(i, l)| {
        l.trim().chars().count() <= FOOTER_MAX_LEN
            && cd.confirm_footer.is_match(l)
            && blocks.iter().any(|b| {
                let last = *b.options.last().unwrap();
                b.options.len() >= 2 && last < i && i - last <= FOOTER_MAX_GAP
            })
    }) {
        return Some(HoldReason::ConfirmFooter);
    }

    None
}

/// The chooser blocks that can be LIVE on this screen.
///
/// A TUI draws its transcript above the input box and takes the box away while
/// a modal owns the keyboard — every fixture in the hold corpus ends in its
/// footer, with no composer under it. So a block that ends ABOVE the composer
/// row is transcript, whatever its shape: a wrapped prompt echo, whose
/// continuation rows the transcript indents to the caret's label column, is
/// row-for-row a selected option plus its sibling, and a pasted or blockquoted
/// numbered list reproduces a whole menu. Dropping those blocks is what keeps
/// an ordinary settled turn out of the Menu and ConfirmFooter rules below.
fn live_option_blocks(lines: &[&str], cd: &CompiledDetection) -> Vec<OptionBlock> {
    let composer = lines.iter().rposition(|l| cd.prompt_box.is_match(l));
    option_blocks(lines)
        .into_iter()
        .filter(|b| match composer {
            None => true,
            Some(row) => b.options.last().is_some_and(|&last| last >= row),
        })
        .collect()
}

/// A caret-selected option row and the rows drawn with it as one chooser.
struct OptionBlock {
    /// Row index of the caret-selected line that anchors the block.
    anchor: usize,
    /// Row indices of the option rows, in screen order, anchor included.
    options: Vec<usize>,
}

/// Every chooser block on the screen.
///
/// A chooser draws its options at one column: the selected row spends its
/// leading cells on a caret, the others on spaces, and a wrapped description
/// sits further right. So a block is the run of rows around a caret-selected
/// row whose content starts at the SAME column (an option) or further right
/// (that option's description), with at most one blank row bridging two
/// options. A row whose content starts further LEFT is transcript or box
/// chrome, and ends the block.
fn option_blocks(lines: &[&str]) -> Vec<OptionBlock> {
    let mut blocks = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let Some(col) = selected_label_col(line) else { continue };
        let mut options = vec![i];
        collect_aligned(lines, i, col, false, &mut options);
        options.reverse();
        collect_aligned(lines, i, col, true, &mut options);
        blocks.push(OptionBlock { anchor: i, options });
    }
    blocks
}

/// Walk away from `anchor` in one direction, pushing the row index of every
/// aligned option row onto `options` until the block ends.
fn collect_aligned(
    lines: &[&str],
    anchor: usize,
    col: usize,
    down: bool,
    options: &mut Vec<usize>,
) {
    let mut i = anchor;
    let mut blank_bridged = false;
    loop {
        i = if down {
            i + 1
        } else if i == 0 {
            return;
        } else {
            i - 1
        };
        let Some(line) = lines.get(i) else { return };
        if option_label_col(line) == Some(col) {
            options.push(i);
            blank_bridged = false;
            continue;
        }
        match content_col(line) {
            // Blank row: one may bridge two options; a second ends the block.
            None => {
                if blank_bridged {
                    return;
                }
                blank_bridged = true;
            }
            // Indented further than the options — a wrapped description.
            Some(c) if c > col => blank_bridged = false,
            _ => return,
        }
    }
}

/// Column of a row's option label: past a leading selection or scroll marker
/// when one is there (an off-edge chooser row is prefixed with `↑`/`↓`),
/// otherwise the row's own content column. This is the column a chooser aligns
/// every option on, marked or not.
fn option_label_col(line: &str) -> Option<usize> {
    selected_label_col(line).or_else(|| marker_label_col(line)).or_else(|| content_col(line))
}

/// Label column past a leading `↑`/`↓` scroll cursor, or None when the row
/// carries no such marker.
fn marker_label_col(line: &str) -> Option<usize> {
    let chars: Vec<char> = line.chars().collect();
    let marker = chars.iter().position(|c| !c.is_whitespace())?;
    if !matches!(chars[marker], '↑' | '↓') {
        return None;
    }
    let label = chars[marker + 1..].iter().position(|c| !c.is_whitespace())? + marker + 1;
    (label > marker + 1).then_some(label)
}

/// Column (in characters) of a row's first non-whitespace character, or None
/// when the row is blank.
fn content_col(line: &str) -> Option<usize> {
    line.chars().position(|c| !c.is_whitespace())
}

/// Column of the label on a caret-SELECTED option row (`❯ 1. Yes`, `› Skip`),
/// or None when the row is not one. An empty composer (`❯`, or `❯` + NBSP) has no
/// label and is not an option row.
fn selected_label_col(line: &str) -> Option<usize> {
    let chars: Vec<char> = line.chars().collect();
    let caret = chars.iter().position(|c| !c.is_whitespace())?;
    if !matches!(chars[caret], '\u{276f}' | '\u{203a}' | '>') {
        return None;
    }
    let label = chars[caret + 1..].iter().position(|c| !c.is_whitespace())? + caret + 1;
    // The caret needs a gap before the label: `>foo` is a quote, not an option.
    (label > caret + 1).then_some(label)
}

// ---------------------------------------------------------------------------
// Submit confirmation — did the write actually become a turn?
// ---------------------------------------------------------------------------

/// What the screen says about a message the relay just wrote.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubmitState {
    /// The harness took the message. The payload names the evidence.
    Submitted(&'static str),
    /// The message is still sitting in the composer, unechoed, with no turn in
    /// flight — the settled paste-failure shape. Exactly one extra Enter is the
    /// measured recovery, and only on profiles that show this state.
    StuckInComposer,
    /// A modal owns the keyboard on the screen sampled after the write: the
    /// write is unconfirmed AND no keystroke may be spent on it, because the
    /// Enter a stuck composer would earn SELECTS the highlighted option. The
    /// selected row of a chooser carries the same caret glyph as the composer,
    /// and carries the body too whenever the sent text is one of the offered
    /// answers — which is exactly when the mistake costs the most.
    Held(HoldReason),
    /// Neither confirmed nor demonstrably stuck. Never worth an extra Enter:
    /// a blind Enter is what answers a menu by accident.
    Unconfirmed,
}

/// Decide whether `body` reached the harness, from the screen sampled after
/// the write.
///
/// Evidence, in precedence order:
///   `busy`  — a turn is in flight (the interrupt hint is on screen). Every
///             confirmed-submit capture in the corpus shows it.
///   `echo`  — the body appears on a row that is NOT the composer row, i.e.
///             the transcript took it, and only rows that are NEW since the
///             pre-write baseline (see `baseline` below).
///   held    — a hold state (dialog, menu, confirm footer) is on screen. The
///             row rules cannot tell a selected option from a composer, so the
///             hold classifier decides first and no recovery is owed.
///   stuck   — the composer row still carries the body, nothing echoes it and
///             nothing is running. Reported only for profiles that can show
///             this state; on Claude Code the same rows are produced by the
///             dim ghost suggestion drawn INTO an empty composer, and the
///             attribute that separates them does not survive row extraction.
///
/// `baseline` is the PRE-WRITE screen, when the caller read one.
/// Echo evidence is only evidence when it is NEW. The same text can already be
/// echoed in the transcript from an earlier submit — re-asking a question, a
/// retry — and that old row confirms nothing about the write just made: a
/// message that stuck in the composer would be read as submitted and get no
/// recovery Enter. So the echo rows are COUNTED on both screens and the write
/// is confirmed only when the count grew. With no baseline (the caller read no
/// pre-write screen) the count is compared against zero.
pub fn confirm_submit(
    screen: &str,
    body: &str,
    cd: &CompiledDetection,
    baseline: Option<&str>,
) -> SubmitState {
    if is_busy(screen, cd) {
        return SubmitState::Submitted("busy");
    }

    let needle = echo_needle(body);
    if needle.is_empty() {
        return SubmitState::Unconfirmed;
    }

    let (echoes, composer_holds_body) = echo_rows(screen, &needle, cd);
    let echoes_before = baseline.map_or(0, |b| echo_rows(b, &needle, cd).0);

    if echoes > echoes_before {
        return SubmitState::Submitted("echo");
    }
    // A hold state outranks the composer rule: on a chooser the row that looks
    // like a composer holding the body IS the selected option.
    if let Some(reason) = hold_reason(screen, cd) {
        return SubmitState::Held(reason);
    }
    if composer_holds_body && cd.composer_enter_recovery {
        return SubmitState::StuckInComposer;
    }
    SubmitState::Unconfirmed
}

/// How many rows of `screen` carry `needle` OUTSIDE the composer (the echo
/// count), and whether the composer row itself carries it.
fn echo_rows(screen: &str, needle: &str, cd: &CompiledDetection) -> (usize, bool) {
    let composer_idx = screen
        .lines()
        .enumerate()
        .filter(|(_, l)| cd.prompt_box.is_match(l))
        .map(|(i, _)| i)
        .last();
    let mut echoes = 0usize;
    let mut composer_holds_body = false;
    for (i, line) in screen.lines().enumerate() {
        if !normalize_row(line).contains(needle) {
            continue;
        }
        if Some(i) == composer_idx {
            composer_holds_body = true;
        } else {
            echoes += 1;
        }
    }
    (echoes, composer_holds_body)
}

/// The comparable fragment of a sent message: its first line, whitespace
/// collapsed, capped so a wrapped transcript row still contains it.
fn echo_needle(body: &str) -> String {
    let first = body.lines().next().unwrap_or("");
    let normalized = normalize_row(first);
    normalized.chars().take(48).collect()
}

/// Collapse a row to comparable text: caret/box glyphs and runs of whitespace
/// (the composer's NBSP included) become single spaces.
fn normalize_row(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut pending_space = false;
    for ch in line.chars() {
        if ch.is_whitespace() || matches!(ch, '❯' | '›' | '↳' | '│' | '┃') {
            pending_space = !out.is_empty();
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(ch);
    }
    out
}

/// Count the trailing rows of `screen` that are input-box chrome rather than
/// content: everything from the LAST line matching the profile's prompt_box
/// regex to the end (the live input box, draft rows below it, hint lines).
/// Falls back to counting trailing blank lines when no prompt is visible.
/// The watcher subtracts this from total_scrollback_rows so turn boundaries
/// anchor on the last CONTENT row — the answer renders INTO the rows the
/// input box occupied at snapshot time (B5 live finding 019eb345d4d9).
pub fn trailing_noncontent_rows(screen: &str, cd: &CompiledDetection) -> u64 {
    let lines: Vec<&str> = screen.lines().collect();
    if let Some(idx) = lines.iter().rposition(|l| cd.prompt_box.is_match(l)) {
        // Absorb the input box's top border and separating blanks above the
        // prompt line — they redraw with the next turn too.
        let mut first_chrome = idx;
        while first_chrome > 0 {
            let above = lines[first_chrome - 1];
            if above.trim().is_empty() || is_pure_box_line(above) {
                first_chrome -= 1;
            } else {
                break;
            }
        }
        return (lines.len() - first_chrome) as u64;
    }
    lines.iter().rev().take_while(|l| l.trim().is_empty()).count() as u64
}

/// True when the line is only box-drawing/block codepoints + whitespace
/// (an input-box border row).
fn is_pure_box_line(line: &str) -> bool {
    !line.trim().is_empty()
        && line.chars().all(|c| matches!(c, '\u{2500}'..='\u{25FF}') || c.is_whitespace())
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
        // Real Claude Code 2026-06 idle layout (tests/fixtures/real/):
        // the input prompt is `❯` + U+00A0 NO-BREAK SPACE (\u{a0} below) —
        // a plain-space-only regex misses it (B5 live finding).
        "Here is my answer to your question.\n\
         I recommend using Rust for this task.\n\
         \n\
         ✻ Baked for 3s\n\
         \n\
         \u{276f}\u{a0}\n\
         ? for shortcuts \u{b7} \u{2190} for agents\n"
    }

    /// A screen with an active Braille spinner — agent is still working.
    fn screen_claude_busy() -> &'static str {
        // Real busy layout: the prompt line stays visible DURING generation;
        // the reliable busy marker is the literal "esc to interrupt" hint.
        "✶ Pondering\u{2026} (3s \u{b7} esc to interrupt)\n\
         Running tool: read_file\n\
         \n\
         \u{276f}\u{a0}\n"
    }

    /// Claude Code idle on WINDOWS (ConPTY, live capture 2026-07-03): the
    /// input box renders as ASCII `> ` between horizontal rules — no `❯`,
    /// no NBSP (tests/fixtures/real/claude_windows_idle.txt). The prompt line
    /// is a BARE `>` here: cell extraction right-strips trailing spaces, so an
    /// empty input box reaches the detector with nothing after the caret.
    fn screen_claude_windows_idle() -> &'static str {
        "\u{25cf} What would you like to clarify about those questions?\n\
         \n\
         \u{273b} Brewed for 1m 17s\n\
         \n\
         \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n\
         >\n\
         \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n\
         \u{23f5}\u{23f5} bypass permissions on (shift+tab to cycle) \u{b7} \u{2190} for agents\n"
    }

    /// Claude Code busy on WINDOWS: same ASCII prompt box, but the interrupt
    /// hint is on screen — must NOT read as turn_completed.
    fn screen_claude_windows_busy() -> &'static str {
        "\u{2736} Pondering\u{2026} (3s \u{b7} esc to interrupt)\n\
         \n\
         \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n\
         > \n\
         \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n"
    }

    /// A screen with a permission dialog.
    fn screen_permission_dialog() -> &'static str {
        "The agent wants to run a bash command:\n\
           rm -rf /tmp/test\n\
         \n\
         Do you want to proceed? (y/n) [y]:\n\
         \n"
    }

    /// An AskUserQuestion chooser (Windows ASCII caret): numbered options with
    /// a `>` cursor and the nav footer. Must fire input_requested.
    fn screen_claude_windows_chooser() -> &'static str {
        // NOTE the explicit two-space indents: a `\` line continuation eats the
        // leading whitespace of the next source line, and an unselected option
        // row drawn at column 0 is a shape no harness produces — the caret
        // occupies that cell on the selected row.
        "Which experience should I prototype next?\n\
         \n\
         > 1. Group fair + NetTrans (Recommended)\n  2. CSA provider onboarding\n  6. Chat about this\n\
         \n\
         Enter to select \u{b7} \u{2191}/\u{2193} to navigate \u{b7} Esc to cancel\n"
    }

    /// LIVE REGRESSION (2026-07-03): a completed turn whose PROSE ends with a
    /// conversational "Do you want to …?" question, idle input box below. The
    /// old phrase-based dialog regex turned this into a phantom choice dialog
    /// (input_requested) and the passthrough chat stored only the question
    /// snippet instead of the full answer. Must detect as turn_completed.
    fn screen_claude_prose_question_idle() -> &'static str {
        "  So the ladder I'd write down: (1) one character, exact pose, on-model still\n\
         \n\
           Do you want to keep pushing on the target picture, or is the next move to look\n\
           at what you have in hand \u{2014} to see how far rung 1 is from working today?\n\
         \n\
         \u{273b} Cooked for 51s\n\
         \n\
         \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n\
         >\n\
         \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n\
         \u{23f5}\u{23f5} bypass permissions on (shift+tab to cycle) \u{b7} \u{2190} for agents\n"
    }

    /// Screen that looks idle but has a spinner further up (should detect as idle
    /// since spinners are only checked in the last 40 lines).
    /// The spinners are at lines 0-1; then 50 blank lines push them above the
    /// 40-line detection window; then the prompt box appears at the bottom.
    fn screen_spinner_above_fold() -> &'static str {
        concat!(
            "\u{2736} Previous activity (esc to interrupt)\n",
            "\u{2736} More activity (esc to interrupt)\n",
            // 50 blank lines — ensures spinners are outside the last-40-lines window
            "\n\n\n\n\n\n\n\n\n\n",  // 10
            "\n\n\n\n\n\n\n\n\n\n",  // 20
            "\n\n\n\n\n\n\n\n\n\n",  // 30
            "\n\n\n\n\n\n\n\n\n\n",  // 40
            "\n\n\n\n\n\n\n\n\n\n",  // 50
            "\u{276f}\u{a0}\n",
            "? for shortcuts\n",
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

    // ── Test: Windows ASCII prompt box (`> `, no ❯/NBSP) ─────────────────────

    #[test]
    fn test_turn_completed_windows_ascii_prompt() {
        let cd = compiled_claude();
        let result = run(screen_claude_windows_idle(), false, false, &cd);
        assert!(result.is_some(), "Windows idle screen should detect turn_completed");
        let r = result.unwrap();
        assert_eq!(r.cause, WakeCause::TurnCompleted);
        assert_eq!(r.method, DetectionMethod::SettlePrompt);
    }

    #[test]
    fn test_prose_question_is_turn_completed_not_dialog() {
        let cd = compiled_claude();
        let result = run(screen_claude_prose_question_idle(), false, false, &cd);
        assert!(result.is_some(), "settled prose-question screen should detect");
        let r = result.unwrap();
        assert_eq!(
            r.cause, WakeCause::TurnCompleted,
            "conversational 'Do you want to …?' prose must NOT read as a dialog"
        );
        assert_eq!(r.method, DetectionMethod::SettlePrompt);
    }

    #[test]
    fn test_windows_chooser_is_input_requested() {
        let cd = compiled_claude();
        let result = run(screen_claude_windows_chooser(), false, false, &cd);
        assert!(result.is_some(), "chooser screen should detect");
        let r = result.unwrap();
        assert_eq!(r.cause, WakeCause::InputRequested);
        assert_eq!(r.method, DetectionMethod::PermissionDialog);
    }

    #[test]
    fn test_windows_busy_not_turn_completed() {
        let cd = compiled_claude();
        let result = run(screen_claude_windows_busy(), false, false, &cd);
        assert!(
            result.is_none() || result.as_ref().map(|r| &r.cause) != Some(&WakeCause::TurnCompleted),
            "Windows busy screen (esc to interrupt) must not produce turn_completed: {result:?}"
        );
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

    // ── Test: is_busy (busy-gate input) ──────────────────────────────────────

    #[test]
    fn test_is_busy_on_spinner_screen() {
        let cd = compiled_claude();
        assert!(is_busy(screen_claude_busy(), &cd), "esc-to-interrupt screen is busy");
        assert!(!is_busy(screen_claude_idle(), &cd), "idle prompt screen is not busy");
        assert!(!is_busy("", &cd), "empty screen is not busy");
    }

    // ── Test: trailing_noncontent_rows (row anchoring) ───────────────────────

    #[test]
    fn test_trailing_noncontent_rows_idle_screen() {
        let cd = compiled_claude();
        // screen_claude_idle ends with: blank, ❯+NBSP line, hints line → 3 chrome
        // rows (the separating blank above the prompt is absorbed).
        assert_eq!(trailing_noncontent_rows(screen_claude_idle(), &cd), 3);
    }

    #[test]
    fn test_trailing_noncontent_rows_draft_below_prompt() {
        let cd = compiled_claude();
        // Multi-row draft + hints + blank below the prompt all count as chrome.
        let screen = "answer text\n\
                      \u{276f}\u{a0}first draft row\n\
                      second draft row\n\
                      ? for shortcuts\n\
                      \n";
        assert_eq!(trailing_noncontent_rows(screen, &cd), 4);
    }

    #[test]
    fn test_trailing_noncontent_rows_no_prompt_counts_blanks() {
        let cd = compiled_claude();
        assert_eq!(trailing_noncontent_rows("output line\n\n\n", &cd), 2);
        assert_eq!(trailing_noncontent_rows("output line\n", &cd), 0);
        assert_eq!(trailing_noncontent_rows("", &cd), 0);
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

    // ── Codex CLI — REAL fixtures, captured live from v0.139.0 (B5 HITL) ────
    // Byte-true captures in tests/fixtures/real/codex_*.txt (extracted from
    // the MCP transcript, never retyped — the claude NBSP lesson).

    const CODEX_IDLE: &str = include_str!("../tests/fixtures/real/codex_idle_prompt.txt");
    const CODEX_BUSY: &str = include_str!("../tests/fixtures/real/codex_busy.txt");
    const CODEX_DONE: &str = include_str!("../tests/fixtures/real/codex_done.txt");
    const CODEX_PERMISSION: &str = include_str!("../tests/fixtures/real/codex_permission.txt");

    fn compiled_codex() -> CompiledDetection {
        let codex = builtin_profiles().into_iter().find(|p| p.id == "codex").unwrap();
        CompiledDetection::from_profile(&codex).unwrap()
    }

    #[test]
    fn test_codex_idle_fires_turn_completed() {
        // Idle screen: `›` U+203A + space + PLACEHOLDER TEXT — the old
        // `^\s*[>❯]\s*$` seed matched neither the char nor the non-empty line.
        let result = run(CODEX_IDLE, false, false, &compiled_codex());
        let r = result.expect("codex idle prompt must detect turn_completed");
        assert_eq!(r.cause, WakeCause::TurnCompleted);
        assert_eq!(r.method, DetectionMethod::SettlePrompt);
    }

    #[test]
    fn test_codex_busy_does_not_fire_turn_completed() {
        // Busy screen shows "◦ Working (9s • esc to interrupt)" while the
        // prompt line stays visible — the interrupt hint must gate it.
        let result = run(CODEX_BUSY, false, false, &compiled_codex());
        assert!(
            result.as_ref().map(|r| &r.cause) != Some(&WakeCause::TurnCompleted),
            "busy codex screen must not produce turn_completed: {result:?}"
        );
    }

    #[test]
    fn test_codex_done_fires_turn_completed() {
        // Post-turn screen: working line VANISHED (codex leaves no persistent
        // status glyph), prompt+placeholder back at the bottom.
        let result = run(CODEX_DONE, false, false, &compiled_codex());
        let r = result.expect("codex done screen must detect turn_completed");
        assert_eq!(r.cause, WakeCause::TurnCompleted);
        assert_eq!(r.method, DetectionMethod::SettlePrompt);
    }

    #[test]
    fn test_codex_permission_dialog_fires_input_requested() {
        // The approval picker has NO busy marker on screen and its selector
        // line (`› 1. Yes, proceed (y)`) matches the prompt regex — without
        // the dialog regex this screen false-fires turn_completed.
        let result = run(CODEX_PERMISSION, false, false, &compiled_codex());
        let r = result.expect("codex permission dialog must detect");
        assert_eq!(r.cause, WakeCause::InputRequested);
        assert_eq!(r.method, DetectionMethod::PermissionDialog);
    }

    #[test]
    fn test_codex_is_primary_screen_profile() {
        // Scrollback grew 17→23→50 rows across live turns — codex scrolls the
        // primary screen; the busy-gate's row-growth arm depends on this.
        let codex = builtin_profiles().into_iter().find(|p| p.id == "codex").unwrap();
        assert!(!codex.detection.alt_screen, "codex runs on the primary screen");
    }
}

#[cfg(test)]
mod claude_v2_anchor_tests {
    use super::*;
    use crate::profiles;

    // Byte-true screen captured live 2026-06-12 (Claude Code v2.1.174 under
    // --dangerously-skip-permissions, after a short "hi" turn). The W8 HITL
    // failure: the turn window anchored BELOW the answer.
    const SCREEN: &str = include_str!("../tests/fixtures/real/claude_v2_short_turn_idle.txt");

    #[test]
    fn test_trailing_rows_on_claude_v2_screen() {
        let _g = profiles::TEST_PROFILES_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        profiles::init_profiles();
        let p = profiles::profile_get("claude").unwrap();
        let cd = CompiledDetection::from_profile(&p).unwrap();
        let trailing = trailing_noncontent_rows(SCREEN, &cd);
        // Box = separator + "❯ NBSP" + separator + status line = 4 rows.
        // Plus the blank above the box top = 5.
        assert!(trailing >= 4, "trailing chrome under-counted: {trailing}");
        let lines: Vec<&str> = SCREEN.lines().collect();
        let prompt_idx = lines.iter().rposition(|l| cd.prompt_box.is_match(l));
        assert!(prompt_idx.is_some(), "prompt_box regex must match the idle box prompt line");
    }
}

#[cfg(test)]
mod askuserquestion_tests {
    use super::*;
    use crate::profiles;

    // Byte-true AskUserQuestion chooser captured live 2026-06-18 (terminal
    // 4180446039187). The bug: the `❯ 1.` cursor line matches prompt_box_regex,
    // so without the footer signal the detector false-fires turn_completed and
    // the host never gets a question card.
    const CHOOSER: &str = include_str!("../tests/fixtures/real/claude_question.txt");

    #[test]
    fn test_chooser_fires_input_requested_not_turn_completed() {
        let _g = profiles::TEST_PROFILES_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        profiles::init_profiles();
        let p = profiles::profile_get("claude").unwrap();
        let cd = CompiledDetection::from_profile(&p).unwrap();

        // The cursor line DOES match the idle prompt regex — proving the
        // collision the footer signal must beat on precedence.
        assert!(
            CHOOSER.lines().any(|l| cd.prompt_box.is_match(l)),
            "the `❯ 1.` cursor line matches prompt_box — that's the false-positive source"
        );

        let r = run(CHOOSER, false, false, &cd).expect("chooser must detect");
        assert_eq!(
            r.cause,
            WakeCause::InputRequested,
            "chooser must be input_requested, not a false turn_completed"
        );
        assert_eq!(r.method, DetectionMethod::PermissionDialog);
    }
}
