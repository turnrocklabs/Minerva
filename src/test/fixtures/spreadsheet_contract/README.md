# PRE-extraction spreadsheet contracts (B0)

Source host: `38cab76815ce5b74ba1644597d94f404c327ef82` (Godot 4.6.2).
Consumer plugin source: `b99ef01ceaeb459632d3b36c0035d2200f7195b9`.

Run `scripts/dev-test.sh test/test_spreadsheet_contract.gd` **in an isolated
container/clone**, never with the live checkout as a Godot project.

`tools.json` is the sorted `MCPExportCatalog.snapshot` of the two registered
production spreadsheet modules, including all 30 names, descriptions and input
schemas. Generate in an isolated imported clone with the test's explicit
`-- --write-tools` option, then review the diff. Ordinary verification never
rewrites the fixture. No global tool-count assertions changed.

`baseline.minsheet` is its own complete saved-model oracle: formulas, formatting,
column/row metadata, freeze panes and AutoFilter. The formula result is 5 (2+3).
`session.minproj` uses the production `Editors` project field, with its editor-array envelope with a type-6 sheet and
one chart. The test mounts a real editor, restores the content and compares the
production `EditorContainer.serialize()` output, including the whole envelope.
`no-chart-session.minproj` also executes the real `EditorContainer.deserialize()`
path and full envelope round-trip; the chart bug does not affect that fixture.
`linked-note.json` is a pre-entry-log note: its link is a tab-name STRING, not
embedded sheet data. Known fields and a second save/reopen are checked; generated
entry ids, revision and content hash are intentionally outside this old fixture.

The CSV/TSV/XLSX expected files are **complete** imported models, compared without
filtering fields; JSON normalization only equates integer/float representations.
The XLSX is copied byte-for-byte from
`src/sidecars/host_pdf/testdata/nametag_gate/sample.xlsx`.

## Current gaps are evidence, not fixes

- Native .minsheet chart array is empty today (`minerva:01a14b6689f0`); chart
  coverage is in mounted session content, not a claim that native files save it.
- The outer `EditorContainer.deserialize()` restores charts before mounting,
  causing a null-tree script error (`minerva:01a14b693555`). This suite does NOT
  claim full project-loader chart acceptance. The original failing runtime log is retained with the batch receipt;
  per orchestrator disposition, no crash-pinning subprocess machinery is
  added to B0. The fix and real outer chart restore test belong to B4. The
  chartless fixture covers the real restore path; chart content is verified
  on a mounted editor until that bug is fixed.
- XLSX inline strings are dropped (`minerva:01a14b6935b8`). The complete current
  import oracle contains only numeric group cells. A strict expected-failure
  assertion records the absent known name. It must be replaced when fixed.
- Future version 999 is silently read as v1 and unknown fields are dropped
  (`minerva:01a14b668a56`). The strict XFAIL records that defect; input bytes must
  still be unchanged. Malformed JSON and non-object input must refuse without
  touching either an existing loaded model or the source bytes.
- Imported-path Save can overwrite CSV/XLSX with JSON (`minerva:01a14b11f066`),
  outside B0. This suite tests import + model serialization, not that unsafe Save
  action. Selection/scroll/undo are not currently saved by these formats.

`consumers.json` freezes the actual nametag skill tool_deps, MultiMeter call,
webview helpers and CapabilityBroker kind for B5. `inventory.tsv` is generated
from a `git archive` of the host source pin, matching case-insensitive
`spreadsheet|minsheet|\bsheet\b|\bcharts?\b` or spreadsheet-owned paths. It includes
lexical false positives, with exact source hashes/line numbers, not deletion
instructions. Future extraction tests must interpret ownership before deleting.
