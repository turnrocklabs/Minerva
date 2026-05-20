# Presentation plugin test fixture

`test_deck.mdeck` is a small, schema-valid `.mdeck` deck used by the
presentation plugin's functional regression test. It exists so the test can
open a deck and assert it loads + renders with known slide/tile counts,
without depending on large real decks (`~/temp/llms_overview_v1.migrated.mdeck`
is 58 MB and image-heavy — unsuitable for a committed fixture).

All content is generic placeholder text. Nothing is copied from real decks.

## Schema

- Schema version: **1** (integer `version` field).
- Confirmed in plugin source: `plugins/presentation/ui/slide_model.gd:19`
  (`const SCHEMA_VERSION: int = 1`).
- Validators that this fixture satisfies:
  - `slide_model.gd:310` `validate_deck` — requires `version`, `aspect`
    (one of `16:9` / `4:3` / `1:1`), `slides` array; slide ids unique.
  - `slide_model.gd:343` `validate_slide` — requires `id` (non-empty string),
    `tiles` array, `reveal` array; `title`/`background`/`annotations` optional;
    tile ids unique.
  - `slide_model.gd:427` `validate_tile` — requires `id`, `kind`, and
    `x`/`y`/`w`/`h` numbers in `[0,1]`. Text tiles require `text_mode`
    (`plain` / `bullet` / `numbered`) and a string `content`; optional bool
    `auto_fit`.
- Deck root shape matches `make_deck()` (`slide_model.gd:75`):
  `{version, aspect, slides}`. The real deck also carries an optional
  `file_path` key — that is a save-time field, not required by the loader, so
  the fixture omits it.

## Asserted counts

The test should assert exactly:

| Slide index | Slide id              | Title             | Tile count |
|-------------|-----------------------|-------------------|------------|
| 0           | `slide_fixture_0001`  | Test Slide One    | 2          |
| 1           | `slide_fixture_0002`  | Test Slide Two    | 3          |
| 2           | `slide_fixture_0003`  | Test Slide Three  | 2          |

- Slide count: **3**
- Total tiles: **7** (all `kind: text`; no image/spreadsheet tiles, no blobs).

## Notes / not verified

- The fixture uses integer `version: 1`. The 58 MB real deck stores
  `version: 1.0` (a float, a JSON round-trip artifact). `validate_deck`
  compares with `!=` against the int constant; integer `1` is the canonical
  form `make_deck()` writes and is accepted by both the GDScript validator and
  the Go plugin's `version` reads (`main.go:1297`, `main.go:1354`, which parse
  it as `float64`).
- No image tiles are included, so the blob-envelope contract
  (`{__blob__, content_type, bytes}`) is intentionally untested by this
  fixture — keep image rendering coverage in a separate, opt-in fixture if
  needed.
- The fixture was validated structurally against the schema rules above; it
  was not run through the live Godot `validate_deck` function or the plugin's
  `loadDeck` path.
