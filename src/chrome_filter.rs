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
}
