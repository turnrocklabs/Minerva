// hold_submit_tests.rs — the corpus tests of the send gate's two screen
// judgements, declared as send_gate.rs's `corpus_tests` module.
//
// Every screen here is a byte-true capture from
// tests/fixtures/hold_submit/, whose README states the ground truth each
// assertion is checked against: which screens own the keyboard, and what a
// harness shows one second after a write it accepted (and after one it did
// not). The fixtures are included at compile time so the bytes under test are
// the captured bytes.

use crate::detector::{self, CompiledDetection, DetectionMethod, SubmitState, WakeCause};
use crate::dialog;
use crate::profiles::{builtin_profiles, Profile};

const F: &str = "tests/fixtures/hold_submit";

fn profile(id: &str) -> Profile {
    builtin_profiles().into_iter().find(|p| p.id == id).unwrap()
}

fn compiled(id: &str) -> CompiledDetection {
    CompiledDetection::from_profile(&profile(id)).unwrap()
}

// ── The seven screens a write must never land on ────────────────────────────
// README §1: all seven are `must_hold: true` in their meta.json. Four of them
// (permission dialog, both trust prompts, the codex update offer) classified
// as `none` before this gate existed, and the update offer is the screen whose
// stray Enter started an `npm install -g` during capture.

const HOLD_FIXTURES: &[(&str, &str)] = &[
    ("claude", include_str!("../tests/fixtures/hold_submit/hold/claude_permission_dialog/screen.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/hold/claude_question_chooser/screen.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/hold/claude_trust_folder/screen.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/hold/claude_model_menu/screen.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/hold/codex_trust_directory/screen.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/hold/codex_update_available_menu/screen.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/hold/codex_model_menu/screen.txt")),
];

#[test]
fn every_hold_fixture_holds_and_wakes_as_input_requested() {
    assert_eq!(HOLD_FIXTURES.len(), 7, "the corpus has seven hold states");
    for (i, (profile_id, screen)) in HOLD_FIXTURES.iter().enumerate() {
        let cd = compiled(profile_id);
        assert!(
            detector::hold_reason(screen, &cd).is_some(),
            "{F}/hold[{i}] ({profile_id}) is a must_hold screen but the gate would write on it"
        );
        // The same screen must also tell a watcher a human is being asked:
        // a held write with no wake would just stall the chat.
        let det = detector::run(screen, false, false, &cd)
            .unwrap_or_else(|| panic!("{F}/hold[{i}] produced no detection at all"));
        assert_eq!(
            det.cause,
            WakeCause::InputRequested,
            "{F}/hold[{i}] must wake as input_requested, got {:?}",
            det.cause
        );
        assert_eq!(det.method, DetectionMethod::PermissionDialog);
    }
}

// ── Screens a write MUST be allowed on ──────────────────────────────────────
// Everything the corpus captured that is NOT a hold state: the submit pair on
// both harnesses, the ghost-suggestion idle screen, every moment of both queue
// runs, and the older calibration captures. A false hold here stalls every
// send until its budget expires.

const WRITABLE_SCREENS: &[(&str, &str)] = &[
    ("claude", include_str!("../tests/fixtures/hold_submit/submit/claude_composer_typed_before_enter/screen.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/submit/claude_typed_submit_ok/screen.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/submit/claude_chunk_submit_ok/screen.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/submit/claude_idle_with_ghost_suggestion/screen.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/submit/codex_composer_typed_before_enter/screen.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/submit/codex_typed_submit_ok/screen.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/submit/codex_chunk_stuck_in_composer/screen.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/submit/codex_chunk_after_extra_enter/screen.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/queue/claude_queue/screens/01_turn1_in_flight.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/queue/claude_queue/screens/02_second_message_typed.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/queue/claude_queue/screens/03_queued.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/queue/claude_queue/screens/05_dequeued_running.txt")),
    ("claude", include_str!("../tests/fixtures/hold_submit/queue/claude_queue/screens/06_second_answer.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/queue/codex_queue/screens/01_turn1_in_flight.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/queue/codex_queue/screens/03_queued.txt")),
    ("codex", include_str!("../tests/fixtures/hold_submit/queue/codex_queue/screens/06_second_answer.txt")),
    ("claude", include_str!("../tests/fixtures/real/claude_idle_prompt.txt")),
    ("claude", include_str!("../tests/fixtures/real/claude_turn_complete.txt")),
    ("claude", include_str!("../tests/fixtures/real/claude_prose_question_idle.txt")),
    ("claude", include_str!("../tests/fixtures/real/claude_v2_short_turn_idle.txt")),
    ("claude", include_str!("../tests/fixtures/real/claude_windows_idle.txt")),
    ("codex", include_str!("../tests/fixtures/real/codex_idle_prompt.txt")),
    ("codex", include_str!("../tests/fixtures/real/codex_busy.txt")),
    ("codex", include_str!("../tests/fixtures/real/codex_done.txt")),
];

#[test]
fn no_working_screen_is_held() {
    for (i, (profile_id, screen)) in WRITABLE_SCREENS.iter().enumerate() {
        let cd = compiled(profile_id);
        assert_eq!(
            detector::hold_reason(screen, &cd),
            None,
            "writable[{i}] ({profile_id}) was held — a send would stall on an ordinary screen"
        );
    }
}

// ── What the screen says about a write ──────────────────────────────────────
// README §2 / findings 5–7. The evidence is the in-flight turn marker or the
// transcript echo; "composer empty" is not readable from extracted rows on
// Claude Code, and a queued send reproduces the echo without being ours.

/// The two messages the submit corpus was driven with.
const PING: &str = "Reply with exactly the word PING and nothing else.";
const PONG: &str = "Reply with exactly the word PONG and nothing else.";

#[test]
fn submit_confirmation_matches_the_corpus() {
    // (profile, screen, the message that was written, expected verdict)
    let cases: &[(&str, &str, &str, SubmitState)] = &[
        // Claude Code took both the typed Enter and the single chunk: a turn
        // is in flight on each screen.
        (
            "claude",
            include_str!("../tests/fixtures/hold_submit/submit/claude_typed_submit_ok/screen.txt"),
            PONG,
            SubmitState::Submitted("busy"),
        ),
        (
            "claude",
            include_str!("../tests/fixtures/hold_submit/submit/claude_chunk_submit_ok/screen.txt"),
            PING,
            SubmitState::Submitted("busy"),
        ),
        // The ghost suggestion draws the message INTO an empty composer. It
        // must never read as stuck — the extra Enter it would earn submits
        // nothing and lands on whatever comes next.
        (
            "claude",
            include_str!(
                "../tests/fixtures/hold_submit/submit/claude_idle_with_ghost_suggestion/screen.txt"
            ),
            PONG,
            SubmitState::Submitted("echo"),
        ),
        // codex took the typed Enter, and took the chunk only after the extra
        // Enter that the stuck screen earned.
        (
            "codex",
            include_str!("../tests/fixtures/hold_submit/submit/codex_typed_submit_ok/screen.txt"),
            PONG,
            SubmitState::Submitted("busy"),
        ),
        (
            "codex",
            include_str!(
                "../tests/fixtures/hold_submit/submit/codex_chunk_after_extra_enter/screen.txt"
            ),
            PING,
            SubmitState::Submitted("busy"),
        ),
        // The one measured failure shape: settled, unechoed, nothing running.
        (
            "codex",
            include_str!(
                "../tests/fixtures/hold_submit/submit/codex_chunk_stuck_in_composer/screen.txt"
            ),
            PING,
            SubmitState::StuckInComposer,
        ),
    ];

    for (i, (profile_id, screen, body, expected)) in cases.iter().enumerate() {
        assert_eq!(
            &detector::confirm_submit(screen, body, &compiled(profile_id), None),
            expected,
            "submit case {i} ({profile_id})"
        );
    }
}

/// A screen shape the corpus cannot hold on its own: the SAME text submitted
/// twice. The first submit left an echo row in the transcript; the second
/// stuck in the composer. The old echo is still on screen, so without a
/// pre-write baseline the stuck submit reads as Submitted("echo") and never
/// earns its recovery Enter.
///
/// Both screens are built from the codex stuck-composer capture: the composer
/// row IS the body row there, so removing it gives the pre-write screen and
/// the inserted transcript copy gives the old echo.
#[test]
fn an_old_echo_of_the_same_text_does_not_confirm_a_new_submit() {
    let cd = compiled("codex");
    let stuck = include_str!(
        "../tests/fixtures/hold_submit/submit/codex_chunk_stuck_in_composer/screen.txt"
    );
    let composer_row = format!("\u{203a} {PING}");
    assert!(
        stuck.contains(&composer_row),
        "the fixture's composer row is the body row"
    );
    // The transcript row the FIRST submit of this text left behind, placed
    // above the composer so it is not the last prompt_box match.
    let old_echo = format!("\u{2022} {PING}\n");
    let with_old_echo = format!("{old_echo}{stuck}");
    let pre_write = with_old_echo.replace(&composer_row, "");

    assert_eq!(
        detector::confirm_submit(&pre_write, PING, &cd, None),
        SubmitState::Submitted("echo"),
        "the old echo is already on the PRE-WRITE screen — judged alone, it \
         reads as a confirmation"
    );
    assert_eq!(
        detector::confirm_submit(&with_old_echo, PING, &cd, Some(&pre_write)),
        SubmitState::StuckInComposer,
        "an echo that was already there confirms nothing: this submit is stuck"
    );
    // The same screen WITHOUT the old echo is a plain stuck composer, and a
    // screen whose echo count grew is a real submit.
    assert_eq!(
        detector::confirm_submit(stuck, PING, &cd, Some(&pre_write)),
        SubmitState::StuckInComposer,
        "no echo at all is still stuck"
    );
    let echoed_again = format!("{old_echo}{with_old_echo}");
    assert_eq!(
        detector::confirm_submit(&echoed_again, PING, &cd, Some(&pre_write)),
        SubmitState::Submitted("echo"),
        "a NEW echo row confirms the submit"
    );
}

#[test]
fn claude_never_reports_a_stuck_composer() {
    // The paste-stuck state was not producible on Claude Code, and its ghost
    // suggestion makes the rows ambiguous — so no Claude screen may ever earn
    // the extra Enter, including the BEFORE-Enter screen that looks exactly
    // like one.
    let cd = compiled("claude");
    for (profile_id, screen) in WRITABLE_SCREENS.iter().filter(|(p, _)| *p == "claude") {
        for body in [PING, PONG] {
            assert_ne!(
                detector::confirm_submit(screen, body, &cd, None),
                SubmitState::StuckInComposer,
                "{profile_id} must never report a stuck composer"
            );
        }
    }
}

// ── The question card keeps working ─────────────────────────────────────────
// The hold rules widened what counts as a dialog; the passthrough card must
// still name the same options a human sees on the screen (meta.json
// ground_truth for each fixture).

fn card_options(profile_id: &str, screen: &str) -> Vec<(String, String)> {
    let dialog_re = profile(profile_id)
        .detection
        .permission_dialog_regex
        .and_then(|pat| regex::Regex::new(&pat).ok());
    let region = dialog::extract_question_region(screen)
        .unwrap_or_else(|| dialog::extract_dialog_region(screen, dialog_re.as_ref(), 20));
    dialog::parse_options(profile_id, &region)
        .into_iter()
        .map(|o| (o.label, o.keystroke))
        .collect()
}

#[test]
fn permission_dialog_and_chooser_still_parse_their_options() {
    let permission = include_str!(
        "../tests/fixtures/hold_submit/hold/claude_permission_dialog/screen.txt"
    );
    let opts = card_options("claude", permission);
    let labels: Vec<&str> = opts.iter().map(|(l, _)| l.as_str()).collect();
    assert_eq!(
        labels.len(),
        3,
        "the Write-tool dialog offers three options: {labels:?}"
    );
    assert_eq!(labels[0], "Yes");
    assert!(labels[1].starts_with("Yes, and switch to accept edits"));
    assert_eq!(labels[2], "No");
    assert_eq!(
        opts.iter().map(|(_, k)| k.as_str()).collect::<Vec<_>>(),
        vec!["1", "2", "3"],
        "numbered options answer with their number"
    );

    let chooser =
        include_str!("../tests/fixtures/hold_submit/hold/claude_question_chooser/screen.txt");
    assert_eq!(
        card_options("claude", chooser),
        vec![
            ("Spaces".to_string(), "1".to_string()),
            ("Tabs".to_string(), "2".to_string()),
            ("Type something.".to_string(), "3".to_string()),
            ("Chat about this".to_string(), "4".to_string()),
        ],
        "the AskUserQuestion chooser's options, in screen order"
    );

    // The older byte-true codex approval capture is the regression guard for
    // the region anchoring the widening touched.
    let codex_permission = include_str!("../tests/fixtures/real/codex_permission.txt");
    let labels: Vec<String> = card_options("codex", codex_permission)
        .into_iter()
        .map(|(l, _)| l)
        .collect();
    assert_eq!(labels.len(), 3, "codex approval options: {labels:?}");
    assert_eq!(labels[0], "Yes, proceed");
}

#[test]
fn the_update_offer_parses_into_a_card_instead_of_a_blind_enter() {
    // The incident this corpus records: Enter on this screen selects
    // "Update now" and runs a global npm install. It matches no profile
    // phrase, so it must reach the card through the structural path.
    let screen = include_str!(
        "../tests/fixtures/hold_submit/hold/codex_update_available_menu/screen.txt"
    );
    let opts = card_options("codex", screen);
    let labels: Vec<&str> = opts.iter().map(|(l, _)| l.as_str()).collect();
    assert_eq!(labels.len(), 3, "update offer options: {labels:?}");
    assert!(labels[0].starts_with("Update now"));
    assert_eq!(labels[2], "Skip until next version");
}

// ── False holds: ordinary completed turns that must NOT own the keyboard ────
// The Menu and ConfirmFooter rules read the whole screen, so anything a
// harness ECHOES can imitate a chooser: a user prompt that starts with a
// number renders as a caret-marked option row, an answer's numbered list
// supplies the siblings, and answer prose naming the Enter key reads as a
// modal footer. Each screen below is an ordinary settled turn — a hold here
// stalls every send on that terminal until its budget expires, and wakes the
// chat as a question card with no answer.

/// A user prompt that starts with "1." echoed into the transcript, with a
/// numbered list in the answer below it.
const FALSE_HOLD_CLAUDE_NUMBERED_ECHO: &str = concat!(
    "\u{276f} 1. Get the build green, 2. then cut the tag\n",
    "\n",
    "\u{25cf} Two steps, in order:\n",
    "\n",
    "  1. Run the scoped suite and fix the two reds\n",
    "  2. Tag the commit once it is green\n",
    "\n",
    "\u{273b} Brewed for 4s \u{b7} done 2:10 AM\n",
    "\n",
    "\u{276f}\u{a0}\n",
    "? for shortcuts \u{b7} \u{2190} for agents\n",
);

/// The same shape on codex, whose transcript marker is `\u{203a}`.
const FALSE_HOLD_CODEX_NUMBERED_ECHO: &str = concat!(
    "\u{203a} 1. Summarise the diff\n",
    "\n",
    "\u{2022} Here is the summary:\n",
    "\n",
    "  1. detector.rs gained a hold pass\n",
    "  2. send_gate.rs serialises the writes\n",
    "\n",
    "  done 2:11 AM\n",
    "\n",
    "\u{203a} Ask Codex to do anything\n",
);

/// Answer prose that names the Enter key. The phrase is what an UNNUMBERED
/// chooser's footer says, and prose says it too.
const FALSE_HOLD_CLAUDE_ENTER_PROSE: &str = concat!(
    "\u{276f} How do I finish the installer?\n",
    "\n",
    "\u{25cf} Run the installer, then press enter to continue.\n",
    "\n",
    "\u{273b} Cooked for 2s \u{b7} done 2:12 AM\n",
    "\n",
    "\u{276f}\u{a0}\n",
    "? for shortcuts \u{b7} \u{2190} for agents\n",
);

/// A WRAPPED user prompt echo. The transcript indents the continuation of a
/// long prompt to the caret's label column, so the echo and its continuation
/// are shaped exactly like a selected option and its sibling — and an answer
/// line naming the Enter key sits two rows under them.
const FALSE_HOLD_CLAUDE_WRAPPED_ECHO: &str = concat!(
    "\u{276f} Get the build green on both machines and then cut the tag once\n",
    "  the scoped suite has been clean for a full run\n",
    "\n",
    "\u{25cf} Run it, then press enter to continue.\n",
    "\n",
    "\u{273b} Brewed for 3s \u{b7} done 2:14 AM\n",
    "\n",
    "\u{276f}\u{a0}\n",
    "? for shortcuts \u{b7} \u{2190} for agents\n",
);

/// A multi-line pasted prompt echoed as a numbered block: the first line
/// carries the transcript caret, the rest are indented to its label column.
const FALSE_HOLD_CLAUDE_PASTED_LIST: &str = concat!(
    "\u{276f} 1. Get the build green\n",
    "  2. Cut the tag\n",
    "  3. Post the release note\n",
    "\n",
    "\u{25cf} All three are done.\n",
    "\n",
    "\u{273b} Cooked for 5s \u{b7} done 2:15 AM\n",
    "\n",
    "\u{276f}\u{a0}\n",
    "? for shortcuts \u{b7} \u{2190} for agents\n",
);

/// A blockquoted numbered list inside an answer. `>` is accepted as a caret
/// glyph (it is how Windows draws the input box), so the quote marker makes
/// the first row read as caret-SELECTED and the second as its sibling.
const FALSE_HOLD_CLAUDE_BLOCKQUOTE: &str = concat!(
    "\u{276f} What does the release note say?\n",
    "\n",
    "\u{25cf} It says:\n",
    "\n",
    "  > 1. Ship the tag\n",
    "  > 2. Announce it\n",
    "\n",
    "\u{273b} Baked for 2s \u{b7} done 2:16 AM\n",
    "\n",
    "\u{276f}\u{a0}\n",
    "? for shortcuts \u{b7} \u{2190} for agents\n",
);

const FALSE_HOLD_SCREENS: &[(&str, &str, &str)] = &[
    ("claude", "numbered prompt echo + numbered answer", FALSE_HOLD_CLAUDE_NUMBERED_ECHO),
    ("codex", "numbered prompt echo + numbered answer", FALSE_HOLD_CODEX_NUMBERED_ECHO),
    ("claude", "answer prose naming the Enter key", FALSE_HOLD_CLAUDE_ENTER_PROSE),
    ("claude", "wrapped prompt echo + Enter prose", FALSE_HOLD_CLAUDE_WRAPPED_ECHO),
    ("claude", "multi-line pasted numbered prompt", FALSE_HOLD_CLAUDE_PASTED_LIST),
    ("claude", "blockquoted numbered list in an answer", FALSE_HOLD_CLAUDE_BLOCKQUOTE),
];

#[test]
fn echoed_prompts_and_answer_prose_are_not_hold_states() {
    for (profile_id, what, screen) in FALSE_HOLD_SCREENS {
        let cd = compiled(profile_id);
        assert_eq!(
            detector::hold_reason(screen, &cd),
            None,
            "{profile_id}: {what} was held — sends stall until their budget expires"
        );
    }
}

#[test]
fn echoed_prompts_and_answer_prose_still_complete_their_turn() {
    for (profile_id, what, screen) in FALSE_HOLD_SCREENS {
        let cd = compiled(profile_id);
        let det = detector::run(screen, false, false, &cd)
            .unwrap_or_else(|| panic!("{profile_id}: {what} produced no detection"));
        assert_eq!(
            det.cause,
            WakeCause::TurnCompleted,
            "{profile_id}: {what} must wake as a completed turn, not a question card"
        );
    }
}
