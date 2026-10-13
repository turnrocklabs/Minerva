SpeechDelivery owns admissions, playback receipts, topic supersede and counts.
SpeechLog stores version 1 JSON records in the profile's `speech-log/` directory.
No audio is stored, and no record is automatically deleted or capped. AtomicFile
provides old-or-new replacement after a process restart; it does not provide an
fsync guarantee across power loss. Corrupt or unsupported records are retained
and surfaced while valid records continue; their filenames reserve IDs. Explicit delete removes text and voice parameters through a hidden
metadata tombstone, preserving supersede ordering. A playing item's exemption is
stored on the new admission, so it also survives process restart.

Replay supports granted plugin speakers and the current OS output. It never
changes device preferences. A playing receipt means live delivery remains in flight. A queued receipt confirms saved undeliverable text, not playback.
Only terminal successful output completion marks heard. Active items are excluded from missed counts. Replay is an explicit output action; historical origin remains record metadata. Reconnect never starts
automatic playback. Topic keys are exact `(producer namespace, topic)` pairs;
explicit statuses use `explicit`, remote turns use their plugin id. Already
playing speech is excluded from supersede; separate cancel and barge-in still
apply. Plugin views include only records originally routed to that plugin.

Exit table: Q = saved unheard, H = heard, X = derived superseded; failed replay
preserves an existing H/X flag. Caller errors include the concrete reason. OLED
is the plugin's projection of receipt/count and connection loss, tested in F2/I.

| State | Cancel | Timeout | Disconnect | Revoke | Crash | Reconnect |
|---|---|---|---|---|---|---|
| Admission | refuse or committed Q; cancelled | refuse or Q; timeout | committed Q; queued/offline | refuse or Q; denied | committed Q recovered; offline | count snapshot; no playback |
| Summary/synthesis | Q; stopped | Q; failure/missed | Q; queued/offline | Q; denied | Q recovered; offline | count snapshot; stale completion refused |
| Streaming | Q; stopped/missed | Q; failure/missed | Q; queued/offline | Q; denied | Q recovered; offline | count snapshot; no retry |
| Drain pending | Q; stopped/missed | Q; unknown/missed | Q; unknown/offline | Q; denied | Q recovered, never inferred heard | count snapshot; stale ACK refused |
| Q | unchanged; no operation | unchanged | offline | playback denied | Q recovered | count snapshot only |
| H | H preserved on replay failure | H preserved | offline | playback denied | H recovered | replay remains explicit |
| X | X preserved on replay failure | X preserved | offline | playback denied | X recovered | replay remains explicit |

Positive terminal completion after EOS gives H. Mark/delete persist before their
receipt and count event. Store failure refuses success and surfaces the error to
caller/UI. Explicit delete cancels active playback before committing its tombstone; replay refuses an already active item. Explicit mark changes heard state independently.
