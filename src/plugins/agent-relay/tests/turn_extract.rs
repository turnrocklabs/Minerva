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

#[path = "../src/turn_extract.rs"]
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
