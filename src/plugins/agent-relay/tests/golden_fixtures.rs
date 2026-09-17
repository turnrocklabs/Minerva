// golden_fixtures.rs — golden-output tests for the chrome filter pipeline.
//
// Each test loads a fixture from tests/fixtures/, runs it through the filter
// pipeline (chrome_filter::filter), and asserts structural properties of the
// output. Property-based assertions are used instead of exact string snapshots
// because the fixtures are synthetic and will be replaced with real captures
// during B5 HITL; exact snapshots would be brittle.
//
// When replacing fixtures with real captures, update the assertions to match
// real expected output rather than the structural invariants below.

use std::fs;
use std::path::PathBuf;

/// Load a fixture file from tests/fixtures/<name>.
/// Lines beginning with `#` are comment/header lines (synthetic markers) and
/// are stripped before processing — they describe the fixture but are not
/// terminal output.
fn load_fixture(name: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("tests").join("fixtures").join(name);
    let raw = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Failed to read fixture '{}' at {}: {}", name, path.display(), e));
    // Strip comment header lines (lines starting with '#').
    raw.lines()
        .filter(|l| !l.starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n")
}

// Re-export the filter functions under test.
// The crate is a binary, not a library, so we pull the module in via path.
// We use #[path] to include the source directly in the test binary.
#[path = "../src/chrome_filter.rs"]
mod chrome_filter;

// ---------------------------------------------------------------------------
// Helper: count box-drawing characters in a string.
// ---------------------------------------------------------------------------

fn count_box_drawing(s: &str) -> usize {
    s.chars().filter(|&c| c >= '\u{2500}' && c <= '\u{25FF}').count()
}

fn max_consecutive_blanks(s: &str) -> usize {
    let mut max_run = 0usize;
    let mut run = 0usize;
    for line in s.lines() {
        if line.trim().is_empty() {
            run += 1;
            max_run = max_run.max(run);
        } else {
            run = 0;
        }
    }
    max_run
}

// ---------------------------------------------------------------------------
// Golden test: claude_code_tui.txt
// ---------------------------------------------------------------------------

#[test]
fn golden_claude_code_tui() {
    let raw = load_fixture("claude_code_tui.txt");
    let out = chrome_filter::filter(&raw);

    // 1. No pure chrome lines in output.
    assert!(
        count_box_drawing(&out) == 0,
        "No box-drawing characters should survive chrome filter.\n\
         Remaining box chars in output:\n{out}"
    );

    // 2. Key semantic content is preserved.
    assert!(out.contains("root cause"), "agent response text preserved (root cause)");
    assert!(out.contains("cache key"), "agent response text preserved (cache key)");
    assert!(out.contains("tenant ID"), "agent response text preserved (tenant ID)");
    assert!(out.contains("regression test"), "agent response text preserved (regression test)");

    // 3. Blank line run collapsed to at most 1.
    assert!(
        max_consecutive_blanks(&out) <= 1,
        "No blank run > 1 after filter. Output:\n{out}"
    );

    // 4. Output is non-empty.
    assert!(!out.trim().is_empty(), "output is non-empty");
}

// ---------------------------------------------------------------------------
// Golden test: codex_tui.txt
// ---------------------------------------------------------------------------

#[test]
fn golden_codex_tui() {
    let raw = load_fixture("codex_tui.txt");
    let out = chrome_filter::filter(&raw);

    // 1. No box-drawing chars survive.
    assert!(
        count_box_drawing(&out) == 0,
        "No box-drawing characters should survive. Output:\n{out}"
    );

    // 2. Semantic content preserved.
    assert!(out.contains("cache/key.ts"), "cache key file preserved");
    assert!(out.contains("tenantId"), "variable name preserved");
    assert!(out.contains("Proposed change"), "section header preserved");

    // 3. Blank runs collapsed.
    assert!(max_consecutive_blanks(&out) <= 1, "blank runs collapsed");

    // 4. Non-empty.
    assert!(!out.trim().is_empty(), "output non-empty");
}

// ---------------------------------------------------------------------------
// Golden test: opencode_tui.txt
// ---------------------------------------------------------------------------

#[test]
fn golden_opencode_tui() {
    let raw = load_fixture("opencode_tui.txt");
    let out = chrome_filter::filter(&raw);

    // 1. No box-drawing chars.
    assert!(
        count_box_drawing(&out) == 0,
        "No box-drawing characters should survive. Output:\n{out}"
    );

    // 2. Semantic content preserved.
    assert!(out.contains("pool size"), "pool size recommendation preserved");
    assert!(out.contains("200 req/s"), "load figure preserved");
    assert!(out.contains("database.yml"), "file path preserved");
    assert!(out.contains("Restart"), "step 3 preserved");

    // 3. Blank runs collapsed.
    assert!(max_consecutive_blanks(&out) <= 1, "blank runs collapsed");

    // 4. Non-empty.
    assert!(!out.trim().is_empty(), "output non-empty");
}

// ---------------------------------------------------------------------------
// Golden test: redaction applied over fixture output
// ---------------------------------------------------------------------------

#[test]
fn golden_redaction_over_claude_fixture() {
    // Build a synthetic extension of the claude fixture with an embedded secret.
    let base = load_fixture("claude_code_tui.txt");
    let with_secret = format!(
        "{base}\nexport AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\ntoken=ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890ab\n"
    );

    let filtered = chrome_filter::filter(&with_secret);
    let redacted = chrome_filter::redact(&filtered);

    // AWS key ID is standalone and not caught by credential_value — must be aws_key_id.
    assert!(
        redacted.contains("[REDACTED:aws_key_id]"),
        "AWS key ID redacted in combined fixture output. Got:\n{redacted}"
    );
    // GitHub token may be caught by github_token (index 2) OR by credential_value
    // (index 7) when the line has the form `token=ghp_...`.  Both are correct
    // redactions; we assert the raw value is gone, not the specific label.
    assert!(!redacted.contains("AKIAIOSFODNN7EXAMPLE"), "AWS key not in output");
    assert!(!redacted.contains("ghp_aBcDeFg"), "GitHub token not in output");
    // At least the AWS redaction label is present.
    assert!(redacted.contains("[REDACTED:"), "at least one REDACTED marker present");
    // Normal content still present.
    assert!(redacted.contains("root cause"), "agent content preserved after redaction");
}

// ---------------------------------------------------------------------------
// Golden test: truncation applied over a large synthetic input
// ---------------------------------------------------------------------------

#[test]
fn golden_truncation_tail_keeps_last_line() {
    // Construct input well over MAX_OUTPUT_CHARS.
    let line = "This is line content that will be repeated many times.\n";
    let repeats = (chrome_filter::MAX_OUTPUT_CHARS / line.len()) + 100;
    let big_input: String = (0..repeats)
        .map(|i| format!("Line {:04}: {}", i, line))
        .collect();

    let res = chrome_filter::truncate(&big_input, chrome_filter::MAX_OUTPUT_CHARS);
    assert!(res.truncated, "large input is truncated");
    assert!(res.omitted_chars > 0, "omitted chars reported");

    // The last line of the original input should be in the tail.
    let last_original_line = format!("Line {:04}: {}", repeats - 1, line).trim_end().to_string();
    assert!(
        res.text.contains(&last_original_line),
        "last original line present in tail. tail ends with: {:?}",
        &res.text[res.text.len().saturating_sub(100)..]
    );

    // omitted + kept = total.
    assert_eq!(
        res.omitted_chars + res.text.len(),
        big_input.len(),
        "omitted + kept = total input length"
    );
}
