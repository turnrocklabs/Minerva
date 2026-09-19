// clean_pipeline — run agent-relay's read_turn cleaning pipeline offline.
//
// Mirrors read_turn_core steps 3a-3d for a session with no named filter rules
// installed (the default): chrome_filter::filter -> redact -> truncate.
// Reads the raw screen text on stdin, writes the cleaned text on stdout and a
// one-line envelope (truncated / omitted_chars) on stderr.

use std::io::Read;

#[path = "../../../../src/chrome_filter.rs"]
mod chrome_filter;

fn main() {
    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw).expect("read stdin");
    let cleaned = chrome_filter::filter(&raw);
    let cleaned = chrome_filter::redact(&cleaned);
    let t = chrome_filter::truncate(&cleaned, chrome_filter::MAX_OUTPUT_CHARS);
    print!("{}", t.text);
    eprintln!("truncated={} omitted_chars={}", t.truncated, t.omitted_chars);
}
