# Live Context acceptance

This is the **one** live e2e for DCR `minerva:01a17459de19` (W1
`minerva:01a17475c1e2`). It is opt-in and is absent from CI/test-suite discovery.
It exercises the real GUI under Xvfb using HTTP MCP and GLM-5.3-Flash over
async model-chat. Obtain authorization for each live run. No retries or restart
scenario are performed by the driver; the production async protocol owns its
normal loading/polling behavior. The job has a 1,200-second outer deadline.

Create a clean agent session from the checkout containing the **reviewed
committed test**, using `scripts/agent-container/README.md`. The launcher fetches
the requested immutable commit into that session; the job checks it out afresh.
Use a dedicated session/state/work directory, never an owner's checkout or app.

Provide the four public Linux plugin archives listed in `pins.json` in a scratch
directory. They can be downloaded from the exact `source` URLs in that file;
the launcher verifies their SHA-256 digests. Binaries are never committed. The
job serves the committed, pinned `required-releases.json` fixture on loopback
and needs no egress beyond the existing Core tunnels.

Run from the checkout, with task-specific `MINERVA_AGENT_STATE` and
`MINERVA_AGENT_WORK` already set, substituting public paths/session/SHA:

```sh
sops exec-env /path/to/secrets.enc.json \
 'python3 -B tests/live/run_context_compaction.py --session SESSION --rev FULL_SHA \
  --test-env-dir /path/to/minervaservices/infrastructure/test \
  --assets /path/to/public-plugin-archives --evidence /path/to/new-evidence-dir \
  --expected red'
```

The approved `test_env.py` helper resolves the test username from the inherited
environment/default. The password must already be inherited through SOPS.
Neither value enters argv, fixture data or evidence. `--network core` and
`--env-from` pass only variable names. Git/setup/import/Xvfb subprocesses receive
an environment with those credentials removed. Raw GUI logs and private app data
stay on the job's exec tmpfs. The existing harness finalizes and scans `/out`;
the launcher then scans **both** report and driver metadata for username,
password, email and JWT-like material before copying or printing either.
Only exact `Popen` instances owned by the driver are retired.

The test records the advertised GLM maximum, applies Context values
65,000/6,500/4,000 and reasoning `low` through MCP, and reads the real dialog's
Context labels and reasoning selection. It sends `hi`, then an original story
opening and continuations of about 600 words, capped at **15 story turns**.
It checks the first eligible compaction, no Large Context dialog, reduced input,
summary and real Ledger link/entry, GLM summary response, and a successful next
turn. Every turn records client-observed timestamps, input estimate from
`ChatPane.estimate_agent_context_size`, output reserve, total budget, server usage
and reply length/hash. It never retains reply or summary text.

Clarification `c5696`: the 6,500 threshold uses **input**. The 65,000 limit uses
input plus output reserve. Ratios are recorded on every turn; ±30% accuracy is
asserted only where server prompt usage is at least 1,000 tokens. Following
compaction, accuracy uses the input measured after compaction, before the main
reply. Local Ollama safety uses its real provider/request path to an owned
loopback HTTP capture: `options.num_ctx` must remain today's default **8,192**.
That capture supplies a minimal response; it does not stand in for the live GLM
generation or compaction assertions.

`report.json` distinguishes `red`, `green`, and
`harness_or_prerequisite_failure`. A valid W1 red is `settings_rejected` for
`context_window`/`auto_compact_at`, or `compaction_missing_at_15_turn_cap`, with
no harness or script error. The outer launcher exits zero only if the requested
expectation matches. Use `--expected green` for an authorized final run. For an
authorized falsifier, revert the production threshold lookup **only in the job's
throwaway copy**, rerun this same test, and require
`--expected red --red-assertion compaction_missing_at_15_turn_cap`; never weaken
the assertions or run the falsifier during W1.

The DCR's binding owner rule allows this test alone. Before committing, run the
three static constituents of `scripts/check-fast` (plugin-docs,
spreadsheet-extraction, push-lanes), Python compile/Ruff and isolated GDScript
parse/GATE-W. Skip its three test scripts and the functional suite. Do not
dispatch a release. W1 stops after the reviewed committed test's **single** base
red run; W2–W4 require the next handoff.
