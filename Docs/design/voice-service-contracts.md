# Voice service outcomes and ownership

`VoiceServiceClient` exposes per-call `transcribe_result`, `transcribe_auto_result`,
`synthesize_result`, `synthesize_auto_result`, `list_voices_result`,
`get_status_result`, and `summarize_for_speech_result` methods. Successful results
carry `text`, `audio`, `voices`, or `status`; failures carry `success: false`,
`error_code`, and `error_message`. The older string/byte/array wrappers remain for
compatibility. New callers should use the result methods.

An empty transcript is successful silence. It neither inserts text nor invokes
Whisper fallback. An empty voice inventory or status object is also a valid
response. Failed discovery remains a failure in MCP. Synthesis rejects empty or
undecodable audio before playback. Summary fallback returns its deterministic
shortened text together with `fallback_reason` and `fallback_message`; cancellation
and operation misuse are failures, not summary fallback conditions.

## Request and playback ownership

An optional `VoiceOperation` owns one active Core request at a time. Cancellation
detaches that request immediately using the [Core lifecycle](core-request-lifecycle.md).
It does not cancel remote computation. A cancelled or busy operation cannot start
another request or invoke paid fallback. Already-running Whisper HTTP requests
retain their existing lifecycle; operation cancellation does not abort that HTTP
transport.

`SpeechOperation` additionally owns playback. Chat replacement, Stop, and teardown
finish the operation once, disconnect its player listener, stop playback, and
release busy state and gateway notification. This does not depend on
`AudioStreamPlayer.stop()` emitting `finished`. Old completions cannot release a
replacement operation. MCP and Preview playback use their own players.

PTT owns its Core transcription separately. Stop, replacement, and teardown
invalidate its owner before cancellation, so late results cannot write into a new
target. Gateway transcription owns a separate set of operations; explicit gateway
stop and pane teardown invalidate those results and clear queued utterances without
cancelling an already-dispatched chat. Results from any already-running Whisper
fallback are ignored after their owner is invalidated.

## Voice identity and discovery

Configured stable `voice_name` takes precedence over an ephemeral `voice_id`.
Selection must resolve unambiguously. Missing, duplicate, or unsupported saved
choices remain visible and preserved; refreshing inventory never saves the first
row or substitutes another backend. Unknown saved backend/model values remain
visible as explicit legacy choices.

Successful inventories retain backend metadata, including `backend_family`,
`available_backends`, `voice_type`, `latency_class`, `quality_class`, and
`capabilities`. Advertised backend support constrains selection. Missing metadata
uses the explicit legacy policy: send the configured voice/backend and existing
service topics unchanged. Metadata is displayed without guessing capabilities.

Discovery adds no per-utterance RPC. Cache entries are scoped to their queried
backend and connection epoch. The newest successful applicable exact-filter or
unfiltered snapshot is used; a filtered snapshot cannot declare voices on other
backends absent. A newer same-filter query prevents an older reply from replacing
the cache. Failures do not become empty inventories, and disconnect clears cached
authority. Preferences also rejects replies for an obsolete refresh/filter.

Summary calls use the shared model resolver and generation-options precedence,
with their explicit compact context and output limit. Disabling TurnRock chat
produces a visible summary fallback reason while leaving voice operations available.

The local contract fixtures exercise real Core request routing, MCP dispatch,
controller cancellation, playback Stop, and selection persistence. Backend metadata
has separate local ASGI evidence. These checks do not establish deployed service
availability, browser playback, or microphone/device behavior.
