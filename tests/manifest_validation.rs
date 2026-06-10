// Integration tests for agent-relay manifest.json correctness.
// Mirrors the pattern from scansort/tests/manifest_validation.rs.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

fn load_manifest() -> serde_json::Value {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("manifest.json");
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Failed to read manifest.json at {}: {}", path.display(), e));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("manifest.json is not valid JSON: {}", e))
}

fn tools(manifest: &serde_json::Value) -> &Vec<serde_json::Value> {
    manifest["tools"]
        .as_array()
        .expect("manifest.json must have a top-level 'tools' array")
}

// ── Test 1: every tool has the correct prefix and all names are unique ───────

#[test]
fn test_tool_names_prefix_and_unique() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let mut seen: HashMap<&str, usize> = HashMap::new();

    for (i, tool) in tool_list.iter().enumerate() {
        let name = tool["name"]
            .as_str()
            .unwrap_or_else(|| panic!("Tool at index {} has no 'name' field", i));

        assert!(
            name.starts_with("minerva_agent_relay_"),
            "Tool at index {} has name '{}' which does not start with 'minerva_agent_relay_'",
            i,
            name
        );

        if let Some(prev) = seen.get(name) {
            panic!("Duplicate tool name '{}' at indices {} and {}", name, prev, i);
        }
        seen.insert(name, i);
    }
}

// ── Test 2: events array declares agent_relay.turn_completed ─────────────────

#[test]
fn test_events_contains_turn_completed() {
    let manifest = load_manifest();

    let events = manifest["events"]
        .as_array()
        .expect("manifest.json must have a top-level 'events' array");

    let has_turn_completed = events
        .iter()
        .any(|e| e["name"].as_str() == Some("agent_relay.turn_completed"));

    assert!(
        has_turn_completed,
        "manifest.json events array must contain 'agent_relay.turn_completed'. \
         Current events: {:?}",
        events.iter().filter_map(|e| e["name"].as_str()).collect::<Vec<_>>()
    );
}

// ── Test 3: required tools are all present ────────────────────────────────────

#[test]
fn test_required_tools_present() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let required = [
        "minerva_agent_relay_watch_start",
        "minerva_agent_relay_watch_stop",
        "minerva_agent_relay_watch_status",
        "minerva_agent_relay_send",
        "minerva_agent_relay_read_clean",
        "minerva_agent_relay_read_turn",
        "minerva_agent_relay_filter_set",
        "minerva_agent_relay_filter_list",
        "minerva_agent_relay_filter_delete",
        "minerva_agent_relay_profile_get",
        "minerva_agent_relay_profile_set",
        "minerva_agent_relay_profiles_list",
    ];

    for target in &required {
        let found = tool_list.iter().any(|t| t["name"].as_str() == Some(target));
        assert!(found, "Required tool '{}' not found in manifest.json", target);
    }
}

// ── Test 4: tools with required args declare input_schema ────────────────────

#[test]
fn test_tools_with_args_have_input_schema() {
    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    // These tools have required arguments — they must have input_schema.
    let tools_with_required_args = [
        "minerva_agent_relay_watch_start",
        "minerva_agent_relay_watch_stop",
        "minerva_agent_relay_watch_status",
        "minerva_agent_relay_send",
        "minerva_agent_relay_filter_set",
        "minerva_agent_relay_filter_delete",
        "minerva_agent_relay_profile_get",
        "minerva_agent_relay_profile_set",
    ];

    for target in &tools_with_required_args {
        let tool = tool_list
            .iter()
            .find(|t| t["name"].as_str() == Some(target))
            .unwrap_or_else(|| panic!("Tool '{}' not found in manifest.json", target));

        let schema = tool.get("input_schema").unwrap_or_else(|| {
            panic!("Tool '{}' is missing 'input_schema'", target)
        });

        assert_eq!(
            schema["type"].as_str(),
            Some("object"),
            "Tool '{}' input_schema.type must be 'object'",
            target
        );

        // Verify required array exists and is non-empty for tools that have required args.
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(
            required.map(|r| !r.is_empty()).unwrap_or(false),
            "Tool '{}' input_schema.required must be a non-empty array",
            target
        );
    }
}

// ── Test 5: permissions declare required host capabilities ────────────────────

#[test]
fn test_required_host_capabilities_declared() {
    let manifest = load_manifest();

    let caps = manifest["permissions"]["host_capabilities"]
        .as_array()
        .expect("permissions.host_capabilities must be an array");

    let cap_strs: Vec<&str> = caps.iter().filter_map(|v| v.as_str()).collect();

    let required_caps = [
        "host.terminal.list",
        "host.terminal.read",
        "host.terminal.write",
        "host.terminal.wait",
        "host.providers.chat",
    ];

    for cap in &required_caps {
        assert!(
            cap_strs.contains(cap),
            "Required capability '{}' not found in permissions.host_capabilities. \
             Declared: {:?}",
            cap,
            cap_strs
        );
    }
}

// ── Test 6: every manifest tool has a dispatch arm in main.rs ─────────────────

#[test]
fn test_manifest_tools_have_handlers_in_main_rs() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let main_rs_path = manifest_dir.join("src/main.rs");

    let main_rs = match fs::read_to_string(&main_rs_path) {
        Ok(s) => s,
        Err(_) => {
            eprintln!("SKIP test_manifest_tools_have_handlers_in_main_rs: could not read src/main.rs");
            return;
        }
    };

    let manifest = load_manifest();
    let tool_list = tools(&manifest);

    let mut missing: Vec<&str> = Vec::new();

    for tool in tool_list.iter() {
        let name = tool["name"].as_str().expect("tool has name");
        let pattern = format!("\"{}\"", name);
        if !main_rs.contains(&pattern) {
            missing.push(name);
        }
    }

    assert!(
        missing.is_empty(),
        "The following manifest tools have no string literal in src/main.rs dispatch: {:?}",
        missing
    );
}
