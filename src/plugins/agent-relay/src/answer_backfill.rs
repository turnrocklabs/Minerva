// answer_backfill.rs — deliver the harness's own Markdown for a finished turn.
//
// The screen path can only report what the terminal still holds: markdown
// source the TUI rendered away, text pushed above a viewport with no
// scrollback, tool output collapsed to a one-line summary. The harness's
// session log holds all of it. When a log turn can be tied to the turn the
// relay just drove, that turn's answer replaces the scraped text.
//
// Nothing here can make an answer worse. No cwd, no log file, an ambiguous
// bind, no matching turn, or a turn the harness recorded no answer for all
// leave the scraped text exactly as it was.
//
// Tying a log turn to a screen turn, in order:
//   1. the log turn's prompt is the prompt the relay submitted, and the turn
//      opened inside the submit window — session_log's SUBMIT_WINDOW_EARLY_MS
//      to SUBMIT_WINDOW_LATE_MS around the submit instant, the same window the
//      binder admits a prompt record in. WHICH file is already
//      constrained by the binder; the time bound is what separates two turns
//      sharing one prompt text ("continue", "yes"). Temporal evidence is
//      required, not merely respected: a turn whose opening record carries no
//      readable stamp, and a prompt the relay has no submit time for, are both
//      no evidence at all, and the screen text stands;
//   2. a scraped answer under SHORT_ANSWER_CHARS holds too few words to
//      cross-check against, so rule 1 alone decides it — and only when the
//      cursor vouches for which turns are in play. Only a cursor that already
//      delivered a cross-checked answer under THIS prompt vouches: every
//      submission re-runs the binder, and a turn the binder ran on reads a
//      window nothing has read under that prompt. A short scrape there is
//      refused outright rather than passed on: a one-word text is contained in
//      every answer holding that word, which is what rules 3 and 4 would read.
//      In practice backfill runs once per submission, so a short answer is
//      backfilled only on a re-read of the same prompt and otherwise keeps
//      its screen text, which loses nothing on a one-word answer;
//   3. otherwise one normalised text contains the other;
//   4. otherwise MIN_WORD_COVERAGE of the log answer's words appear in the
//      scraped text.
//
// Rule 4 exists because rule 3 was measured to fail on real pairs: a fenced
// block's language tag is recorded but never rendered, and a tool-summary line
// lands inside the answer's run of screen rows. On the paired corpus, true
// pairs score 0.984-1.000 and no mismatched pair exceeds 0.62.
//
// Known limit: two terminals in one directory that sent the same prompt text
// within the submit window of each other are not told apart by these rules.
// While both transcripts are on disk the binder refuses them as Ambiguous, so
// the exposure is the moment when only the sibling's log has been flushed and
// ours has not. What is left of it there is narrow: that file is freshly bound,
// so a short scrape is refused, and a longer one carries the sibling's answer
// only when that answer also passes rule 3 or rule 4 against our screen text.
// Nor does such a bind outlive the prompt it was made for: every submission
// re-puts the question to the binder before the cached path is read again, and
// a short scrape is refused on every turn that question was put on.

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, VecDeque};
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::session_log::{self, Binding, LogRoots};
use crate::terminal_facts::{Prompt, SessionFacts};
use crate::turn_extract::{self, Cursor, Harness, Turn};
use crate::watcher;

/// Envelope values for the field naming where a delivered answer came from.
pub const SOURCE_SCREEN: &str = "screen";
pub const SOURCE_LOG: &str = "log";

/// Below this many scraped characters there is nothing to cross-check with, so
/// a prompt match alone carries the log's answer.
const SHORT_ANSWER_CHARS: usize = 10;

/// Fraction of the log answer's words that must also appear in the scraped
/// text. Set inside the measured gap between true pairs (>= 0.98) and
/// mismatched ones (<= 0.62).
const MIN_WORD_COVERAGE: f64 = 0.90;

/// Fruitless searches against ONE unchanged prompt set before a watch stops
/// walking the log tree. A relay-driven turn appends a prompt and so lifts the
/// cap again; what this bounds is the repeats within one prompt — several
/// detections for one send, and turns read out of a terminal nothing is being
/// sent to.
const MAX_SEARCHES: u8 = 3;

/// Quiet period after which a capped watch may walk the tree once more. The
/// cap must never be permanent: a harness relaunched in the same tab, a
/// `/clear` that opened a new file, and a log flushed after the first turns
/// all begin binding with no change the relay can see. One walk a minute per
/// terminal is a small fraction of a turn, which runs for seconds to minutes.
const SEARCH_RETRY: Duration = Duration::from_secs(60);

// ---------------------------------------------------------------------------
// Per-watch binding cache
// ---------------------------------------------------------------------------

/// Which log file a watched terminal writes and how far it has been read.
/// Cached in the watch session so repeated turns on one prompt cost no search
/// at all. It is only ever a cache: every field is re-derivable from the
/// terminal's facts, and the path is re-derived on every new prompt.
#[derive(Debug, Clone, Default)]
pub struct LogBinding {
    path: Option<PathBuf>,
    cursor: Cursor,
    searches: u8,
    /// Fingerprint of the retained prompts the last search ran against, over
    /// their bodies and submit instants.
    prompts_searched: u64,
    /// Earliest instant a capped watch may walk the tree again. None before
    /// the first search.
    retry_at: Option<Instant>,
    /// Fingerprint of the prompt set under which the cached path last
    /// delivered a cross-checked answer; only such a delivery lets a later
    /// re-read under the same prompts trust the cursor for a short scrape.
    vouched_for: u64,
    last_stage: Option<&'static str>,
    last_verdict: Option<&'static str>,
    last_candidates: usize,
    last_undecided: usize,
    last_source: &'static str,
    last_reason: &'static str,
}

impl LogBinding {
    /// Record that the cached path answered under `prompts` with a text the
    /// scrape could cross-check. A short scrape proves nothing about the
    /// path, so it leaves the marker untouched.
    fn vouch(&mut self, prompts: u64, scraped: &str) {
        if scraped.trim().chars().count() >= SHORT_ANSWER_CHARS {
            self.vouched_for = prompts;
        }
    }

    /// Extract from the cached path and pick this turn's answer. Advances the
    /// cursor past every turn read, so a turn is offered once.
    fn take_answer(&mut self, harness: Harness, candidate: &Candidate) -> Option<String> {
        let path = self.path.as_ref()?;
        let extraction = turn_extract::extract(path, harness, self.cursor).ok()?;
        self.cursor = extraction.cursor;
        // An extraction that skipped an over-budget span read a window nothing
        // has read before, exactly as a fresh bind does, and the turns of the
        // skipped span are not in it.
        let candidate = Candidate {
            rebound: candidate.rebound || extraction.skipped,
            ..*candidate
        };
        choose(&candidate, &extraction.turns)
    }

    /// Put the binding back to the binder for a prompt it was not derived
    /// under, before the cached path is trusted for that prompt. A verdict that
    /// does not name exactly the cached path — Ambiguous, NoLog, or another
    /// file — drops the path and its cursor, so a sibling bound while our own
    /// log was still unflushed cannot answer a later turn from the cache. The
    /// walk counts against the cap like any other. None when nothing has been
    /// submitted since the last search, where the cache stands and the cap
    /// alone bounds the walks.
    fn rebind_on_new_prompt(
        &mut self,
        profile_id: &str,
        facts: &SessionFacts,
        roots: &LogRoots,
    ) -> Option<Binding> {
        let fingerprint = prompt_fingerprint(&facts.prompts);
        if fingerprint == self.prompts_searched {
            return None;
        }
        self.prompts_searched = fingerprint;
        self.searches = 1;
        self.retry_at = Some(Instant::now() + SEARCH_RETRY);

        let verdict = session_log::bind(&facts.to_terminal_facts(profile_id), roots);
        let names_cache = match (&verdict, self.path.as_deref()) {
            (Binding::Bound(found), Some(cached)) => found.as_path() == cached,
            _ => false,
        };
        if !names_cache {
            self.path = None;
            self.cursor = Cursor::default();
            self.vouched_for = 0;
        }
        Some(verdict)
    }

    /// May a log-tree walk run this turn? The cap bounds repeated walks, and
    /// lifts on either thing that can turn a failed bind into a good one: the
    /// retained prompts changed — any submission changes them, and their
    /// newest entry is what the binder matches on — or enough time passed for
    /// the harness to have written a file that was not there before. Never
    /// consulted for a cached path that still yields turns, which is decided
    /// before this is called.
    fn may_search(&mut self, prompts: &VecDeque<Prompt>) -> bool {
        let fingerprint = prompt_fingerprint(prompts);
        let quiet = self.retry_at.is_some_and(|at| Instant::now() >= at);
        if fingerprint != self.prompts_searched || quiet {
            self.searches = 0;
            self.prompts_searched = fingerprint;
        }
        self.searches < MAX_SEARCHES
    }

    pub(crate) fn diagnostic(&self) -> serde_json::Value {
        serde_json::json!({
            "source": self.last_source,
            "reason": self.last_reason,
            "stage": self.last_stage,
            "verdict": self.last_verdict,
            "candidates": self.last_candidates,
            "undecided": self.last_undecided,
            "searches": self.searches,
            "bound": self.path.is_some(),
        })
    }

    fn begin_attempt(&mut self) {
        self.last_stage = None;
        self.last_verdict = None;
        self.last_candidates = 0;
        self.last_undecided = 0;
        self.last_source = SOURCE_SCREEN;
        self.last_reason = "search_deferred";
    }
}

/// Order-sensitive digest of the retained prompts, over body AND submit
/// instant. The instants are what make every submission change the digest: a
/// set of repeats — "continue" eight times — holds one body throughout, and a
/// digest over bodies alone would leave a ninth send indistinguishable from no
/// send at all.
fn prompt_fingerprint(prompts: &VecDeque<Prompt>) -> u64 {
    let mut hasher = DefaultHasher::new();
    for prompt in prompts {
        prompt.text.hash(&mut hasher);
        prompt.submitted_ms.hash(&mut hasher);
    }
    hasher.finish()
}

// ---------------------------------------------------------------------------
// Turn path
// ---------------------------------------------------------------------------

/// The answer the harness recorded for the turn `terminal_id` just finished,
/// or None to keep the scraped text. Called with the prompt the relay
/// submitted and the cleaned screen text, before redaction and truncation.
pub fn for_terminal(terminal_id: &str, prompt: &str, scraped: &str) -> Option<String> {
    let Some((profile_id, facts, mut binding)) = watcher::backfill_inputs(terminal_id) else {
        log::debug!("backfill: terminal={terminal_id} source=screen reason=no_watch");
        return None;
    };
    binding.begin_attempt();
    let Some(roots) = LogRoots::from_env() else {
        log::debug!("backfill: terminal={terminal_id} source=screen reason=no_log_roots");
        binding.last_reason = "no_log_roots";
        watcher::store_log_binding(terminal_id, binding);
        return None;
    };
    log::debug!(
        "backfill: terminal={terminal_id} attempt profile={profile_id} cwd={} start={} prompts={} cached={}",
        facts.cwd.is_some(), facts.start_ms.is_some(), facts.prompts.len(), binding.path.is_some()
    );
    let answer = backfill(&profile_id, &facts, &roots, &mut binding, prompt, scraped);
    binding.last_source = if answer.is_some() { SOURCE_LOG } else { SOURCE_SCREEN };
    binding.last_reason = if answer.is_some() {
        "matched_turn"
    } else {
        match binding.last_verdict {
            Some("bound") => "bound_no_matching_turn",
            Some(reason) => reason,
            None => "search_deferred",
        }
    };
    log::debug!(
        "backfill: terminal={terminal_id} source={} binding={} searches={}",
        if answer.is_some() {
            SOURCE_LOG
        } else {
            SOURCE_SCREEN
        },
        binding.path.is_some(),
        binding.searches
    );
    watcher::store_log_binding(terminal_id, binding);
    answer
}

/// Backfill against explicit roots and an explicit cache. The binding is
/// re-derived on every submission before the cached path is read for it, and
/// within one prompt a cached path that stops yielding this terminal's turns
/// has been superseded — a harness `/clear` opens a new log file — so a miss
/// re-derives the binding once.
fn backfill(
    profile_id: &str,
    facts: &SessionFacts,
    roots: &LogRoots,
    binding: &mut LogBinding,
    prompt: &str,
    scraped: &str,
) -> Option<String> {
    let harness = Harness::from_profile_id(profile_id)?;
    let mut candidate = Candidate {
        prompt,
        scraped,
        submitted_ms: facts.submitted_ms(prompt),
        rebound: false,
    };

    let fresh = binding.rebind_on_new_prompt(profile_id, facts, roots);
    if let Some(verdict) = fresh.as_ref() {
        record_binding_verdict(binding, "new_prompt", verdict);
    }
    // A turn the binder ran on reads a window no cursor vouched for under this
    // prompt, whichever file the verdict named — the cached one included. So
    // does a re-read under prompts the cached path has not yet answered with
    // a cross-checked text: an earlier read that delivered nothing left the
    // path but vouched for none of its turns.
    let prompts_now = prompt_fingerprint(&facts.prompts);
    candidate.rebound = fresh.is_some() || binding.vouched_for != prompts_now;

    if let Some(answer) = binding.take_answer(harness, &candidate) {
        binding.searches = 0;
        binding.vouch(prompts_now, scraped);
        return Some(answer);
    }
    let verdict = match fresh {
        Some(verdict) => verdict,
        None => {
            if !binding.may_search(&facts.prompts) {
                return None;
            }
            binding.searches += 1;
            binding.retry_at = Some(Instant::now() + SEARCH_RETRY);
            let verdict = session_log::bind(&facts.to_terminal_facts(profile_id), roots);
            record_binding_verdict(binding, "retry", &verdict);
            verdict
        }
    };
    let found = match verdict {
        Binding::Bound(path) => path,
        // Ambiguous is a refusal, not a candidate list: a wrong transcript
        // would deliver another terminal's answer into this chat.
        Binding::NoLog | Binding::Ambiguous { .. } | Binding::Unsupported(_) => return None,
    };
    if binding.path.as_deref() == Some(found.as_path()) {
        return None;
    }
    // A file nothing has read before is read from its tail, not from offset 0:
    // the turn just driven is at the end, and the history before the window was
    // answered on the screen long ago.
    binding.cursor = turn_extract::tail_cursor(&found);
    binding.path = Some(found);
    candidate.rebound = true;

    let answer = binding.take_answer(harness, &candidate);
    match answer {
        Some(_) => {
            binding.searches = 0;
            binding.vouch(prompts_now, scraped);
        }
        // A rebind that delivered nothing leaves no binding behind. Keeping the
        // path would make the next turn read it as an established one — cursor
        // vouching for the window, no walk of the tree — so a set the binder
        // would now refuse as Ambiguous would never be put to it again.
        None => {
            binding.path = None;
            binding.cursor = Cursor::default();
            binding.vouched_for = 0;
        }
    }
    answer
}

fn record_binding_verdict(binding: &mut LogBinding, stage: &'static str, verdict: &Binding) {
    binding.last_stage = Some(stage);
    binding.last_candidates = 0;
    binding.last_undecided = 0;
    match verdict {
        Binding::Bound(_) => binding.last_verdict = Some("bound"),
        Binding::NoLog => binding.last_verdict = Some("no_log"),
        Binding::Unsupported(_) => binding.last_verdict = Some("unsupported"),
        Binding::Ambiguous {
            candidates,
            undecided,
        } => {
            binding.last_verdict = Some("ambiguous");
            binding.last_candidates = candidates.len();
            binding.last_undecided = undecided.len();
        }
    }
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

/// One finished screen turn, as the matcher is allowed to see it.
#[derive(Clone, Copy)]
struct Candidate<'a> {
    /// Prompt body the relay submitted for this turn.
    prompt: &'a str,
    /// Cleaned screen text, before redaction and truncation.
    scraped: &'a str,
    /// Epoch milliseconds the relay submitted the prompt; 0 when unknown.
    submitted_ms: i64,
    /// True when no cursor vouches for the window these turns came from: the
    /// binder ran on this turn, or a span was skipped as over budget. Only a
    /// cursor left by an earlier detection of THIS prompt vouches.
    rebound: bool,
}

/// The log answer that may stand in for the scrape, or None to keep the
/// screen. The LAST match wins: the turn the relay just drove is the most
/// recent one, and a prompt can legitimately be sent twice.
fn choose(candidate: &Candidate, turns: &[Turn]) -> Option<String> {
    let turn = turns.iter().rev().find(|turn| {
        opened_for_this_submit(candidate.submitted_ms, turn.start_ms)
            && session_log::prompt_matches(candidate.prompt, &turn.prompt)
    })?;

    // An aborted codex turn records no assistant text at all, and the screen
    // is then the only record of the partial answer.
    if turn.answer.trim().is_empty() {
        return None;
    }
    if candidate.scraped.trim().chars().count() < SHORT_ANSWER_CHARS {
        // Rule 2: nothing to cross-check with, so the cursor has to vouch for
        // which turns are in play. A window read under a fresh binder verdict
        // vouches for none, and the rules below would take a one-word scrape as
        // a match on any answer holding that word.
        return (!candidate.rebound).then(|| turn.answer.clone());
    }

    let log_text = normalise(&turn.answer);
    let screen_text = normalise(candidate.scraped);
    if contains_words(&screen_text, &log_text) || contains_words(&log_text, &screen_text) {
        return Some(turn.answer.clone());
    }
    if word_coverage(&log_text, &screen_text) >= MIN_WORD_COVERAGE {
        return Some(turn.answer.clone());
    }
    None
}

/// Could a turn stamped `start_ms` be the one submitted at `submitted_ms`?
/// Both stamps must be known: a zero on either side is an absent measurement,
/// and an absent measurement admits every turn sharing the prompt text —
/// including a repeat of it in another terminal or an hour earlier. The window
/// itself is the binder's, which asks this of the same instants.
fn opened_for_this_submit(submitted_ms: i64, start_ms: i64) -> bool {
    start_ms != 0 && session_log::within_submit_window(submitted_ms, start_ms)
}

/// Lowercase, every non-alphanumeric run to one space, trimmed. Markdown
/// markers, box glyphs and line breaks all collapse to the same separator, so
/// rendered and source forms of one answer normalise alike.
fn normalise(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_alphanumeric() {
            out.extend(c.to_lowercase());
        } else if !out.ends_with(' ') {
            out.push(' ');
        }
    }
    out.trim().to_string()
}

/// Substring containment on whole words: padding both sides keeps a short
/// needle from matching inside a longer word.
fn contains_words(haystack: &str, needle: &str) -> bool {
    !needle.is_empty() && format!(" {haystack} ").contains(&format!(" {needle} "))
}

/// Fraction of `needle`'s words present in `haystack`, counting repeats once
/// each. Word order is not checked — the prompt match already fixes which turn
/// is in play, and an ordered check costs the product of the two lengths.
fn word_coverage(needle: &str, haystack: &str) -> f64 {
    let mut available: HashMap<&str, usize> = HashMap::new();
    for word in haystack.split(' ').filter(|w| !w.is_empty()) {
        *available.entry(word).or_default() += 1;
    }
    let mut total = 0usize;
    let mut found = 0usize;
    for word in needle.split(' ').filter(|w| !w.is_empty()) {
        total += 1;
        if let Some(count) = available.get_mut(word).filter(|c| **c > 0) {
            *count -= 1;
            found += 1;
        }
    }
    if total == 0 {
        return 0.0;
    }
    found as f64 / total as f64
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

// The tests are a module of this file like any other; they live next door so
// that the matcher and its corpus harness each stay a readable file.
#[cfg(test)]
#[path = "answer_backfill_tests.rs"]
mod tests;
