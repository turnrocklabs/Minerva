// turn_extract.rs — does the extractor recover the turns the harness recorded?
//
// The corpus at tests/fixtures/loss_pairs holds eleven real turns, each with
// the harness's own records and the answer text those records carry
// (ground_truth.txt; empty when the harness recorded none, which for the two
// slash-command pairs means no log file was written at all). Every test below
// feeds those real bytes to the extractor and checks the result against the
// corpus's own ground truth, so a wrong rule cannot pass.
//
// meta.json states no turn count and no boundary. Each pair was captured as one
// prompt and its response, so the expectation is one turn per pair with records
// and none for an empty log, and the boundary is taken from the harness's own
// end markers (claude system/turn_duration or the interrupt record; codex
// task_complete or turn_aborted).
//
// The crate is a binary, so the module is pulled in by path, as the other
// test files do.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

// The crate's own turn path reaches every item here; a standalone include does not.
#[path = "../src/session_log.rs"]
#[allow(dead_code)]
mod session_log;
#[path = "../src/turn_extract.rs"]
#[allow(dead_code)]
mod turn_extract;

use turn_extract::{extract, Cursor, Harness, Turn, TurnEnd};

// ---------------------------------------------------------------------------
// Corpus access
// ---------------------------------------------------------------------------

/// One corpus pair reduced to what the extractor's caller would know, plus the
/// ground truth to judge it by.
struct Pair {
    id: String,
    harness: Harness,
    log: Vec<u8>,
    /// Prompt as submitted, with the corpus's own "(Esc at +Ns)" annotation
    /// removed — that suffix records operator timing, it was never typed.
    prompt: String,
    /// The answer text the harness recorded, byte for byte.
    ground_truth: String,
    interrupted: bool,
}

fn corpus_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/loss_pairs")
}

fn load_pairs() -> Vec<Pair> {
    let mut pairs = Vec::new();
    for (name, harness) in [("claude", Harness::Claude), ("codex", Harness::Codex)] {
        let mut dirs: Vec<PathBuf> = fs::read_dir(corpus_root().join(name))
            .expect("corpus harness directory")
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.is_dir())
            .collect();
        dirs.sort();
        for dir in dirs {
            let meta: serde_json::Value =
                serde_json::from_slice(&fs::read(dir.join("meta.json")).expect("meta.json"))
                    .expect("meta.json parses");
            let prompt = meta["prompt"].as_str().unwrap_or_default();
            let prompt = match prompt.find("  (Esc at +") {
                Some(at) => &prompt[..at],
                None => prompt,
            };
            pairs.push(Pair {
                id: format!("{name}/{}", dir.file_name().unwrap().to_string_lossy()),
                harness,
                log: fs::read(dir.join("session_log.jsonl")).expect("session_log.jsonl"),
                prompt: prompt.to_string(),
                ground_truth: fs::read_to_string(dir.join("ground_truth.txt"))
                    .expect("ground_truth.txt"),
                interrupted: meta["interrupted_or_aborted"].as_bool().unwrap_or(false),
            });
        }
    }
    assert_eq!(pairs.len(), 11, "corpus size changed");
    pairs
}

// ---------------------------------------------------------------------------
// Scratch files
// ---------------------------------------------------------------------------

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A throwaway log file that can be appended to between extractions.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Scratch {
        let path = std::env::temp_dir().join(format!(
            "agent-relay-turns-{}-{}-{}.jsonl",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
            tag.replace('/', "-"),
        ));
        let _ = fs::remove_file(&path);
        fs::write(&path, b"").unwrap();
        Scratch(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn append(&self, bytes: &[u8]) {
        let mut existing = fs::read(&self.0).unwrap();
        existing.extend_from_slice(bytes);
        fs::write(&self.0, existing).unwrap();
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

/// Every turn in a file, read in one pass from the start.
fn turns_of(path: &Path, harness: Harness) -> Vec<Turn> {
    extract(path, harness, Cursor::start())
        .expect("extraction reads the file")
        .turns
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The corpus oracle: prompt, answer, end state and turn count for all eleven
/// real turns, against the ground truth recorded beside each log.
#[test]
fn corpus_turns_match_recorded_ground_truth() {
    for pair in load_pairs() {
        let scratch = Scratch::new(&pair.id);
        scratch.append(&pair.log);
        let turns = turns_of(scratch.path(), pair.harness);

        if pair.log.is_empty() {
            // A session whose only activity was a local slash command left no
            // records at all, so there is nothing to extract.
            assert!(turns.is_empty(), "{}: expected no turns", pair.id);
            continue;
        }

        assert_eq!(turns.len(), 1, "{}: one prompt, one turn", pair.id);
        let turn = &turns[0];
        assert_eq!(
            turn.prompt.trim(),
            pair.prompt.trim(),
            "{}: prompt",
            pair.id
        );
        assert_eq!(turn.answer, pair.ground_truth, "{}: answer", pair.id);
        let expected_end = if pair.interrupted {
            TurnEnd::Interrupted
        } else {
            TurnEnd::Normal
        };
        assert_eq!(turn.end, expected_end, "{}: end state", pair.id);
    }
}

/// Codex records no partial answer for a turn it aborted; claude does. Both
/// still come out marked interrupted.
#[test]
fn interrupted_turns_keep_the_text_their_harness_recorded() {
    let pairs = load_pairs();
    let find = |id: &str| {
        let pair = pairs.iter().find(|pair| pair.id == id).expect("pair");
        let scratch = Scratch::new(id);
        scratch.append(&pair.log);
        let turns = turns_of(scratch.path(), pair.harness);
        assert_eq!(turns.len(), 1, "{id}: one turn");
        turns.into_iter().next().unwrap()
    };

    let claude = find("claude/05_interrupted");
    assert_eq!(claude.end, TurnEnd::Interrupted);
    assert!(
        claude.answer.starts_with("# The Glass Teletype"),
        "claude keeps the partial answer: {:?}",
        &claude.answer[..claude.answer.len().min(60)]
    );

    let codex = find("codex/04_interrupted");
    assert_eq!(codex.end, TurnEnd::Interrupted);
    assert!(
        codex.answer.is_empty(),
        "codex records no partial answer: {:?}",
        codex.answer
    );
}

/// Appending the log in pieces, including pieces that cut a record in half,
/// yields exactly the turns of a single pass and never emits one twice.
#[test]
fn chunked_appends_match_a_single_pass() {
    for pair in load_pairs() {
        if pair.log.is_empty() {
            continue;
        }
        let whole = Scratch::new(&pair.id);
        whole.append(&pair.log);
        let expected = turns_of(whole.path(), pair.harness);

        // Strides chosen to land mid-record: the smallest splits every record,
        // the largest lands inside one of the long answer records.
        for stride in [3usize, 7, 97, 613] {
            let scratch = Scratch::new(&pair.id);
            let mut cursor = Cursor::start();
            let mut collected: Vec<Turn> = Vec::new();
            for chunk in pair.log.chunks(stride) {
                scratch.append(chunk);
                let step = extract(scratch.path(), pair.harness, cursor)
                    .expect("extraction reads the growing file");
                collected.extend(step.turns);
                assert!(
                    step.cursor.offset >= cursor.offset,
                    "{}: cursor went backwards at stride {stride}",
                    pair.id
                );
                cursor = step.cursor;
            }
            assert_eq!(
                collected, expected,
                "{}: stride {stride} disagrees with one pass",
                pair.id
            );
        }
    }
}

/// A half-written last line yields the previous complete turn, and the cursor
/// left behind picks that record up once the rest of it lands.
#[test]
fn a_truncated_last_line_defers_rather_than_fails() {
    for pair in load_pairs() {
        if pair.log.is_empty() {
            continue;
        }
        let complete = Scratch::new(&pair.id);
        complete.append(&pair.log);
        let expected = turns_of(complete.path(), pair.harness);

        // Cut the final record in half: the turn it completes must not appear
        // until its closing bytes arrive.
        let last_start = pair.log[..pair.log.len() - 1]
            .iter()
            .rposition(|byte| *byte == b'\n')
            .map(|at| at + 1)
            .unwrap_or(0);
        let half = last_start + (pair.log.len() - last_start) / 2;

        let scratch = Scratch::new(&pair.id);
        scratch.append(&pair.log[..half]);
        let partial = extract(scratch.path(), pair.harness, Cursor::start())
            .expect("a truncated tail is not an error");
        assert!(
            expected.starts_with(&partial.turns),
            "{}: truncated read invented a turn",
            pair.id
        );

        scratch.append(&pair.log[half..]);
        let rest = extract(scratch.path(), pair.harness, partial.cursor)
            .expect("the completed record is readable");
        let mut collected = partial.turns;
        collected.extend(rest.turns);
        assert_eq!(collected, expected, "{}: deferred turn was lost", pair.id);
    }
}

/// Records of unknown type and lines that are not JSON at all are skipped, and
/// the turns around them are unaffected.
#[test]
fn unknown_and_corrupt_records_are_skipped() {
    let noise: &[&[u8]] = &[
        b"{\"type\":\"cost-state\",\"total\":3}\n",
        b"{\"type\":\"file-history-snapshot\"}\n",
        b"{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n",
        b"{\"type\":\"user\",\"message\":{}\n", // unbalanced: not JSON
        b"\n",
        b"not json at all\n",
    ];

    for pair in load_pairs() {
        if pair.log.is_empty() {
            continue;
        }
        let clean = Scratch::new(&pair.id);
        clean.append(&pair.log);
        let expected = turns_of(clean.path(), pair.harness);

        // Interleave the noise between every pair of real records.
        let mut polluted: Vec<u8> = Vec::new();
        for (index, line) in pair.log.split_inclusive(|byte| *byte == b'\n').enumerate() {
            polluted.extend_from_slice(noise[index % noise.len()]);
            polluted.extend_from_slice(line);
        }
        polluted.extend_from_slice(noise[0]);

        let scratch = Scratch::new(&pair.id);
        scratch.append(&polluted);
        assert_eq!(
            turns_of(scratch.path(), pair.harness),
            expected,
            "{}: noise changed the turns",
            pair.id
        );
    }
}

/// A local slash command and its output become a turn carrying both.
///
/// No corpus pair can exercise this: both slash-command sessions wrote no log
/// file. The records below are in the shape measured from live Claude Code
/// transcripts, where the harness files a command either as a user record or as
/// a system/local_command record with the same tags.
#[test]
fn slash_commands_carry_their_output() {
    let log = concat!(
        r#"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args></command-args>"}}"#,
        "\n",
        r#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to Fable 5.1</local-command-stdout>"}}"#,
        "\n",
        r#"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>ignore me</local-command-caveat>"}}"#,
        "\n",
        r#"{"type":"system","subtype":"local_command","content":"<command-name>/cost</command-name>\n            <command-message>cost</command-message>\n            <command-args>--verbose</command-args>"}"#,
        "\n",
        r#"{"type":"system","subtype":"local_command","content":"<local-command-stdout>Total cost: $1.23</local-command-stdout>"}"#,
        "\n",
        r#"{"type":"user","message":{"role":"user","content":"what did that cost"}}"#,
        "\n",
        r#"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"A dollar and change."}]}}"#,
        "\n",
        r#"{"type":"system","subtype":"turn_duration","durationMs":42}"#,
        "\n",
    );

    let scratch = Scratch::new("slash");
    scratch.append(log.as_bytes());
    let turns = turns_of(scratch.path(), Harness::Claude);

    assert_eq!(turns.len(), 3, "two command turns and one prompt turn");

    assert_eq!(turns[0].prompt, "/model");
    assert_eq!(turns[0].slash_commands.len(), 1);
    assert_eq!(turns[0].slash_commands[0].name, "/model");
    assert_eq!(turns[0].slash_commands[0].args, "");
    assert_eq!(turns[0].slash_commands[0].stdout, "Set model to Fable 5.1");
    assert!(turns[0].answer.is_empty());

    assert_eq!(turns[1].prompt, "/cost --verbose");
    assert_eq!(turns[1].slash_commands[0].stdout, "Total cost: $1.23");

    assert_eq!(turns[2].prompt, "what did that cost");
    assert_eq!(turns[2].answer, "A dollar and change.");
    assert_eq!(turns[2].end, TurnEnd::Normal);
    assert!(turns[2].slash_commands.is_empty());
}

/// A turn whose text outgrows MAX_TURN_BYTES is dropped whole rather than
/// truncated, and its own closing record resynchronises the extractor: the turn
/// after an over-cap one comes out intact.
#[test]
fn an_over_cap_turn_is_dropped_and_the_next_turn_still_arrives() {
    let log = format!(
        "{}{}{}{}{}{}",
        claude_user("the runaway one"),
        claude_assistant(&"x".repeat(turn_extract::MAX_TURN_BYTES + 1)),
        claude_turn_close(),
        claude_user("the ordinary one"),
        claude_assistant("a short answer"),
        claude_turn_close(),
    );

    let scratch = Scratch::new("over-cap");
    scratch.append(log.as_bytes());
    let turns = turns_of(scratch.path(), Harness::Claude);

    assert_eq!(turns.len(), 1, "only the turn inside the cap is extracted");
    assert_eq!(turns[0].prompt, "the ordinary one");
    assert_eq!(turns[0].answer, "a short answer");
    assert_eq!(turns[0].end, TurnEnd::Normal);
}

/// A fresh bind on a transcript whose FIRST line is the record that opens the
/// turn. The tail window is the whole file while the file is smaller than the
/// budget, so the cursor it yields must name offset 0 and leave that first
/// record to be read.
#[test]
fn a_fresh_bind_reads_a_transcript_that_opens_on_its_first_record() {
    let log = concat!(
        r#"{"type":"user","cwd":"/scratch","timestamp":"2026-09-18T10:00:00.000Z","#,
        r#""message":{"role":"user","content":"ping"}}"#,
        "\n",
        r#"{"type":"assistant","timestamp":"2026-09-18T10:00:01.000Z","message":"#,
        r#"{"role":"assistant","content":[{"type":"text","text":"pong"}]}}"#,
        "\n",
        r#"{"type":"system","subtype":"turn_duration","timestamp":"2026-09-18T10:00:01.100Z"}"#,
        "\n",
    );
    let scratch = Scratch::new("fresh-bind");
    scratch.append(log.as_bytes());

    let cursor = turn_extract::tail_cursor(scratch.path());
    assert_eq!(
        cursor.offset, 0,
        "a file inside the budget opens at its start"
    );

    let turns = extract(scratch.path(), Harness::Claude, cursor)
        .expect("extraction reads the file")
        .turns;
    assert_eq!(turns.len(), 1, "the first record opened a turn");
    assert_eq!(turns[0].prompt, "ping");
    assert_eq!(turns[0].answer, "pong");
}

// ---------------------------------------------------------------------------
// Claude record shapes
// ---------------------------------------------------------------------------

fn line(record: serde_json::Value) -> String {
    record.to_string() + "\n"
}

fn claude_user(text: &str) -> String {
    line(serde_json::json!({
        "type": "user",
        "timestamp": "2026-09-18T10:00:00.000Z",
        "message": {"role": "user", "content": text},
    }))
}

fn claude_assistant(text: &str) -> String {
    line(serde_json::json!({
        "type": "assistant",
        "timestamp": "2026-09-18T10:00:01.000Z",
        "message": {"role": "assistant", "content": [{"type": "text", "text": text}]},
    }))
}

fn claude_turn_close() -> String {
    line(serde_json::json!({"type": "system", "subtype": "turn_duration"}))
}

/// A user record whose content is a one-element text block, the shape the
/// harness writes its interrupt markers in.
fn claude_user_block(text: &str) -> String {
    line(serde_json::json!({
        "type": "user",
        "timestamp": "2026-09-18T10:00:02.000Z",
        "message": {"role": "user", "content": [{"type": "text", "text": text}]},
    }))
}

/// The record an automatic compaction writes: a user record carrying the
/// summary as plain string content, flagged and nothing else.
fn claude_compact_summary(text: &str) -> String {
    line(serde_json::json!({
        "type": "user",
        "isCompactSummary": true,
        "timestamp": "2026-09-18T10:00:02.000Z",
        "message": {"role": "user", "content": text},
    }))
}

/// Both interrupt markers the harness writes — the bare one and the "for tool
/// use" variant a denied permission leaves — close the open turn with the
/// partial answer it holds. Neither opens a turn of its own, which would drop
/// the answered turn ahead of it.
#[test]
fn either_interrupt_marker_closes_the_open_turn() {
    for marker in [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ] {
        let log = format!(
            "{}{}{}",
            claude_user("the interrupted one"),
            claude_assistant("half an answer"),
            claude_user_block(marker),
        );
        let scratch = Scratch::new("interrupt");
        scratch.append(log.as_bytes());
        let turns = turns_of(scratch.path(), Harness::Claude);

        assert_eq!(turns.len(), 1, "{marker}: one turn, no bogus second one");
        assert_eq!(turns[0].prompt, "the interrupted one", "{marker}: prompt");
        assert_eq!(
            turns[0].answer, "half an answer",
            "{marker}: partial answer"
        );
        assert_eq!(turns[0].end, TurnEnd::Interrupted, "{marker}: end state");
    }
}

/// An automatic compaction lands mid-turn. Its summary record is a user record
/// carrying plain prose — not isMeta, not tag-wrapped — so only its own flag
/// keeps it from posing as a new prompt and taking the answer still to come.
#[test]
fn a_compaction_summary_leaves_the_live_turn_running() {
    let log = format!(
        "{}{}{}{}{}",
        claude_user("the real prompt"),
        claude_assistant("first half"),
        claude_compact_summary("This session is being continued from a previous conversation..."),
        claude_assistant("second half"),
        claude_turn_close(),
    );

    let scratch = Scratch::new("compact-summary");
    scratch.append(log.as_bytes());
    let turns = turns_of(scratch.path(), Harness::Claude);

    assert_eq!(turns.len(), 1, "the summary opened no turn");
    assert_eq!(turns[0].prompt, "the real prompt");
    assert_eq!(turns[0].answer, "first half\n\nsecond half");
    assert_eq!(turns[0].end, TurnEnd::Normal);
}

/// One extraction reads the length it captured and nothing past it, so a
/// harness still appending cannot stretch the span MAX_SPAN_BYTES was measured
/// against. A file already longer than the length handed in is exactly what
/// such an append leaves behind.
#[test]
fn an_extraction_never_reads_past_the_length_it_captured() {
    let first = format!(
        "{}{}{}",
        claude_user("the first one"),
        claude_assistant("an answer"),
        claude_turn_close(),
    );
    let second = format!(
        "{}{}{}",
        claude_user("the second one"),
        claude_assistant("another answer"),
        claude_turn_close(),
    );
    let scratch = Scratch::new("captured-length");
    scratch.append(format!("{first}{second}").as_bytes());
    let captured = first.len() as u64;

    let step =
        turn_extract::extract_within(scratch.path(), Harness::Claude, Cursor::start(), captured)
            .expect("extraction reads the file");
    assert_eq!(
        step.turns.len(),
        1,
        "only the turns inside the captured length are delivered"
    );
    assert_eq!(step.turns[0].prompt, "the first one");
    assert_eq!(
        step.cursor.offset, captured,
        "the cursor stops at the captured length"
    );

    // A length landing mid-record: those bytes are half a record, so they are
    // neither parsed nor committed, and the next call re-reads them whole.
    let cut = captured + 40;
    let mid = turn_extract::extract_within(scratch.path(), Harness::Claude, Cursor::start(), cut)
        .expect("a length cutting a record is not an error");
    assert_eq!(mid.turns, step.turns, "a cut record invented no turn");
    assert_eq!(mid.cursor.offset, captured, "the cut record is left unread");

    assert_eq!(
        turns_of(scratch.path(), Harness::Claude).len(),
        2,
        "the same file read at its real length holds both turns"
    );
}

/// At least `bytes` of records the extractor steps over, so that only their
/// size matters to the windows under test.
fn filler_lines(bytes: usize) -> String {
    let record = line(serde_json::json!({
        "type": "system",
        "subtype": "filler",
        "timestamp": "2026-09-18T09:00:00.000Z",
        "filler": "x".repeat(4_096),
    }));
    record.repeat(bytes / record.len() + 1)
}

/// A span over MAX_SPAN_BYTES falls back to the tail window, and that window is
/// aligned against the length the call captured. A harness appending while the
/// call runs would otherwise move the window past that length, and the read
/// would open inside a record whose opening bytes are then gone for good.
#[test]
fn a_skipped_span_aligns_its_tail_window_on_the_captured_length() {
    let turn = format!(
        "{}{}{}",
        claude_user("the tail turn"),
        claude_assistant("the tail answer"),
        claude_turn_close(),
    );
    let scratch = Scratch::new("skipped-span");
    scratch.append(
        format!(
            "{}{turn}",
            filler_lines(turn_extract::MAX_SPAN_BYTES as usize + 64 * 1024)
        )
        .as_bytes(),
    );
    let captured = fs::metadata(scratch.path()).unwrap().len();

    // The append a harness makes between the capture and the read, large
    // enough that the live tail window would open past the captured length.
    scratch
        .append(filler_lines(turn_extract::FRESH_BIND_TAIL_BYTES as usize + 64 * 1024).as_bytes());
    let grown = fs::metadata(scratch.path()).unwrap().len();

    let step =
        turn_extract::extract_within(scratch.path(), Harness::Claude, Cursor::start(), captured)
            .expect("extraction reads the file");
    assert!(step.skipped, "the span was over budget");
    assert_eq!(
        step.turns.len(),
        1,
        "the turn inside the tail window arrived"
    );
    assert_eq!(step.turns[0].prompt, "the tail turn");
    assert_eq!(step.turns[0].answer, "the tail answer");
    assert_eq!(
        step.cursor.offset, captured,
        "the cursor stops on the record boundary the captured length names"
    );

    // Resuming from that cursor reads the appended records as whole records:
    // a window opened mid-record would have left the first of them unparseable.
    let next = turn_extract::extract_within(scratch.path(), Harness::Claude, step.cursor, grown)
        .expect("the appended span reads too");
    assert!(next.turns.is_empty(), "the appended records close no turn");
    assert_eq!(next.cursor.offset, grown, "every appended record was whole");
}

/// A turn the harness never closed must not swallow the turn behind it. Both
/// shapes of "never closed" resynchronise on the next prompt: one that outgrew
/// MAX_TURN_BYTES and lost its closing record with the harness, and an ordinary
/// one simply left open. Neither is emitted with the answer it had.
#[test]
fn an_unclosed_turn_gives_way_to_the_next_prompt() {
    let ordinary = format!(
        "{}{}{}",
        claude_user("the ordinary one"),
        claude_assistant("a short answer"),
        claude_turn_close(),
    );

    let unclosed: [(&str, String); 2] = [
        (
            "over-cap",
            format!(
                "{}{}",
                claude_user("the runaway one"),
                claude_assistant(&"x".repeat(turn_extract::MAX_TURN_BYTES + 1)),
            ),
        ),
        (
            "unterminated",
            format!(
                "{}{}",
                claude_user("the abandoned one"),
                claude_assistant("half an answer"),
            ),
        ),
    ];

    for (label, head) in unclosed {
        let scratch = Scratch::new(label);
        scratch.append(format!("{head}{ordinary}").as_bytes());
        let turns = turns_of(scratch.path(), Harness::Claude);
        assert_eq!(turns.len(), 1, "{label}: only the completed turn survives");
        assert_eq!(turns[0].prompt, "the ordinary one", "{label}: prompt");
        assert_eq!(turns[0].answer, "a short answer", "{label}: answer");
        assert_eq!(turns[0].end, TurnEnd::Normal, "{label}: end state");
    }
}

/// The codex equivalent: task_started opens a fresh turn whatever came before,
/// so a turn whose task_complete never arrived is dropped rather than carried
/// into the next one.
#[test]
fn a_codex_turn_without_task_complete_gives_way_to_the_next_task_started() {
    let started = || {
        line(serde_json::json!({
            "type": "event_msg",
            "timestamp": "2026-09-18T10:00:00.000Z",
            "payload": {"type": "task_started"},
        }))
    };
    let message = |role: &str, kind: &str, text: &str| {
        line(serde_json::json!({
            "type": "response_item",
            "timestamp": "2026-09-18T10:00:01.000Z",
            "payload": {"type": "message", "role": role,
                        "content": [{"type": kind, "text": text}]},
        }))
    };
    let complete = |stated: &str| {
        line(serde_json::json!({
            "type": "event_msg",
            "timestamp": "2026-09-18T10:00:02.000Z",
            "payload": {"type": "task_complete", "last_agent_message": stated},
        }))
    };

    let log = format!(
        "{}{}{}{}{}{}{}",
        started(),
        message("user", "input_text", "the abandoned one"),
        message("assistant", "output_text", "half an answer"),
        started(),
        message("user", "input_text", "the ordinary one"),
        message("assistant", "output_text", "a short answer"),
        complete("a short answer"),
    );

    let scratch = Scratch::new("codex-unclosed");
    scratch.append(log.as_bytes());
    let turns = turns_of(scratch.path(), Harness::Codex);
    assert_eq!(turns.len(), 1, "only the completed turn survives");
    assert_eq!(turns[0].prompt, "the ordinary one");
    assert_eq!(turns[0].answer, "a short answer");
}
