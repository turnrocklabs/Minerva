# scansort functional-regression fixtures

Synthetic, **PII-free** fixtures for the scansort plugin's end-to-end functional
regression test. The test creates a fresh vault, imports `rules.json`, registers
this directory as a source, runs scansort's `process()` (vision classification
via qwen2.5vl rendering each PDF page to an image), and asserts each document
landed where `expected_placement.json` says it should.

> **Every name, SSN, EIN, account number, address and dollar amount in these
> PDFs is obviously fake** ("Jane Q. Sample", SSN `000-00-0000`, EIN `00-0000000`,
> "123 Test Street, Springfield"). Do **not** replace any of it with real data.
> Do **not** confuse these with the real records in `~/temp/scansort-staging/`.

## Files

| File | Purpose |
|------|---------|
| `gen_fixtures.py` | Deterministic, re-runnable generator for the 6 PDFs (reportlab). Re-run with `python3 gen_fixtures.py`; output is byte-stable. |
| `*.pdf` | The 6 synthetic input documents (1 page each, US Letter). |
| `rules.json` | The co-designed scansort rule set — a full `RulesFile` (schema v2). |
| `expected_placement.json` | Assertion oracle: input PDF → rule fired + destination + renamed prefix. |
| `README.md` | This file. |

## The 6 PDFs and the rule each fires

Each PDF is visually distinct so a vision model unambiguously identifies it, and
each is co-designed to fire exactly one rule in `rules.json`.

| PDF | One-line description | Rule label | Destination subfolder |
|-----|----------------------|------------|-----------------------|
| `w2_wage_statement.pdf` | A **Form W-2** annual wage & tax statement: bold "Form W-2" title, numbered Box 1–6 grid, Employer EIN, Employee SSN. | `tax-w2` | `Taxes/W-2` |
| `electric_utility_bill.pdf` | An **electric utility bill** from "Springfield Power & Light": blue header, kWh usage, charge summary, bold TOTAL AMOUNT DUE. | `utility-electric` | `Utilities/Electric` |
| `bank_statement.pdf` | A **monthly bank account statement** from "First Sample Bank": green header, beginning/ending balances, dated transaction table. | `bank-statement` | `Banking/Statements` |
| `pay_stub.pdf` | A **pay stub / earnings statement** for one pay period: "EARNINGS STATEMENT" title, Earnings + Deductions sections, bold NET PAY. | `pay-stub` | `Income/PayStubs` |
| `insurance_eob.pdf` | A **health insurance Explanation of Benefits**: "EXPLANATION OF BENEFITS", "THIS IS NOT A BILL", BILLED / PLAN PAID / YOU OWE table. | `insurance-eob` | `Medical/EOB` |
| `vehicle_registration.pdf` | A **vehicle registration certificate**: decorative border, "DEPARTMENT OF MOTOR VEHICLES", license plate, VIN, registration year. | `vehicle-registration` | `Vehicle/Registration` |

### Designed-in disambiguation

The two confusable pairs are deliberately separated by the rule `instruction`
text:

- **W-2 vs. pay stub** — both are employer/income documents. The W-2 rule keys
  on the *annual* "Form W-2" title, numbered boxes, and EIN/SSN; the pay-stub
  rule keys on the *single pay period*, "EARNINGS STATEMENT" title, and NET PAY.
  Each instruction explicitly tells the model to reject the other.
- **Bank statement vs. EOB vs. utility bill** — all have money tables. Each rule
  instruction names its unique header text and table columns.

## Rule schema (scansort source citations)

`rules.json` is a full **`RulesFile`** (schema v2), the shape
`minerva_scansort_import_rules_from_json` accepts when given a `rules_path`
(`src/main.rs:1042-1060` parses `json_text` as a `RulesFile` first).

`RulesFile` — `src/rules_file.rs:162-169`:

- `schema_version: i64` (current = 2, `rules_file.rs:15`)
- `default_category: String`
- `confidence_threshold: f64`
- `rename_pattern: String`
- `rules: Vec<FileRule>`

`FileRule` — `src/rules_file.rs:31-85`:

- `label: String` — primary key (upsert is by label)
- `name`, `instruction: String`
- `subfolder: String` — destination subfolder; supports `{token}` expansion
- `rename_pattern: String` — supports `{token}` expansion
- `confidence_threshold: f64` (default 0.6)
- `encrypt`, `enabled` (default true), `is_default: bool`
- `conditions`, `exceptions: Option<ConditionNode>` — deterministic gates
- `order: i64`, `stop_processing: bool`, `copy_to: Vec<String>`
- `stages: Vec<Stage>` — the v2 per-rule classification pipeline (DCR 019e33bf)
- `signals: Vec<String>`, `subtypes: Vec<Subtype>` — **deprecated** legacy
  fields; omitted here since v2 uses `stages`.

`Stage` — `src/types.rs:262-268`: `{ ask: String, classify: BTreeMap<String,
Slot>, keep_when: Option<String> }`.

`Slot` — `src/types.rs:246-250`: `{ description: String, values: SlotValues }`.
`SlotValues` is untagged (`src/types.rs:227-232`): a JSON **array** = `Closed`
(LLM picks from the list); a JSON **string** = `Open` (natural-language
constraint).

`keep_when` grammar — `src/stage_walker.rs:21-28`: `slot == 'value'`,
`slot != 'value'`, `slot in ['a','b']`. Unknown grammar → evaluates **false**.

Rename/subfolder `{token}` expansion: stage-driven rules resolve tokens from
their `classify` slot values via `resolve_template_from_slots`
(`src/rule_engine.rs:398-415`); any referenced token with no slot falls back to
`unknown`. Legacy non-stage rules use `resolve_template`
(`src/rule_engine.rs:347-390`, built-in tokens `{year} {date} {issuer}
{description} {doc_type} {amount} {category}`).

Each rule in `rules.json` has a single stage with three slots: a `yes`/`no`
gating slot (used by `keep_when`), a `year` slot, and a `doc_type` slot — the
latter two feed the `rename_pattern`.

## Not verified / caveats

- **Vision-model determinism.** scansort classifies with a vision LLM
  (qwen2.5vl). The `keep_when` yes/no gate and the destination subfolder should
  be stable, but the `{doc_type}` slot is free-form LLM text and is **not** byte-
  deterministic. The test should assert the `expected_subfolder` and the static
  `expected_renamed_prefix` (e.g. `2024_W2_`) and treat the trailing
  `{doc_type}` token as free-form. This is reflected in `expected_placement.json`.
- **`process()` placement vs. rename wiring not traced end-to-end.** The
  `RulesFile`/`FileRule`/`Stage` schema and the two template resolvers were read
  directly from source. The exact way `process()` joins `subfolder` to the vault
  root and applies `rename_pattern` to produce the on-disk filename was not
  traced line-by-line — the test author should confirm against `src/process.rs`
  and `src/placement.rs` and adjust `expected_placement.json` if placement adds
  an extension or a date prefix beyond what the pattern specifies.
- **PDF byte-stability.** `gen_fixtures.py` sets fixed document metadata and
  `info.invariant = 1`. reportlab is generally reproducible with these settings,
  but byte-identical output across reportlab *versions* is not guaranteed; pin
  reportlab if exact-diff regeneration matters (generated here with 4.4.10).
- The 6 PDFs and `gen_fixtures.py` already existed in this directory before this
  task; `rules.json`, `expected_placement.json`, and this README were added to
  complete the fixture set. The PDFs were verified as valid 1-page US-Letter
  PDFs via `pdfinfo` but were not re-rendered through a vision model.
