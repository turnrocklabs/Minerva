// answer_backfill_tests.rs — the tests of answer_backfill.rs, which declares
// this file as its `tests` module. Everything here reaches the matcher's
// private items through `super`.

use super::*;
use crate::turn_extract::TurnEnd;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};

/// The instant the matching tests treat as the relay's submit time.
const SUBMIT_MS: i64 = 1_700_000_000_000;

/// A log turn the harness opened right after the submit, which is what a
/// turn the relay actually drove looks like.
fn turn(prompt: &str, answer: &str) -> Turn {
    turn_at(prompt, answer, SUBMIT_MS + 1_000)
}

fn turn_at(prompt: &str, answer: &str, start_ms: i64) -> Turn {
    Turn {
        prompt: prompt.to_string(),
        answer: answer.to_string(),
        start_ms,
        end: TurnEnd::Normal,
        slash_commands: Vec::new(),
    }
}

/// A screen turn submitted at SUBMIT_MS, read off the cached cursor.
fn cand<'a>(prompt: &'a str, scraped: &'a str) -> Candidate<'a> {
    Candidate {
        prompt,
        scraped,
        submitted_ms: SUBMIT_MS,
        rebound: false,
    }
}

/// Every way a log turn can fail to stand in for the screen, and the two
/// ways it can succeed without containment.
#[test]
fn matching_rules_decide_which_turns_may_stand_in() {
    let answered = vec![turn(
        "describe a pty",
        "A pseudo-terminal pairs two virtual devices.",
    )];
    let screen = "A pseudo-terminal pairs two virtual devices.";

    assert_eq!(
        choose(&cand("a prompt nobody sent", screen), &answered),
        None,
        "a prompt that names no turn backfills nothing"
    );
    assert_eq!(
        choose(
            &cand("describe a pty", screen),
            &[turn("describe a pty", "")]
        ),
        None,
        "a turn the harness recorded no answer for keeps the screen text"
    );
    assert_eq!(
        choose(
            &cand(
                "describe a pty",
                "Shipping containers, freight rates, harbours."
            ),
            &answered
        ),
        None,
        "a log answer sharing no words with the screen is not this turn"
    );
    assert_eq!(
        choose(&cand("describe a pty", "PONG"), &answered).as_deref(),
        Some("A pseudo-terminal pairs two virtual devices."),
        "a scrape too short to cross-check rides on the prompt match"
    );
    assert_eq!(
        choose(
            &Candidate {
                rebound: true,
                ..cand("describe a pty", "PONG")
            },
            &answered
        ),
        None,
        "after a rebind the cursor vouches for nothing, so a short scrape \
             may not ride on the prompt alone"
    );
    assert_eq!(
        choose(
            &cand(
                "describe a pty",
                "> A pseudo-terminal pairs two virtual devices."
            ),
            &answered
        )
        .as_deref(),
        Some("A pseudo-terminal pairs two virtual devices."),
        "normalised containment"
    );
    assert_eq!(
        choose(
            &cand(
                "describe a pty",
                "A pseudo-terminal pairs two\nRan 1 shell command\nvirtual devices."
            ),
            &answered,
        )
        .as_deref(),
        Some("A pseudo-terminal pairs two virtual devices."),
        "chrome interleaved in the answer is covered by word coverage"
    );

    let repeated = vec![turn("ping", "first"), turn("ping", "second")];
    assert_eq!(
        choose(&cand("ping", "PONG"), &repeated).as_deref(),
        Some("second"),
        "the most recent turn for a repeated prompt"
    );
}

/// Temporal evidence is required, and it is required from BOTH sides: the
/// window admits the turn the relay drove and nothing else, and a missing
/// stamp on either side leaves the screen text in place.
#[test]
fn a_turn_qualifies_only_inside_the_submit_window() {
    let at = |start_ms: i64| vec![turn_at("ping", "first", start_ms)];
    let screen = cand("ping", "PONG");

    assert_eq!(
        choose(&screen, &at(SUBMIT_MS)).as_deref(),
        Some("first"),
        "a turn opening at the submit instant is this turn"
    );
    assert_eq!(
        choose(
            &screen,
            &at(SUBMIT_MS - session_log::SUBMIT_WINDOW_EARLY_MS)
        )
        .as_deref(),
        Some("first"),
        "a harness clock running slightly ahead of ours still matches"
    );
    assert_eq!(
        choose(&screen, &at(SUBMIT_MS + session_log::SUBMIT_WINDOW_LATE_MS)).as_deref(),
        Some("first"),
        "a write delayed to the edge of the window still matches"
    );
    assert_eq!(
        choose(
            &screen,
            &at(SUBMIT_MS - session_log::SUBMIT_WINDOW_EARLY_MS - 1)
        ),
        None,
        "a turn that opened before this prompt was submitted is another turn"
    );
    assert_eq!(
        choose(
            &screen,
            &at(SUBMIT_MS + session_log::SUBMIT_WINDOW_LATE_MS + 1)
        ),
        None,
        "a turn opening long after the submit is a later turn, not ours"
    );
    assert_eq!(
        choose(&screen, &at(0)),
        None,
        "an unstamped opening record is no evidence, so the screen stands"
    );
    assert_eq!(
        choose(
            &Candidate {
                submitted_ms: 0,
                ..cand("ping", "PONG")
            },
            &at(SUBMIT_MS),
        ),
        None,
        "a prompt from a state file with no submit time cannot be placed in \
             time, so the screen stands"
    );
}

#[test]
fn normalise_collapses_markup_to_words() {
    assert_eq!(
        normalise("## What a **PTY** is\n\n- one\n"),
        "what a pty is one"
    );
    assert!(contains_words("what a pty is one", "pty is"));
    assert!(
        !contains_words("whatapty", "pty"),
        "a needle inside a longer word is not containment"
    );
    assert_eq!(word_coverage("a b c d", "d c b"), 0.75);
    assert_eq!(word_coverage("", "anything"), 0.0);
}

// -----------------------------------------------------------------------
// Paired loss corpus
// -----------------------------------------------------------------------

/// A scratch harness-log tree, removed when the test drops it.
struct TempTree(PathBuf);

impl TempTree {
    fn new() -> TempTree {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "agent-relay-backfill-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst),
        ));
        fs::create_dir_all(&dir).expect("scratch tree");
        TempTree(dir)
    }

    fn roots(&self) -> LogRoots {
        LogRoots {
            claude_projects: self.0.join("claude/projects"),
            codex_sessions: self.0.join("codex/sessions"),
        }
    }

    /// Put a pair's transcript where that harness's binder looks for it.
    /// An empty fixture is a session the harness wrote no file for, so
    /// nothing is planted.
    fn plant(&self, pair: &Pair) {
        if pair.log.trim().is_empty() {
            return;
        }
        let roots = self.roots();
        let dir = match pair.harness.as_str() {
            "claude" => roots
                .claude_projects
                .join(session_log::claude_project_slug(Path::new(&pair.cwd))),
            // Rollouts live under the date the session started; any day
            // directory is in range for a terminal that is still alive.
            _ => roots.codex_sessions.join(pair.log_day.replace('-', "/")),
        };
        fs::create_dir_all(&dir).expect("log directory");
        let name = match pair.harness.as_str() {
            "claude" => "session.jsonl".to_string(),
            _ => format!("rollout-{}.jsonl", pair.log_day),
        };
        fs::write(dir.join(name), &pair.log).expect("plant transcript");
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Pair {
    name: String,
    harness: String,
    prompt: String,
    cwd: String,
    /// Date directory the rollout belongs in, from its first record.
    log_day: String,
    /// Stamp on the record that opens the turn, which in every corpus
    /// transcript is its first record. 0 when no log was written.
    opened_ms: i64,
    log: String,
    screen: String,
    ground_truth: String,
    loss_classes: Vec<String>,
}

impl Pair {
    fn facts(&self) -> SessionFacts {
        let mut facts = SessionFacts {
            cwd: Some(self.cwd.clone()),
            ..Default::default()
        };
        // The corpus is the harness's side of one turn; the relay's own
        // submit instant is nowhere in it. The harness stamps the record
        // that opens a turn from its own clock within a second or two of
        // the Enter, so that stamp is the submit instant to restate here.
        facts.record_prompt(&self.prompt, self.opened_ms);
        facts
    }

    /// What the cleaning pipeline hands the backfill step: chrome filter
    /// with no named rules installed, which is a fresh worker's state.
    fn scraped(&self) -> String {
        crate::chrome_filter::filter(&self.screen)
    }
}

fn corpus_pairs() -> Vec<Pair> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/loss_pairs");
    let mut dirs: Vec<PathBuf> = ["claude", "codex"]
        .iter()
        .flat_map(|h| fs::read_dir(root.join(h)).expect("corpus harness dir"))
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();
    assert!(!dirs.is_empty(), "corpus present at {}", root.display());

    dirs.iter()
        .map(|dir| {
            let read = |name: &str| fs::read_to_string(dir.join(name)).expect(name);
            let meta: Value = serde_json::from_str(&read("meta.json")).expect("meta.json");
            let log = read("session_log.jsonl");
            let first: Value = log
                .lines()
                .find(|l| !l.trim().is_empty())
                .and_then(|l| serde_json::from_str(l).ok())
                .unwrap_or(Value::Null);
            Pair {
                name: format!(
                    "{}/{}",
                    meta["harness"].as_str().unwrap_or(""),
                    meta["pair"].as_str().unwrap_or(""),
                ),
                harness: meta["harness"].as_str().unwrap_or("").to_string(),
                // The corpus annotates an interrupted pair's prompt with
                // the operator's Esc timing, which was never typed.
                prompt: strip_operator_note(meta["prompt"].as_str().unwrap_or("")),
                cwd: first["cwd"].as_str().unwrap_or("/nonexistent").to_string(),
                log_day: first["timestamp"]
                    .as_str()
                    .and_then(|ts| ts.split('T').next())
                    .unwrap_or("1970-01-01")
                    .to_string(),
                opened_ms: first["timestamp"]
                    .as_str()
                    .and_then(session_log::parse_iso_ms)
                    .unwrap_or(0),
                log,
                screen: read("screen.txt"),
                ground_truth: read("ground_truth.txt"),
                loss_classes: meta["loss_classes_present"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect()
                    })
                    .unwrap_or_default(),
            }
        })
        .collect()
}

fn strip_operator_note(prompt: &str) -> String {
    match prompt.rfind("  (Esc at +") {
        Some(at) if prompt.ends_with("s)") => prompt[..at].to_string(),
        _ => prompt.to_string(),
    }
}

/// Screen-loss the log repairs. A pair carrying any of these and holding a
/// recorded answer must deliver that answer, not the scrape.
const REPAIRABLE: &[&str] = &[
    "markdown_source_lost",
    "chrome_interleaved_in_answer",
    "completion_glyph_status_line",
    "viewport_ceiling_no_scrollback",
    "tool_output_elided",
    "truncation_30k",
];

/// The whole measured corpus through the real binder, extractor and
/// matcher: a recorded answer replaces the scrape, and everything else
/// leaves the scrape alone.
#[test]
fn corpus_delivers_the_recorded_answer_or_keeps_the_screen() {
    // The trailing status line both harnesses leave on a finished screen.
    let glyph = regex::Regex::new("(?:\u{273b}|done [0-9]{1,2}:[0-9]{2} [AP]M)").expect("glyph");

    for pair in corpus_pairs() {
        let tree = TempTree::new();
        tree.plant(&pair);
        let scraped = pair.scraped();
        let mut binding = LogBinding::default();
        let delivered = backfill(
            &pair.harness,
            &pair.facts(),
            &tree.roots(),
            &mut binding,
            &pair.prompt,
            &scraped,
        );

        if pair.ground_truth.is_empty() {
            assert_eq!(
                delivered, None,
                "{}: no recorded answer, so the screen stays",
                pair.name
            );
            continue;
        }

        assert_eq!(
            delivered.as_deref(),
            Some(pair.ground_truth.as_str()),
            "{}: the harness's own answer is delivered",
            pair.name
        );
        let repaired = pair
            .loss_classes
            .iter()
            .any(|c| REPAIRABLE.contains(&c.as_str()));
        assert!(
            repaired,
            "{}: corpus pair lost nothing worth repairing",
            pair.name
        );
        assert!(
            !glyph.is_match(&delivered.unwrap()),
            "{}: the completion-glyph status line is gone",
            pair.name
        );

        // An empty tree is the pre-backfill pipeline: the scrape stands.
        let bare = TempTree::new();
        let mut unbound = LogBinding::default();
        assert_eq!(
            backfill(
                &pair.harness,
                &pair.facts(),
                &bare.roots(),
                &mut unbound,
                &pair.prompt,
                &scraped,
            ),
            None,
            "{}: no log, no backfill",
            pair.name
        );
    }
}

/// A bound path costs no further searches, and a search is not repeated
/// without end for a terminal whose harness writes no log.
#[test]
fn binding_is_cached_and_fruitless_searches_are_capped() {
    let pairs = corpus_pairs();
    let pair = pairs
        .iter()
        .find(|p| p.name == "claude/01_short_answer")
        .expect("corpus pair");
    let tree = TempTree::new();
    tree.plant(pair);
    let scraped = pair.scraped();

    let mut binding = LogBinding::default();
    assert!(binding.path.is_none());
    assert!(backfill(
        &pair.harness,
        &pair.facts(),
        &tree.roots(),
        &mut binding,
        &pair.prompt,
        &scraped,
    )
    .is_some());
    assert!(binding.path.is_some(), "the bound path is cached");
    assert_eq!(
        binding.searches, 0,
        "a delivered answer clears the search count"
    );
    assert!(
        binding.cursor.offset > 0,
        "the cursor advanced past the turn read"
    );

    // The same turn is offered once: the cursor is past it now.
    let before = binding.cursor;
    assert!(backfill(
        &pair.harness,
        &pair.facts(),
        &tree.roots(),
        &mut binding,
        &pair.prompt,
        &scraped,
    )
    .is_none());
    assert_eq!(
        binding.cursor, before,
        "a re-read of the same file moves nothing"
    );

    let bare = TempTree::new();
    let mut fruitless = LogBinding::default();
    for _ in 0..MAX_SEARCHES + 2 {
        assert!(backfill(
            &pair.harness,
            &pair.facts(),
            &bare.roots(),
            &mut fruitless,
            &pair.prompt,
            &scraped,
        )
        .is_none());
    }
    assert_eq!(
        fruitless.searches, MAX_SEARCHES,
        "searching stops at the cap instead of walking the tree every turn"
    );
}

/// The cap bounds repeated tree walks without ever becoming permanent:
/// a prompt set the binder has not seen fail, and a quiet period long
/// enough for the harness to have written a file, each buy one more walk.
#[test]
fn a_capped_watch_searches_again_on_new_prompts_or_after_the_quiet_period() {
    let pairs = corpus_pairs();
    let pair = pairs
        .iter()
        .find(|p| p.name == "claude/01_short_answer")
        .expect("corpus pair");
    let tree = TempTree::new();
    tree.plant(pair);
    let scraped = pair.scraped();

    // The shape a send the harness has not recorded yet leaves: the relay's
    // latest prompt is in no transcript on disk, so the binder finds no
    // candidate at all.
    let mut unrecorded = pair.facts();
    unrecorded.record_prompt("a prompt no transcript holds yet", pair.opened_ms);

    let mut binding = LogBinding::default();
    for _ in 0..MAX_SEARCHES {
        assert!(backfill(
            &pair.harness,
            &unrecorded,
            &tree.roots(),
            &mut binding,
            &pair.prompt,
            &scraped,
        )
        .is_none());
    }
    assert_eq!(binding.searches, MAX_SEARCHES, "the cap is reached");
    let capped_at = binding.retry_at;

    assert!(backfill(
        &pair.harness,
        &unrecorded,
        &tree.roots(),
        &mut binding,
        &pair.prompt,
        &scraped,
    )
    .is_none());
    assert_eq!(
        binding.retry_at, capped_at,
        "at the cap the turn costs no walk at all"
    );

    // The unrecorded prompt ages out of the retained set.
    let aged = pair.facts();
    assert_eq!(
        backfill(
            &pair.harness,
            &aged,
            &tree.roots(),
            &mut binding,
            &pair.prompt,
            &scraped,
        )
        .as_deref(),
        Some(pair.ground_truth.as_str()),
        "a changed prompt set lifts the cap, and the search binds"
    );
    assert_eq!(binding.searches, 0, "a delivered answer clears the count");

    // Same cap, same prompts, nothing new sent: the quiet period alone
    // has to be enough.
    let mut quiet = LogBinding {
        searches: MAX_SEARCHES,
        prompts_searched: prompt_fingerprint(&aged.prompts),
        retry_at: Some(Instant::now()),
        ..Default::default()
    };
    assert_eq!(
        backfill(
            &pair.harness,
            &aged,
            &tree.roots(),
            &mut quiet,
            &pair.prompt,
            &scraped,
        )
        .as_deref(),
        Some(pair.ground_truth.as_str()),
        "the retry deadline lets a capped watch bind the log that appeared"
    );
}

/// Two turns in one log share a prompt body and only the earlier one has
/// closed. The earlier turn's answer belongs to the earlier turn.
///
/// An opening turn whose scrape cross-checks establishes the binding: only a
/// delivered answer caches the path, and a short scrape is refused on a file
/// that was just bound.
#[test]
fn a_repeated_prompt_never_delivers_the_earlier_turns_answer() {
    const CWD: &str = "/work/repeat-proj";
    const OPENING_TS: &str = "2026-09-19T00:55:00.000Z";
    const OPENING_ANSWER: &str = "Setup done, nothing to report.";
    const FIRST_TS: &str = "2026-09-19T01:00:00.000Z";
    const SECOND_TS: &str = "2026-09-19T01:05:00.000Z";
    const SECOND_ANSWER: &str = "Second answer, about gadgets.";

    let user = |ts: &str, text: &str| claude_user(CWD, ts, text);
    let assistant = claude_assistant;
    let turn_duration = claude_turn_end;

    let tree = TempTree::new();
    let dir = tree
        .roots()
        .claude_projects
        .join(session_log::claude_project_slug(Path::new(CWD)));
    fs::create_dir_all(&dir).expect("log directory");
    let log = dir.join("session.jsonl");
    let opening = format!(
        "{}{}{}",
        user(OPENING_TS, "start"),
        assistant(OPENING_TS, OPENING_ANSWER),
        turn_duration(OPENING_TS),
    );
    fs::write(&log, &opening).expect("plant transcript");

    let mut facts = SessionFacts {
        cwd: Some(CWD.to_string()),
        ..Default::default()
    };
    facts.record_prompt("start", session_log::parse_iso_ms(OPENING_TS).unwrap());

    let mut binding = LogBinding::default();
    assert_eq!(
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "start",
            OPENING_ANSWER,
        )
        .as_deref(),
        Some(OPENING_ANSWER),
        "the opening turn is what binds the log file"
    );

    let through_first = format!(
        "{opening}{}{}{}",
        user(FIRST_TS, "continue"),
        assistant(FIRST_TS, "First answer, about widgets."),
        turn_duration(FIRST_TS),
    );
    let second_open = format!(
        "{through_first}{}{}",
        user(SECOND_TS, "continue"),
        assistant(SECOND_TS, SECOND_ANSWER),
    );
    fs::write(&log, &second_open).expect("append the repeated prompt");

    facts.record_prompt("continue", session_log::parse_iso_ms(FIRST_TS).unwrap());
    facts.record_prompt("continue", session_log::parse_iso_ms(SECOND_TS).unwrap());

    // Short enough that nothing in it could cross-check an answer: the submit
    // time is all that stands between the screen and the earlier turn's text.
    let scraped = "ok";
    assert_eq!(
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "continue",
            scraped,
        ),
        None,
        "the earlier turn is outside this submit window and the later one has \
         no recorded answer yet, so the screen stands"
    );

    // The harness closes the second turn.
    fs::write(&log, format!("{second_open}{}", turn_duration(SECOND_TS)))
        .expect("close the second turn");
    assert_eq!(
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "continue",
            SECOND_ANSWER,
        )
        .as_deref(),
        Some(SECOND_ANSWER),
        "the turn the relay drove is delivered once the harness closes it"
    );
}

/// A path bound while our own log was still unflushed does not outlive the
/// prompt it was bound for. The sibling is the only file on disk for the first
/// turn, so it binds and delivers against a scrape that cross-checks it. Our
/// own transcript then appears holding the next prompt, and that prompt puts
/// the question back to the binder before the cached path is read for it: two
/// candidates are refused, the path and its cursor are dropped, and a scrape
/// too short to cross-check takes nothing from the sibling's next answer.
#[test]
fn a_new_prompt_re_derives_the_binding_before_the_cache_answers() {
    const CWD: &str = "/work/unflushed-proj";
    const FIRST_TS: &str = "2026-09-19T01:00:00.000Z";
    const SECOND_TS: &str = "2026-09-19T01:05:00.000Z";
    const SIBLING_FIRST: &str = "Done - I rewrote the parser and every test passes.";
    const SIBLING_SECOND: &str = "Done - I deleted the fixture directory.";

    let turn = |ts: &str, answer: &str| {
        format!(
            "{}{}{}",
            claude_user(CWD, ts, "continue"),
            claude_assistant(ts, answer),
            claude_turn_end(ts),
        )
    };

    let tree = TempTree::new();
    let dir = tree
        .roots()
        .claude_projects
        .join(session_log::claude_project_slug(Path::new(CWD)));
    fs::create_dir_all(&dir).expect("log directory");
    let sibling = dir.join("aaaa-sibling.jsonl");
    let sibling_first = turn(FIRST_TS, SIBLING_FIRST);
    fs::write(&sibling, &sibling_first).expect("plant the sibling");

    let mut facts = SessionFacts {
        cwd: Some(CWD.to_string()),
        ..Default::default()
    };
    facts.record_prompt("continue", session_log::parse_iso_ms(FIRST_TS).unwrap());

    let mut binding = LogBinding::default();
    assert_eq!(
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "continue",
            SIBLING_FIRST,
        )
        .as_deref(),
        Some(SIBLING_FIRST),
        "with our own log unflushed the sibling is the one candidate"
    );
    assert_eq!(binding.path.as_deref(), Some(sibling.as_path()));

    // Our own transcript appears, and both terminals get the next prompt.
    fs::write(
        &sibling,
        format!("{sibling_first}{}", turn(SECOND_TS, SIBLING_SECOND)),
    )
    .expect("append the sibling's next turn");
    fs::write(
        dir.join("bbbb-ours.jsonl"),
        claude_user(CWD, SECOND_TS, "continue"),
    )
    .expect("plant our own log");
    facts.record_prompt("continue", session_log::parse_iso_ms(SECOND_TS).unwrap());

    assert_eq!(
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "continue",
            "ok",
        ),
        None,
        "the new prompt is put to the binder, which refuses two candidates"
    );
    assert!(
        binding.path.is_none() && binding.cursor == Cursor::default(),
        "a verdict that does not name the cached path drops it and its cursor"
    );
}

/// A repeat of a prompt body the retained set is already full of still puts
/// the question back to the binder. Eight sends of "continue" leave the bodies
/// identical from one turn to the next, so the submit instants are the only
/// thing a ninth send changes; without them the cached sibling — bound while
/// our own log was unflushed — would answer that ninth turn off a scrape too
/// short to cross-check it with.
#[test]
fn a_repeated_prompt_body_still_re_derives_the_binding() {
    const CWD: &str = "/work/repeat-fingerprint-proj";
    const EIGHTH_TS: &str = "2026-09-19T01:00:00.000Z";
    const NINTH_TS: &str = "2026-09-19T01:05:00.000Z";
    const SIBLING_EIGHTH: &str = "Done - I rewrote the parser and every test passes.";
    const SIBLING_NINTH: &str = "Done - I deleted the fixture directory.";

    let turn = |ts: &str, answer: &str| {
        format!(
            "{}{}{}",
            claude_user(CWD, ts, "continue"),
            claude_assistant(ts, answer),
            claude_turn_end(ts),
        )
    };

    let tree = TempTree::new();
    let dir = tree
        .roots()
        .claude_projects
        .join(session_log::claude_project_slug(Path::new(CWD)));
    fs::create_dir_all(&dir).expect("log directory");
    let sibling = dir.join("aaaa-sibling.jsonl");
    let sibling_eighth = turn(EIGHTH_TS, SIBLING_EIGHTH);
    fs::write(&sibling, &sibling_eighth).expect("plant the sibling");

    // A full retained set of one repeated body: only the newest submission is
    // in the binder's window, and every body in it is the same word.
    let mut facts = SessionFacts {
        cwd: Some(CWD.to_string()),
        ..Default::default()
    };
    let eighth_ms = session_log::parse_iso_ms(EIGHTH_TS).unwrap();
    for back in (0..crate::terminal_facts::MAX_PROMPTS as i64).rev() {
        facts.record_prompt("continue", eighth_ms - back * 60_000);
    }
    assert_eq!(facts.prompts.len(), crate::terminal_facts::MAX_PROMPTS);

    let mut binding = LogBinding::default();
    assert_eq!(
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "continue",
            SIBLING_EIGHTH,
        )
        .as_deref(),
        Some(SIBLING_EIGHTH),
        "with our own log unflushed the sibling is the one candidate"
    );
    assert_eq!(binding.path.as_deref(), Some(sibling.as_path()));

    // Our own transcript appears, and both terminals get a ninth "continue".
    fs::write(
        &sibling,
        format!("{sibling_eighth}{}", turn(NINTH_TS, SIBLING_NINTH)),
    )
    .expect("append the sibling's ninth turn");
    fs::write(
        dir.join("bbbb-ours.jsonl"),
        claude_user(CWD, NINTH_TS, "continue"),
    )
    .expect("plant our own log");
    facts.record_prompt("continue", session_log::parse_iso_ms(NINTH_TS).unwrap());

    assert_eq!(
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "continue",
            "ok",
        ),
        None,
        "the ninth send is put to the binder, which refuses two candidates"
    );
    assert!(
        binding.path.is_none() && binding.cursor == Cursor::default(),
        "a verdict that does not name the cached path drops it and its cursor"
    );
}

/// A verdict that names the cached path is still a fresh verdict: the window
/// it hands back was read under no cursor of this prompt. The sibling is the
/// only transcript on disk, so every prompt binds it while our own log stays
/// unflushed — and a scrape too short to cross-check may not take the
/// sibling's next answer off that, though one that cross-checks may.
#[test]
fn a_rebind_onto_the_cached_path_refuses_a_short_scrape() {
    const CWD: &str = "/work/rebound-cache-proj";
    const FIRST_TS: &str = "2026-09-19T01:00:00.000Z";
    const SECOND_TS: &str = "2026-09-19T01:05:00.000Z";
    const SIBLING_FIRST: &str = "Done - I rewrote the parser and every test passes.";
    const SIBLING_SECOND: &str = "Done - I deleted the fixture directory and its loader.";

    let turn = |ts: &str, answer: &str| {
        format!(
            "{}{}{}",
            claude_user(CWD, ts, "continue"),
            claude_assistant(ts, answer),
            claude_turn_end(ts),
        )
    };

    // Bind the sibling on the first prompt, append its second turn, then read
    // that turn for a second prompt with `scraped`.
    let deliver_second = |scraped: &str| -> Option<String> {
        let tree = TempTree::new();
        let dir = tree
            .roots()
            .claude_projects
            .join(session_log::claude_project_slug(Path::new(CWD)));
        fs::create_dir_all(&dir).expect("log directory");
        let sibling = dir.join("sibling.jsonl");
        let sibling_first = turn(FIRST_TS, SIBLING_FIRST);
        fs::write(&sibling, &sibling_first).expect("plant the sibling");

        let mut facts = SessionFacts {
            cwd: Some(CWD.to_string()),
            ..Default::default()
        };
        facts.record_prompt("continue", session_log::parse_iso_ms(FIRST_TS).unwrap());
        let mut binding = LogBinding::default();
        assert_eq!(
            backfill(
                "claude",
                &facts,
                &tree.roots(),
                &mut binding,
                "continue",
                SIBLING_FIRST,
            )
            .as_deref(),
            Some(SIBLING_FIRST),
            "a cross-checked scrape binds the one candidate on disk"
        );

        fs::write(
            &sibling,
            format!("{sibling_first}{}", turn(SECOND_TS, SIBLING_SECOND)),
        )
        .expect("append the sibling's second turn");
        facts.record_prompt("continue", session_log::parse_iso_ms(SECOND_TS).unwrap());

        let delivered = backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "continue",
            scraped,
        );
        assert_eq!(
            binding.path.as_deref(),
            Some(sibling.as_path()),
            "the binder named the cached path again, so it is kept"
        );
        delivered
    };

    assert_eq!(
        deliver_second("ok"),
        None,
        "the binder ran for this prompt, so a scrape too short to cross-check \
         may not ride on the prompt match"
    );
    assert_eq!(
        deliver_second(SIBLING_SECOND).as_deref(),
        Some(SIBLING_SECOND),
        "a scrape that cross-checks is delivered off the same rebind"
    );
}

// ---------------------------------------------------------------------------
// Constructed transcripts
// ---------------------------------------------------------------------------

/// The three claude records that make one finished turn.
fn claude_user(cwd: &str, ts: &str, text: &str) -> String {
    json!({
        "type": "user",
        "cwd": cwd,
        "timestamp": ts,
        "message": {"role": "user", "content": text},
    })
    .to_string()
        + "\n"
}

fn claude_assistant(ts: &str, text: &str) -> String {
    json!({
        "type": "assistant",
        "timestamp": ts,
        "message": {"content": [{"type": "text", "text": text}]},
    })
    .to_string()
        + "\n"
}

fn claude_turn_end(ts: &str) -> String {
    json!({"type": "system", "subtype": "turn_duration", "timestamp": ts}).to_string() + "\n"
}

/// At least `bytes` of records the extractor steps over, so that only their
/// size matters.
fn filler(cwd: &str, ts: &str, bytes: u64) -> String {
    let line = json!({"type": "system", "subtype": "filler", "cwd": cwd,
                      "timestamp": ts, "filler": "x".repeat(4_096)})
    .to_string()
        + "\n";
    line.repeat(bytes as usize / line.len() + 1)
}

const APPEND_CWD: &str = "/work/append-proj";
const OPENING_TS: &str = "2026-09-19T00:50:00.000Z";
const OPENING_ANSWER: &str = "Setup finished, and the fixture directory is in place.";
const LATE_TS: &str = "2026-09-19T01:00:00.000Z";

/// Bind a terminal on an opening turn the way a real watch does, then write
/// `tail` past that turn and put the prompt "continue" to the matcher. The
/// answer it delivers for that second turn, or None when the screen text
/// stands.
fn deliver_after_opening(tail: &str, scraped: &str) -> Option<String> {
    let tree = TempTree::new();
    let dir = tree
        .roots()
        .claude_projects
        .join(session_log::claude_project_slug(Path::new(APPEND_CWD)));
    fs::create_dir_all(&dir).expect("log directory");
    let log = dir.join("session.jsonl");
    let opening = format!(
        "{}{}{}",
        claude_user(APPEND_CWD, OPENING_TS, "start"),
        claude_assistant(OPENING_TS, OPENING_ANSWER),
        claude_turn_end(OPENING_TS),
    );
    fs::write(&log, &opening).expect("plant transcript");

    let mut facts = SessionFacts {
        cwd: Some(APPEND_CWD.to_string()),
        ..Default::default()
    };
    facts.record_prompt("start", session_log::parse_iso_ms(OPENING_TS).unwrap());
    let mut binding = LogBinding::default();
    assert_eq!(
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "start",
            OPENING_ANSWER,
        )
        .as_deref(),
        Some(OPENING_ANSWER),
        "the opening turn is what binds the log file and sets the cursor"
    );

    fs::write(&log, format!("{opening}{tail}")).expect("append past the cursor");
    facts.record_prompt("continue", session_log::parse_iso_ms(LATE_TS).unwrap());
    backfill(
        "claude",
        &facts,
        &tree.roots(),
        &mut binding,
        "continue",
        scraped,
    )
}

/// A log that grew past the span budget between two reads is read from its
/// tail window, not from the cursor: the turn inside that window is delivered
/// as it would be from a small file, and a turn in the skipped span is not
/// offered at all. The skip also strips the cursor of its vouching — which is
/// the only thing keeping a scrape too short to cross-check from riding on a
/// prompt match against turns nothing read the history of.
#[test]
fn a_span_past_the_budget_is_skipped_to_the_tail_window() {
    const ANSWER: &str = "The tokeniser now folds escapes before the lexer sees them, \
                          which is why the fixture changed.";
    let turn = format!(
        "{}{}{}",
        claude_user(APPEND_CWD, LATE_TS, "continue"),
        claude_assistant(LATE_TS, ANSWER),
        claude_turn_end(LATE_TS),
    );
    let over_budget = filler(
        APPEND_CWD,
        OPENING_TS,
        crate::turn_extract::MAX_SPAN_BYTES + 64 * 1024,
    );
    let inside_budget = filler(
        APPEND_CWD,
        OPENING_TS,
        crate::turn_extract::MAX_SPAN_BYTES / 4,
    );

    assert_eq!(
        deliver_after_opening(&format!("{over_budget}{turn}"), ANSWER).as_deref(),
        Some(ANSWER),
        "a turn inside the tail window is delivered whatever preceded it"
    );
    assert_eq!(
        deliver_after_opening(&format!("{turn}{over_budget}"), ANSWER),
        None,
        "a turn in the skipped span is unavailable, so the screen text stands"
    );
    assert_eq!(
        deliver_after_opening(&format!("{turn}{inside_budget}"), ANSWER).as_deref(),
        Some(ANSWER),
        "and a span inside the budget is read from the cursor as before"
    );

    assert_eq!(
        deliver_after_opening(&format!("{over_budget}{turn}"), "ok"),
        None,
        "after a skip the cursor vouches for nothing, so a scrape too short to \
         cross-check may not ride on the prompt match"
    );
}

/// One turn cannot accumulate without bound. A turn past the cap is dropped
/// whole: half of a runaway answer would still read as a complete one, so the
/// screen text stands instead.
#[test]
fn a_turn_past_the_size_cap_is_dropped_rather_than_truncated() {
    let cap = crate::turn_extract::MAX_TURN_BYTES;
    let chunk = |bytes: usize| "escape folding ".repeat(bytes / "escape folding ".len());
    let within = chunk(cap / 2);
    let half = chunk(cap * 2 / 3);

    let usable = format!(
        "{}{}{}",
        claude_user(APPEND_CWD, LATE_TS, "continue"),
        claude_assistant(LATE_TS, &within),
        claude_turn_end(LATE_TS),
    );
    assert_eq!(
        deliver_after_opening(&usable, &within).as_deref(),
        Some(within.as_str()),
        "a long answer under the cap is delivered whole"
    );

    let runaway = format!(
        "{}{}{}{}",
        claude_user(APPEND_CWD, LATE_TS, "continue"),
        claude_assistant(LATE_TS, &half),
        claude_assistant(LATE_TS, &half),
        claude_turn_end(LATE_TS),
    );
    assert_eq!(
        deliver_after_opening(&runaway, &half),
        None,
        "the same turn past the cap offers nothing, not a truncated answer"
    );
}

/// A rebind onto the cached path that delivers nothing (the sibling's turn is
/// still open) leaves the path but vouches for none of its turns: once the
/// sibling closes that turn, a re-read under the same prompts must still
/// refuse a short scrape, and only a cross-checking scrape may deliver.
#[test]
fn a_path_kept_by_an_empty_rebind_does_not_vouch_for_a_short_scrape() {
    const CWD: &str = "/work/unvouched-cache-proj";
    const FIRST_TS: &str = "2026-09-19T01:00:00.000Z";
    const SECOND_TS: &str = "2026-09-19T01:05:00.000Z";
    const SIBLING_FIRST: &str = "Done - I rewrote the parser and every test passes.";
    const SIBLING_SECOND: &str = "Done - I deleted the fixture directory and its loader.";

    let run = |scraped_later: &str| -> Option<String> {
        let tree = TempTree::new();
        let dir = tree
            .roots()
            .claude_projects
            .join(session_log::claude_project_slug(Path::new(CWD)));
        fs::create_dir_all(&dir).expect("log directory");
        let sibling = dir.join("sibling.jsonl");
        let first = format!(
            "{}{}{}",
            claude_user(CWD, FIRST_TS, "continue"),
            claude_assistant(FIRST_TS, SIBLING_FIRST),
            claude_turn_end(FIRST_TS),
        );
        fs::write(&sibling, &first).expect("plant the sibling");

        let mut facts = SessionFacts {
            cwd: Some(CWD.to_string()),
            ..Default::default()
        };
        facts.record_prompt("continue", session_log::parse_iso_ms(FIRST_TS).unwrap());
        let mut binding = LogBinding::default();
        assert_eq!(
            backfill(
                "claude",
                &facts,
                &tree.roots(),
                &mut binding,
                "continue",
                SIBLING_FIRST
            )
            .as_deref(),
            Some(SIBLING_FIRST),
            "a cross-checked scrape binds the one candidate on disk"
        );

        // Second prompt: the sibling's turn is open at rebind time, so nothing
        // is delivered and the path is kept.
        let open_turn = format!(
            "{}{}",
            claude_user(CWD, SECOND_TS, "continue"),
            claude_assistant(SECOND_TS, SIBLING_SECOND),
        );
        fs::write(&sibling, format!("{first}{open_turn}")).expect("append an open turn");
        facts.record_prompt("continue", session_log::parse_iso_ms(SECOND_TS).unwrap());
        assert_eq!(
            backfill(
                "claude",
                &facts,
                &tree.roots(),
                &mut binding,
                "continue",
                "ok"
            ),
            None,
            "an open turn delivers nothing"
        );
        assert!(
            binding.path.is_some(),
            "the rebind landed on the cached path and kept it"
        );

        // The sibling closes the turn; a re-read under the same prompts.
        fs::write(
            &sibling,
            format!("{first}{open_turn}{}", claude_turn_end(SECOND_TS)),
        )
        .expect("close the turn");
        backfill(
            "claude",
            &facts,
            &tree.roots(),
            &mut binding,
            "continue",
            scraped_later,
        )
    };

    assert_eq!(
        run("ok"),
        None,
        "no cross-checked answer vouched for this prompt"
    );
    assert_eq!(
        run(SIBLING_SECOND).as_deref(),
        Some(SIBLING_SECOND),
        "a cross-checking scrape may still deliver"
    );
}
