// dialog.rs — permission-dialog option parsing for chat-passthrough (B7).
//
// When the detector reports input_requested, the watched CLI is showing a
// permission/question dialog. This module extracts the dialog region from the
// RAW screen (the profile's permission_dialog_regex locates it — same regex
// the detector fired on) and parses the actionable options into
// {label, keystroke} pairs for the host's question card (W4): clicking an
// option sends ONE keystroke back through passthrough_generate.
//
// Keystroke semantics (DCR 019eb7f329 comment #483 + codex calibration):
//   "› 1. Yes, proceed (y)"  → {label: "Yes, proceed", keystroke: "y"}
//   "2. Continue"            → {label: "Continue", keystroke: "2"}
//                              (numbered, no hint → the number key)
//   "3. No (esc)"            → keystroke is the ESC byte "\u{1b}" — an
//                              actionable byte, not the literal text "esc"
//   "Press enter to confirm or esc to cancel" (and no numbered options)
//                            → Confirm "\r" / Cancel "\u{1b}"
//
// Parsing is per-profile-extensible: parse_options() routes on profile_id;
// every profile currently uses the generic parser, which is calibrated against
// the byte-true codex fixture (tests/fixtures/real/codex_permission.txt).

use regex::Regex;
use serde_json::{json, Value};

/// One actionable dialog option.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DialogOption {
    pub label: String,
    pub keystroke: String,
}

impl DialogOption {
    pub fn to_json(&self) -> Value {
        json!({ "label": self.label, "keystroke": self.keystroke })
    }
}

/// Extract the dialog region from a raw screen: from the FIRST line within the
/// last `window` lines that matches `dialog_re`, through the end of the screen.
/// Falls back to the last `window` lines when the regex matches nothing
/// (defensive — input_requested implies a match fired on the wait screen, but
/// the screen may have repainted between detection and this read).
pub fn extract_dialog_region(screen: &str, dialog_re: Option<&Regex>, window: usize) -> String {
    let lines: Vec<&str> = screen.lines().collect();
    let start_window = lines.len().saturating_sub(window);
    if let Some(re) = dialog_re {
        for (i, line) in lines.iter().enumerate().skip(start_window) {
            if re.is_match(line) {
                return lines[i..].join("\n");
            }
        }
    }
    lines[start_window..].join("\n")
}

/// Parse dialog options from a dialog region. `profile_id` is the extension
/// point for CLI-specific parsers; all current profiles route to the generic
/// parser (codex-tuned coverage lives in the generic rules + fixture tests).
pub fn parse_options(profile_id: &str, region: &str) -> Vec<DialogOption> {
    match profile_id {
        // Per-profile overrides slot in here when a CLI's dialog layout stops
        // fitting the generic rules, e.g.:  "claude" => parse_claude(region),
        _ => parse_generic(region),
    }
}

/// Generic dialog-option parser.
///
/// Pass 1: numbered option lines — optional selection marker (›/❯/>) +
/// "<n>." or "<n>)" + label, with an optional trailing "(hint)" keystroke.
/// Pass 2 (only when pass 1 found nothing): enter/esc phrasing lines produce
/// a Confirm/Cancel pair.
/// Garbage region → empty vec (caller falls back to free text).
fn parse_generic(region: &str) -> Vec<DialogOption> {
    // Compiled per call: dialogs are rare, human-paced events — clarity over
    // a static cache. The pattern is a constant, so unwrap() cannot fail.
    let numbered = Regex::new(r"^\s*[›❯>]?\s*(\d+)[.)]\s+(.+?)\s*$").unwrap();

    let mut options: Vec<DialogOption> = Vec::new();
    for line in region.lines() {
        if let Some(caps) = numbered.captures(line) {
            let number = caps[1].to_string();
            let body = caps[2].trim();
            let (label, keystroke) = split_hint(body, &number);
            options.push(DialogOption { label, keystroke });
        }
    }
    if !options.is_empty() {
        return options;
    }

    // No numbered options — look for bare enter/esc phrasing. (When numbered
    // options exist, the trailing "Press enter to confirm or esc to cancel"
    // line is picker chrome, not extra options — letter/number keys act
    // directly, so the numbered options are the actionable set.)
    let lower = region.to_lowercase();
    let has_enter = lower.contains("enter to confirm")
        || lower.contains("press enter");
    let has_esc = lower.contains("esc to cancel") || lower.contains("press esc");
    if has_enter {
        options.push(DialogOption { label: "Confirm".into(), keystroke: "\r".into() });
    }
    if has_esc {
        options.push(DialogOption { label: "Cancel".into(), keystroke: "\u{1b}".into() });
    }
    options
}

/// Split a trailing "(hint)" keystroke hint off an option body.
/// "(y)" → keystroke "y"; "(esc)"/"(enter)"/"(tab)"/"(space)" → the named key
/// byte; any other parenthetical (e.g. "(recommended)") is NOT a hint — it
/// stays in the label and the option number becomes the keystroke.
fn split_hint(body: &str, number: &str) -> (String, String) {
    if body.ends_with(')') {
        if let Some(open) = body.rfind('(') {
            if open > 0 {
                let hint = &body[open + 1..body.len() - 1];
                if let Some(ks) = hint_keystroke(hint) {
                    let label = body[..open].trim_end().to_string();
                    return (label, ks);
                }
            }
        }
    }
    (body.to_string(), number.to_string())
}

/// Map a hint string to the keystroke byte(s) it names, or None when the
/// parenthetical is not a keystroke hint.
fn hint_keystroke(hint: &str) -> Option<String> {
    let h = hint.trim().to_lowercase();
    match h.as_str() {
        "esc" | "escape" => Some("\u{1b}".to_string()),
        "enter" | "return" => Some("\r".to_string()),
        "tab" => Some("\t".to_string()),
        "space" => Some(" ".to_string()),
        _ => {
            if h.chars().count() == 1
                && h.chars().all(|c| c.is_ascii_alphanumeric())
            {
                Some(h)
            } else {
                None
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profiles::builtin_profiles;

    // Byte-true capture from live Codex CLI v0.139.0 — never retype.
    const CODEX_PERMISSION: &str =
        include_str!("../tests/fixtures/real/codex_permission.txt");

    fn opts(v: &[(&str, &str)]) -> Vec<DialogOption> {
        v.iter()
            .map(|(l, k)| DialogOption { label: l.to_string(), keystroke: k.to_string() })
            .collect()
    }

    // ── Numbered options with explicit letter hints ──────────────────────────

    #[test]
    fn test_numbered_with_letter_hint() {
        let region = "Would you like to proceed?\n\
                      › 1. Yes, proceed (y)\n\
                        2. No, stop here (n)\n";
        assert_eq!(
            parse_options("codex", region),
            opts(&[("Yes, proceed", "y"), ("No, stop here", "n")])
        );
    }

    // ── Numbered options without hints → number is the keystroke ────────────

    #[test]
    fn test_numbered_without_hint_uses_number() {
        let region = "Pick an option:\n\
                      1. Continue\n\
                      2. Abort\n";
        assert_eq!(
            parse_options("codex", region),
            opts(&[("Continue", "1"), ("Abort", "2")])
        );
    }

    // ── Non-keystroke parentheticals stay in the label ───────────────────────

    #[test]
    fn test_non_hint_parenthetical_stays_in_label() {
        let region = "1. Keep going (recommended)\n2. Stop\n";
        assert_eq!(
            parse_options("codex", region),
            opts(&[("Keep going (recommended)", "1"), ("Stop", "2")])
        );
    }

    // ── Named-key hints map to actionable bytes ──────────────────────────────

    #[test]
    fn test_named_key_hints_map_to_bytes() {
        let region = "1. Accept (enter)\n2. Reject (esc)\n";
        assert_eq!(
            parse_options("codex", region),
            opts(&[("Accept", "\r"), ("Reject", "\u{1b}")])
        );
    }

    // ── Enter/esc phrasing without numbered options → Confirm/Cancel ────────

    #[test]
    fn test_enter_esc_phrasing_confirm_cancel() {
        let region = "Apply these changes?\n\
                      Press enter to confirm or esc to cancel\n";
        assert_eq!(
            parse_options("claude", region),
            opts(&[("Confirm", "\r"), ("Cancel", "\u{1b}")])
        );
    }

    #[test]
    fn test_enter_esc_chrome_ignored_when_numbered_options_present() {
        let region = "› 1. Yes (y)\n\
                        2. No (esc)\n\
                      Press enter to confirm or esc to cancel\n";
        let parsed = parse_options("codex", region);
        assert_eq!(parsed.len(), 2, "picker chrome adds no Confirm/Cancel: {parsed:?}");
        assert_eq!(parsed[0].keystroke, "y");
        assert_eq!(parsed[1].keystroke, "\u{1b}");
    }

    // ── Garbage region → empty options (caller falls back to free text) ─────

    #[test]
    fn test_garbage_region_yields_empty() {
        let region = "lorem ipsum dolor\nsit amet ███▌▌\nno options here\n";
        assert!(parse_options("codex", region).is_empty());
        assert!(parse_options("codex", "").is_empty());
    }

    // ── Region extraction ────────────────────────────────────────────────────

    #[test]
    fn test_extract_region_starts_at_first_regex_match() {
        let re = Regex::new(r"(?i)would you like").unwrap();
        let screen = "old output line\nmore output\nWould you like to run it?\n1. Yes\n";
        let region = extract_dialog_region(screen, Some(&re), 20);
        assert!(region.starts_with("Would you like"), "region: {region:?}");
        assert!(region.contains("1. Yes"));
        assert!(!region.contains("old output"));
    }

    #[test]
    fn test_extract_region_fallback_last_window() {
        let screen = "a\nb\nc\nd\ne\n";
        let region = extract_dialog_region(screen, None, 2);
        assert_eq!(region, "d\ne");
        // Regex that matches nothing → same fallback.
        let re = Regex::new(r"zzz-never").unwrap();
        assert_eq!(extract_dialog_region(screen, Some(&re), 2), "d\ne");
    }

    // ── The byte-true codex fixture: exact {label, keystroke} pairs ─────────

    #[test]
    fn test_codex_permission_fixture_exact_options() {
        let codex = builtin_profiles().into_iter().find(|p| p.id == "codex").unwrap();
        let re = Regex::new(codex.detection.permission_dialog_regex.as_deref().unwrap())
            .unwrap();
        let region = extract_dialog_region(CODEX_PERMISSION, Some(&re), 20);
        assert!(
            region.starts_with("  Would you like to run the following command?"),
            "region anchored on the dialog header: {region:?}"
        );

        let parsed = parse_options("codex", &region);
        assert_eq!(
            parsed,
            opts(&[
                ("Yes, proceed", "y"),
                (
                    "Yes, and don't ask again for commands that start with \
                     `touch /tmp/codex_cal_test`",
                    "p"
                ),
                ("No, and tell Codex what to do differently", "\u{1b}"),
            ]),
            "exact option set for the codex fixture"
        );
    }
}
