# Manual Codex MCP live-tool probe

Tracking: Minerva Docket `01a0d08bdaf472cab662b5be5f081e27`.

This opt-in experiment starts an isolated loopback HTTP server and a real
`codex exec` model run. It consumes model usage. It does not launch Godot,
connect to Minerva, edit Codex configuration, or operate the desktop.
Requires Python 3 and an authenticated `codex` CLI on PATH.

```sh
python3 tests/probes/codex_mcp_live_tools.py
python3 tests/probes/codex_mcp_live_tools.py --prepublished
```

The server negotiates MCP 2025-06-18, advertises `tools.listChanged=true`,
issues a session ID, and offers a chunked SSE GET stream. Initially only
`publish_tool` exists. Calling it adds `newly_added_tool` and sends
`notifications/tools/list_changed` on the GET stream. The new tool requires
a random proof value disclosed only by its schema. The tool-call response
does not disclose that value. The control exposes the new tool from startup.

Each invocation prints an artifact directory with `wire.jsonl`, `codex.jsonl`,
`codex.stderr`, and `summary.json`. For the live test, require the initial
one-tool catalog, sent notification, subsequent two-tool catalog, and valid
proof call. The control only requires the two-tool catalog and valid proof.
The process exit code alone is not a test verdict: Codex can exit successfully
after reporting that discovery failed. Inspect the summary and wire events.

Only the two fixture tools are preapproved for the child run. User MCP
configuration is ignored, the child uses the read-only sandbox, and its prompt
forbids shell/HTTP workarounds. The probe is bounded to 150 seconds per run.
This is a narrowly scoped fixture, not a general MCP server or conformance suite.

## Observed September 23, 2026 — Codex CLI 0.156.1

| Check | Live addition | Startup control |
| --- | --- | --- |
| Negotiated version | 2025-06-18 | 2025-06-18 |
| Client opened GET SSE stream | Yes | Yes |
| Initial catalog | publish_tool only | Both tools |
| Change notification written/flushed | Yes | Not needed |
| tools/list after notification | No | Not applicable |
| New tool called with correct proof | No | Yes |

Live run artifacts: `/var/folders/11/02t900kn7472gffnh8cmm4t40000gn/T/minerva-mcp-live-probe-ayx8v527`.
Control artifacts: `/var/folders/11/02t900kn7472gffnh8cmm4t40000gn/T/minerva-mcp-live-probe-iom3xv6x`.
Those temporary directories are local evidence, not portable dependencies.

The first setup attempt was inconclusive because Codex required tool approval;
it sent no change notification. The two runs above explicitly approved only
the fixture tools. A harmless connection-reset traceback during teardown of
the live run was handled in the retained fixture; it happened after the turn.

Conclusion: in this single `codex exec` turn, a server-emitted notification
did not result in a catalog refresh. Startup discovery of the same schema
worked. This does not establish behavior across user turns in a persistent
app-server session, other Codex builds, or modern MCP subscriptions. A server
write/flush is observed; client notification-handler execution is not instrumented.
Do not infer that adding legacy notifications to Minerva alone will solve this
client's hot-install workflow, or that the optional feature's absence violates MCP.

References:

- https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- https://modelcontextprotocol.io/specification/2025-06-18/server/tools
