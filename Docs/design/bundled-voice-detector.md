# Voice Support runtime

The wake-word and VAD worker is the required Voice Support plugin (`voice`), an
immutable Python sidecar published as its own release and installed by Minerva
like any marketplace plugin. It does not use the system Python, invoke pip, or
download models when it starts. CI builds each sidecar from a pinned Python Build Standalone archive,
exact Python package versions, and the existing classifier assets. The build
records all downloaded wheel hashes and a manifest of every shipped file.
Every bundled launcher uses Python's `-B` mode so runtime imports cannot modify
the signed or checksummed sidecar with new bytecode files.

## Runtime boundary

The host supervises the worker through Minerva's existing MCP stdio process
transport. Stdout contains JSON-RPC lines only; worker diagnostics use stderr.
MCP initialization establishes the control channel but does not claim detector
readiness. `minerva_voice_start` loads the models and returns a random token plus an
ephemeral `127.0.0.1` WebSocket port. The host sends binary 16 kHz mono s16le
PCM to `/audio?token=...`; the worker returns only `wake_word`, `vad_start`, and
`vad_end` JSON events. One authenticated audio client is admitted at a time.

The control surface is deliberately small: start, status, configure, reset,
and stop. Configuration ranges and PCM message size/alignment are validated.
Closing a session clears the token and detector state. Connecting a new audio
session resets the openWakeWord feature pipeline and Silero recurrent state so
features cannot leak between sessions.

## Packaging

`src/plugins/voice/scripts/build-runtime.sh` accepts an explicit target:

- `linux-x86_64` or `linux-arm64`
- `windows-x86_64`
- `macos-arm64` or `macos-amd64`

The two macOS builds remain separate release assets. Minerva installs the one
for its process architecture (`macos-arm64` or `macos-amd64`); it must never
silently run the Intel worker under translation on Apple Silicon. A tag
`voice-v<version>` makes `.github/workflows/plugin-release.yml` build each
target and publish `voice-<version>-<target>.tar.gz`, a marketplace archive
(`scripts/package-plugin-release.py`) whose `manifest.json` comes from
`src/plugins/voice/manifest.json` with the target's interpreter as entrypoint.
Archives preserve executable bits and symlinks.

Generated stages and archives are ignored. No executable runtime or wheel is
checked into git. `runtime-bundle.lock` records the PBS URLs and hashes and
classifier hashes. `requirements-runtime.lock` contains exact wheel versions
and every accepted wheel hash. Each artifact
also records the selected wheel filenames in `input-artifacts.sha256` and all
shipped files in `manifest.sha256`. Publishing promotes only an artifact whose
portable tests pass on its native target.

The worker uses the same `AudioFeatures` implementation that Docker's
`Model.predict` called, while omitting unrelated pretrained classifiers. A
packaged numeric equivalence test protects that seam. Runtime dependencies and
the three retained model license sources are inventoried in
`licenses/THIRD_PARTY.md`; wheel license metadata remains in the installed
distributions.

## Validation and host integration

The worker contract test uses a fake detector with a real loopback WebSocket to
verify readiness, token admission, single-client ownership, PCM bounds, reset,
and stop. The artifact test runs with the bundled interpreter, verifies every
manifest entry, blocks non-loopback network access while loading the real
models, and exercises nonzero PCM through the packaged VAD path.

The host installs the release as the required `voice` plugin
(`RequiredPlugins`) and launches the worker through `PluginManager`.
`BundledVoiceDetectorAdapter` owns readiness, reconnect, and shutdown around
the worker while `VoiceGatewayClient` continues to own microphone capture and
speech-session state. The release workflow tests each runtime on its native
target and probes the packaged archive's MCP tool list against its manifest; a
focused opt-in bridge probe covers the production Godot-to-worker boundary
without opening a microphone or contacting Core.
