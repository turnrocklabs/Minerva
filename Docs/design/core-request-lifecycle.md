# Core request completion and local cancellation

`Core.send_message(service, action, data, completion, timeout)` creates a request
ID, installs its owner and signal listeners, then sends. Service requests require
a connected and registered socket. A send failure completes immediately and is
not retried. Registration installs its own correlated listener before sending;
its terminal hook commits readiness before other registration listeners resume.

The returned public type remains `Core.AwaitMessage`. Existing fluent filters,
`with_timeout(seconds)`, and nullable JSON `receive()` remain available. New
callers should consume `await request.receive_result()`:

```gdscript
var request := Core.send_message(service, action, data, "either", 120.0)
var result := await request.receive_result()
if not result.success:
    show_error(result.error_code, result.error_message)
elif result.kind == "binary":
    consume_audio(result.binary)
else:
    consume_json(result.json)
```

Completion modes are configured before sending:

- `json` completes on the matching JSON response.
- `binary` completes on one validated voice audio file; JSON announcements do
  not complete it. Correlated errors remain terminal.
- `either` completes on binary audio or a JSON result. A JSON result declaring
  `transfer_mode: binary` is an announcement and waits for the audio.
- `both` waits for JSON and binary, in either order, retaining at most one audio
  result for that request.

Successful results include `success`, `request_id`, `kind`, `json`, and `binary`.
Failures include `error_code`, `error_message`, and diagnostic JSON if received.
Common local codes are `core_offline`, `send_failed`, `core_disconnected`,
`timeout`, `cancelled`, and `invalid_binary`. Remote codes are retained.
Legacy `receive()` returns null for local failures, including cancellation after
an announcement; remote JSON error envelopes remain available as before.

`cancel()` terminates locally once, disconnects listeners, removes the timer and
pending entry, and discards associated voice streams. CoreProvider connects the
existing history-scoped chat Stop hook to this operation and cancels on provider
exit. This does not claim that the backend stopped computing. Late responses
cannot resume the request, and there are no completion tombstones or retry queues
for this API.

Binary voice frames need an active request owner before NEW_MESSAGE can allocate
state. One request admits one stream, and the stream ID cannot belong to another
voice or artifact/media transfer. The receiver validates the one-file count,
path-header length, raw framing declaration, exact byte size and empty END.
Completed audio belongs to the result, not a global completed-buffer stash.
Unknown non-header frames are rejected before artifact/media collectors run.
The existing direct artifact download path and its indexed format remain separate.

`receive_all()` is an explicitly long-lived publication subscription. It has no
request timer; its owner must call `cancel()` when replacing or leaving the view.
Disconnect also detaches it. Autocoder cancels its seven retained handlers on
replacement, disconnect and view exit. An active request cannot change its ID,
completion mode, or become a subscription. Updating its timeout remains supported.

Focused local verification:

```sh
XDG_DATA_HOME=/tmp/minerva-t7-test-userdata godot --headless --path src --script test/test_core_request_lifecycle.gd
XDG_DATA_HOME=/tmp/minerva-t7-test-userdata godot --headless --path src --script test/test_core_binary_voice_routing.gd
```

These fixtures exercise real request builders, incoming dispatch, chat Stop and
binary routing with a local socket seam. They do not certify deployed services,
WAN recovery or remote cancellation.
