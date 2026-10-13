# Authentication diagnostic boundaries

| State | Success | Refusal | Malformed |
| --- | --- | --- | --- |
| Response callback | token stored, diagnostics safe | status fixed, token cleared | token cleared, no body logged |
| Persisted/UI log | status only | fixed error only | fixed parse failure only |

Coverage: src/test/test_core_auth_logs.gd::run drives actual callback and HCP file/UI owner for all cells. Stdout/stderr capture is scanned by the isolated job; no real credentials. No new persisted settings or protocol exits.

Expanded source: real verbose WebSocket registration preserves auth wire bytes; auth-error and raw HCP signal logs use the same allowlist. Core configured URLs now omitted from diagnostics. Other filename/request-id counters are not auth payload logging.
