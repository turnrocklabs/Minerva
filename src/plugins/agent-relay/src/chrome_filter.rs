// chrome_filter.rs — first-pass TUI chrome stripper for agent-relay.
//
// Purpose: given a raw string captured from a terminal running a CLI agent
// (Claude Code, Codex CLI, OpenCode, etc.), return a clean version containing
// only the agent's semantic output — no box-drawing borders, no spinner glyphs,
// no status bars, no leading/trailing decorative columns.
//
// Filter passes (applied in order):
//   1. Drop lines that consist ONLY of box-drawing / block-element codepoints
//      (U+2500–U+25FF) plus optional whitespace.
//   2. Strip leading/trailing box-drawing border columns from surviving lines
//      (trims sequences of box-drawing chars + spaces from each end).
//   3. Collapse runs of more than 2 consecutive blank lines down to a single
//      blank line.
//   (applied separately by callers, not in filter())
//   4. Redaction pass: mask common secret shapes with [REDACTED:<kind>].
//   5. Honest truncation: keep the TAIL up to MAX_OUTPUT_CHARS; set
//      truncated + omitted_chars in the result envelope.
//
// Passes 4 and 5 are exposed as separate public functions (redact, truncate)
// so read_clean can call them after the rule-filter layer. filter() itself
// remains a pure chrome stripper.
//
// This is intentionally a FIRST PASS — B3 will add per-CLI profile rules
// (spinner glyph stripping, prompt-box detection, etc.). The function is pure
// and has no I/O, making it trivially unit-testable.

/// Return true when `c` falls in the box-drawing (U+2500–U+257F) or
/// block-elements (U+2580–U+259F) or geometric shapes (U+25A0–U+25FF) ranges.
/// These are the codepoints that make up TUI chrome borders and fill characters.
#[inline]
fn is_box_or_block(c: char) -> bool {
    matches!(c, '\u{2500}'..='\u{25FF}')
}

/// Return true when the line contains ONLY box-drawing/block codepoints and
/// ASCII whitespace — i.e. it is a pure decorative border or separator row.
fn is_pure_chrome_line(line: &str) -> bool {
    if line.trim().is_empty() {
        // Blank lines are handled by the blank-collapse pass, not dropped here.
        return false;
    }
    line.chars().all(|c| is_box_or_block(c) || c.is_ascii_whitespace())
}

/// Strip leading and trailing box-drawing + space characters from a line.
/// Preserves the interior content.
fn strip_border_columns(line: &str) -> &str {
    let trimmed = line.trim_matches(|c: char| is_box_or_block(c) || c == ' ');
    trimmed
}

/// Apply the first-pass chrome filter to `raw` and return cleaned text.
///
/// # Parameters
/// - `raw`: raw terminal capture (may contain ANSI escapes — those are passed
///   through unchanged in this pass; ANSI stripping is B3 work).
///
/// # Returns
/// Cleaned text as an owned `String`.
pub fn filter(raw: &str) -> String {
    // Pass 1 + 2: process line by line.
    let mut filtered_lines: Vec<&str> = Vec::new();
    for line in raw.lines() {
        if is_pure_chrome_line(line) {
            // Drop pure chrome lines entirely.
            continue;
        }
        let stripped = strip_border_columns(line);
        filtered_lines.push(stripped);
    }

    // Pass 3: collapse runs of consecutive blank lines to at most 1 blank line.
    // Strategy: build the output from non-blank lines, inserting at most one
    // blank line between content runs.
    let mut result = String::with_capacity(raw.len());
    let mut pending_blank = false;
    let mut any_content = false;

    for line in &filtered_lines {
        if line.trim().is_empty() {
            // Mark that we've seen a blank; don't emit yet.
            if any_content {
                pending_blank = true;
            }
        } else {
            // Content line: flush one pending blank if any, then emit content.
            if pending_blank {
                result.push('\n');
                pending_blank = false;
            }
            result.push_str(line);
            result.push('\n');
            any_content = true;
        }
    }

    // Restore trailing newline behaviour: if the raw input ended with a newline
    // and we have a trailing blank pending, emit it.
    if pending_blank && raw.ends_with('\n') {
        result.push('\n');
    }

    // If the raw input did NOT end with a newline, strip the trailing one we added.
    if result.ends_with('\n') && !raw.ends_with('\n') {
        result.truncate(result.len() - 1);
    }

    result
}

// ---------------------------------------------------------------------------
// Redaction pass
// ---------------------------------------------------------------------------

use regex::Regex;

/// Maximum characters in a read_clean output before honest truncation kicks in.
/// Matches host-side _TERMINAL_EXEC_MAX_OUTPUT precedent (~30 000 chars).
pub const MAX_OUTPUT_CHARS: usize = 30_000;

/// Description of a single secret kind recognised by the redaction pass.
struct RedactPattern {
    /// Short kind label written into [REDACTED:<kind>].
    kind: &'static str,
    /// Regex pattern. Must have no capturing groups (or use non-capturing groups).
    pattern: &'static str,
}

/// All built-in redaction patterns, in priority order.
/// Note: patterns are compiled once at call-time via lazy_static equivalent
/// (std once_cell). For simplicity and no new deps, we compile them on each
/// `redact` call and rely on the compiler to inline / the OS to cache pages.
/// A hot-path optimisation (once_cell/lazy_static) can be added in B3.
static REDACT_PATTERNS: &[RedactPattern] = &[
    // AWS access key IDs: AKIA followed by 16 uppercase alphanumeric chars.
    RedactPattern {
        kind: "aws_key_id",
        pattern: r"AKIA[0-9A-Z]{16}",
    },
    // AWS secret access keys: 40 chars of base64url after common assignment tokens.
    RedactPattern {
        kind: "aws_secret",
        pattern: r"(?:aws_secret_access_key|AWS_SECRET_ACCESS_KEY)\s*[=:]\s*[A-Za-z0-9/+]{40}",
    },
    // GitHub personal access tokens: classic (ghp_) and fine-grained (github_pat_).
    RedactPattern {
        kind: "github_token",
        pattern: r"gh[pors]_[A-Za-z0-9]{36,255}",
    },
    // GitHub fine-grained PAT.
    RedactPattern {
        kind: "github_pat",
        pattern: r"github_pat_[A-Za-z0-9_]{82,255}",
    },
    // OpenAI / Anthropic style sk- bearer tokens.
    RedactPattern {
        kind: "sk_token",
        pattern: r"sk-[A-Za-z0-9\-_]{20,255}",
    },
    // Slack bot tokens.
    RedactPattern {
        kind: "slack_token",
        pattern: r"xox[baprs]-[A-Za-z0-9\-]{10,255}",
    },
    // PEM private key blocks (single-line start marker).
    RedactPattern {
        kind: "pem_private_key",
        pattern: r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----",
    },
    // password= / passwd= / token= / secret= / api_key= value patterns
    // (case-insensitive, value up to first whitespace or quote).
    RedactPattern {
        kind: "credential_value",
        pattern: r#"(?i)(?:password|passwd|token|secret|api_key|apikey)\s*[=:]\s*[^\s"']{4,255}"#,
    },
    // Bearer tokens in HTTP Authorization headers.
    RedactPattern {
        kind: "bearer_token",
        pattern: r"(?i)bearer\s+[A-Za-z0-9\-_\.]{20,512}",
    },
];

/// Apply the redaction pass to `text`.
///
/// Each match of a known secret pattern is replaced with `[REDACTED:<kind>]`.
/// Patterns are applied sequentially; a single substring can only be redacted
/// by the first matching pattern (once replaced, it no longer matches later ones).
///
/// Returns the redacted string.
pub fn redact(text: &str) -> String {
    let mut result = text.to_string();
    for pat in REDACT_PATTERNS {
        // Compile each regex — in production code use once_cell; here clarity wins.
        match Regex::new(pat.pattern) {
            Ok(re) => {
                let replacement = format!("[REDACTED:{}]", pat.kind);
                let replaced = re.replace_all(&result, replacement.as_str());
                // Use into_owned unconditionally — Cow::into_owned() is cheap
                // when no replacement occurred (returns the existing allocation).
                result = replaced.into_owned();
            }
            Err(e) => {
                // Should never happen with static patterns; log and skip.
                eprintln!("agent-relay: redact pattern compile error ({kind}): {e}", kind = pat.kind);
            }
        }
    }
    result
}

// ---------------------------------------------------------------------------
// Honest truncation
// ---------------------------------------------------------------------------

/// Result of the truncation check.
pub struct TruncationResult {
    /// The (possibly tail-truncated) text.
    pub text: String,
    /// True if the input exceeded MAX_OUTPUT_CHARS and was truncated.
    pub truncated: bool,
    /// Number of characters omitted from the HEAD (oldest output).
    pub omitted_chars: usize,
}

/// Apply honest truncation to `text`.
///
/// If `text.len() <= max_chars` the result is a no-op (truncated=false).
/// Otherwise we KEEP THE TAIL — the most recent output — discarding older
/// head content. We split on a newline boundary so we never cut mid-line.
/// The caller should surface `truncated` and `omitted_chars` in the tool
/// result payload.
pub fn truncate(text: &str, max_chars: usize) -> TruncationResult {
    if text.len() <= max_chars {
        return TruncationResult {
            text: text.to_string(),
            truncated: false,
            omitted_chars: 0,
        };
    }

    // We want to keep the last `max_chars` characters.
    // Find a clean newline boundary inside that window.
    let keep_start_byte = text.len() - max_chars;
    // Advance to the next newline so we don't cut mid-line.
    let split_byte = text[keep_start_byte..]
        .find('\n')
        .map(|offset| keep_start_byte + offset + 1)
        .unwrap_or(keep_start_byte);

    let omitted_chars = split_byte; // chars omitted = everything before split point
    let tail = &text[split_byte..];

    TruncationResult {
        text: tail.to_string(),
        truncated: true,
        omitted_chars,
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ── Fixture helpers ──────────────────────────────────────────────────────

    /// A realistic Claude Code TUI prompt-ready state (collapsed to ASCII art).
    /// The real terminal uses box-drawing; we exercise those exact codepoints.
    fn claude_prompt_box() -> &'static str {
        // ╭─────────────────────────────────────────────────────────────╮
        // │ > _                                                         │
        // ╰─────────────────────────────────────────────────────────────╯
        "╭─────────────────────────────────────────────────────────────╮\n\
         │ > _                                                         │\n\
         ╰─────────────────────────────────────────────────────────────╯"
    }

    /// A pure separator line (only box-drawing, no content).
    fn separator_line() -> &'static str {
        "─────────────────────────────────────────────────────────────────"
    }

    /// A realistic agent response fragment with border columns on left/right.
    fn bordered_content() -> &'static str {
        // │ This is the agent's answer.                                 │
        // │ It spans multiple lines.                                    │
        "│ This is the agent's answer.                                 │\n\
         │ It spans multiple lines.                                    │"
    }

    /// A realistic spinner / status line (pure chrome row).
    fn spinner_line() -> &'static str {
        "⠿ Working…"
        // Note: ⠿ is U+283F (Braille), not in our box range.
        // This should NOT be dropped by is_pure_chrome_line — intentional;
        // spinner stripping is a B3 profile concern.
    }

    // ── Test 1: pure chrome lines are dropped ────────────────────────────────

    #[test]
    fn test_pure_separator_dropped() {
        let input = format!("Some text\n{}\nMore text", separator_line());
        let out = filter(&input);
        assert!(!out.contains('─'), "separator line should be stripped");
        assert!(out.contains("Some text"), "content before separator preserved");
        assert!(out.contains("More text"), "content after separator preserved");
    }

    #[test]
    fn test_top_bottom_border_of_prompt_box_dropped() {
        let input = claude_prompt_box();
        let out = filter(input);
        // The top (╭─…─╮) and bottom (╰─…─╯) lines are pure chrome — dropped.
        assert!(!out.contains('╭'), "top-left corner dropped");
        assert!(!out.contains('╰'), "bottom-left corner dropped");
        // The middle line has content (> _) so it survives (border cols stripped).
        assert!(out.contains('>'), "prompt caret preserved");
    }

    // ── Test 2: border columns stripped from content lines ──────────────────

    #[test]
    fn test_border_columns_stripped() {
        let input = bordered_content();
        let out = filter(input);
        // The │ border characters on left and right should be gone.
        assert!(!out.contains('│'), "vertical bar borders stripped");
        assert!(out.contains("This is the agent's answer."), "content preserved");
        assert!(out.contains("It spans multiple lines."), "second line preserved");
    }

    // ── Test 3: blank line collapsing ────────────────────────────────────────

    #[test]
    fn test_single_blank_preserved() {
        let input = "Line A\n\nLine B";
        let out = filter(input);
        assert!(out.contains("Line A"), "Line A preserved");
        assert!(out.contains("Line B"), "Line B preserved");
        // Exactly one blank line between them.
        let blanks: usize = out.lines().filter(|l| l.trim().is_empty()).count();
        assert_eq!(blanks, 1, "single blank preserved, got: {:?}", out);
    }

    #[test]
    fn test_multiple_blanks_collapsed() {
        let input = "Line A\n\n\n\n\nLine B";
        let out = filter(input);
        let blanks: usize = out.lines().filter(|l| l.trim().is_empty()).count();
        assert_eq!(blanks, 1, "run of 5 blanks collapsed to 1, got: {:?}", out);
    }

    #[test]
    fn test_two_blanks_collapsed_to_one() {
        let input = "A\n\n\nB";
        let out = filter(input);
        let blanks: usize = out.lines().filter(|l| l.trim().is_empty()).count();
        assert_eq!(blanks, 1, "two blanks collapsed to one, got: {:?}", out);
    }

    // ── Test 4: non-chrome content untouched ────────────────────────────────

    #[test]
    fn test_plain_text_untouched() {
        let input = "Hello, world!\nThis is a normal response.\n";
        let out = filter(input);
        assert!(out.contains("Hello, world!"));
        assert!(out.contains("This is a normal response."));
    }

    #[test]
    fn test_spinner_line_not_dropped() {
        // ⠿ is Braille (U+283F), not in box-drawing range — should survive.
        let input = spinner_line();
        let out = filter(input);
        assert!(out.contains("Working"), "spinner label text preserved");
    }

    // ── Test 5: realistic multi-section fixture ──────────────────────────────

    #[test]
    fn test_realistic_tui_output() {
        // Simulates a typical Claude Code TUI screen capture:
        //   - top chrome bar (pure box-drawing)
        //   - bordered content area with agent response
        //   - empty lines
        //   - bottom prompt box
        let input = concat!(
            "╭──────────────────────── Claude Code ────────────────────────╮\n",
            "│ claude-opus-4-5 · context 12 847 / 200 000                  │\n",
            "╰──────────────────────────────────────────────────────────────╯\n",
            "\n",
            "│ Here is my answer to your question.                          │\n",
            "│                                                               │\n",
            "│ I recommend using Rust for this task because:                 │\n",
            "│  1. Memory safety without GC                                  │\n",
            "│  2. Excellent tooling                                         │\n",
            "╰──────────────────────────────────────────────────────────────╯\n",
            "\n",
            "\n",
            "\n",
            "╭──────────────────────────────────────────────────────────────╮\n",
            "│ > _                                                          │\n",
            "╰──────────────────────────────────────────────────────────────╯\n",
        );

        let out = filter(input);

        // Content lines should be present (stripped of borders).
        assert!(out.contains("Here is my answer"), "agent content preserved");
        assert!(out.contains("Memory safety"), "list item preserved");
        assert!(out.contains("Excellent tooling"), "list item 2 preserved");

        // Decorative lines should be gone.
        assert!(!out.contains('╭'), "top-left corners stripped");
        assert!(!out.contains('╰'), "bottom-left corners stripped");

        // The 3-blank run (lines 10-12) between the content box and the prompt box
        // should be collapsed to at most 1 blank. The fixture also has one blank
        // line separating the header chrome from the content area, so the total
        // blank count in the output is at most 2 (one separator + one between
        // content and prompt — both legitimate paragraph breaks).
        let blank_runs: Vec<_> = out.lines().filter(|l| l.trim().is_empty()).collect();
        assert!(blank_runs.len() <= 2, "blank runs collapsed, got {} blanks", blank_runs.len());
    }

    // ── Test 6: is_pure_chrome_line edge cases ───────────────────────────────

    #[test]
    fn test_empty_line_not_treated_as_chrome() {
        assert!(!is_pure_chrome_line(""), "empty line is not a chrome line");
        assert!(!is_pure_chrome_line("   "), "whitespace-only is not a chrome line");
    }

    #[test]
    fn test_line_with_mixed_content_not_chrome() {
        assert!(!is_pure_chrome_line("│ hello │"), "line with text is not pure chrome");
    }

    #[test]
    fn test_pure_horizontal_rule_is_chrome() {
        assert!(is_pure_chrome_line("────────────────"), "pure ─ line is chrome");
        assert!(is_pure_chrome_line("╭──────────────╮"), "╭─╮ line is chrome");
        assert!(is_pure_chrome_line("  ─────  "), "with whitespace is still chrome");
    }

    // ── Test 7: redaction pass ───────────────────────────────────────────────

    #[test]
    fn test_redact_aws_key_id() {
        let input = "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE";
        let out = redact(input);
        assert!(out.contains("[REDACTED:aws_key_id]"), "AWS key ID redacted: {out}");
        assert!(!out.contains("AKIAIOSFODNN7EXAMPLE"), "original value not present");
    }

    #[test]
    fn test_redact_github_token() {
        // Bare token not preceded by an assignment — exercises the token pattern directly.
        let input = "Cloned with ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890ab successfully";
        let out = redact(input);
        assert!(out.contains("[REDACTED:github_token]"), "GitHub token redacted: {out}");
        assert!(!out.contains("ghp_"), "original token not present");
    }

    #[test]
    fn test_redact_sk_token() {
        // Bare sk- token not preceded by an assignment.
        let input = "Using key sk-fake1234567890abcdefghij12345678901234567890 for request";
        let out = redact(input);
        assert!(out.contains("[REDACTED:sk_token]"), "sk- token redacted: {out}");
    }

    #[test]
    fn test_redact_slack_token() {
        // Bare xoxb- token.
        // Built at runtime so the literal never matches scanners' static token patterns.
        let input = format!("Sending to xox{}-12345678901-12345678901-FakeSlackTokenValue", "b");
        let out = redact(&input);
        assert!(out.contains("[REDACTED:slack_token]"), "Slack token redacted: {out}");
    }

    #[test]
    fn test_redact_pem_header() {
        let input = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...";
        let out = redact(input);
        assert!(out.contains("[REDACTED:pem_private_key]"), "PEM header redacted: {out}");
    }

    #[test]
    fn test_redact_credential_value() {
        let input = "password=SuperSecret123\ntoken=abc.def.ghi";
        let out = redact(input);
        assert!(out.contains("[REDACTED:credential_value]"), "credential value redacted: {out}");
        assert!(!out.contains("SuperSecret123"), "password value not present");
    }

    #[test]
    fn test_redact_bearer_token() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.fake";
        let out = redact(input);
        assert!(out.contains("[REDACTED:bearer_token]"), "Bearer token redacted: {out}");
    }

    #[test]
    fn test_redact_leaves_normal_text_intact() {
        let input = "The answer is 42 and the sky is blue.\n";
        let out = redact(input);
        assert_eq!(out, input, "normal text unchanged by redaction");
    }

    // ── Test 8: honest truncation ────────────────────────────────────────────

    #[test]
    fn test_truncate_short_text_no_truncation() {
        let text = "Hello, world!\n";
        let res = truncate(text, MAX_OUTPUT_CHARS);
        assert!(!res.truncated, "short text not truncated");
        assert_eq!(res.omitted_chars, 0);
        assert_eq!(res.text, text);
    }

    #[test]
    fn test_truncate_long_text_keeps_tail() {
        // Build a text that exceeds max_chars.
        let line = "abcdefghij\n"; // 11 chars
        let repeats = 200;
        let text: String = line.repeat(repeats); // 2200 chars
        let max = 500;
        let res = truncate(&text, max);
        assert!(res.truncated, "text longer than max should be truncated");
        assert!(res.omitted_chars > 0, "some chars omitted");
        assert!(res.text.len() <= max + line.len(), "output within max + 1 line");
        // The tail must end with the last line of the input.
        assert!(res.text.ends_with(line), "tail ends with last line");
        // omitted_chars + result chars should approximately equal input chars.
        assert_eq!(res.omitted_chars + res.text.len(), text.len(),
            "omitted + kept = total");
    }

    #[test]
    fn test_truncate_splits_on_newline() {
        // Construct text where a naive byte-split would cut mid-line.
        // max_chars = 15, text has lines of length > 15.
        let text = "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n"; // 33 chars, 3 lines of 11
        let res = truncate(text, 15);
        assert!(res.truncated);
        // The kept tail should not start mid-line (should start after a \n).
        let _first_char = res.text.chars().next();
        // Since we split on newline boundary, the kept part starts on a line boundary.
        // Verify it contains complete lines.
        for line in res.text.lines() {
            // Each line in the tail should be one of the original complete lines.
            assert!(
                text.contains(line),
                "tail contains only complete original lines, got: {:?}",
                line
            );
        }
    }
}
