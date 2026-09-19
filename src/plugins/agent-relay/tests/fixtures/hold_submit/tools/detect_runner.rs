// detect_runner — run agent-relay's detector offline over a screen capture.
//
// Includes the crate's real src/detector.rs and src/profiles.rs. Reads screen
// text on stdin (the rows host.terminal.wait hands the watcher, i.e. what
// tools/vtreplay.c prints), writes one JSON line: profile, is_busy, cause,
// method.
//
// Usage: detect_runner <profile-id>   (claude | codex | opencode)

#[path = "../../../../src/profiles.rs"] mod profiles;
#[path = "../../../../src/detector.rs"] mod detector;

use std::io::Read;

fn main() {
    let id = std::env::args().nth(1).unwrap_or_else(|| "claude".to_string());
    let mut screen = String::new();
    std::io::stdin().read_to_string(&mut screen).expect("read stdin");
    let p = profiles::builtin_profiles().into_iter().find(|p| p.id == id)
        .expect("unknown profile id");
    let cd = detector::CompiledDetection::from_profile(&p).expect("compile");
    let busy = detector::is_busy(&screen, &cd);
    // bell_rung / shell_exited are host-reported fields; offline they are false.
    let det = detector::run(&screen, false, false, &cd);
    let (cause, method) = match det {
        Some(d) => (d.cause.as_str().to_string(), d.method.as_str().to_string()),
        None => ("none".to_string(), "none".to_string()),
    };
    println!("{{\"profile\":\"{}\",\"is_busy\":{},\"cause\":\"{}\",\"method\":\"{}\"}}",
             id, busy, cause, method);
}
