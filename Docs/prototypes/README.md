# UI prototypes

Static HTML mocks of the Minerva UI, used to prototype layout/UX changes without
touching Godot. **Not shipped code. Not functional.** They exist to answer
geometry questions — how many tabs fit, what a dock costs, how a layout behaves
at 16:9 vs 32:9 — faster than building the real thing.

## minerva-ui-mock.html

A calibrated clone of the three-pane main window (Chats / Editor / Notes),
self-contained: fonts are embedded as data URIs, nothing is fetched.

Open it in a browser. The **metrics** button (bottom right) toggles a
calibration panel that measures the live DOM against the Godot ground truth and
reports pass/fail per item at a 10% tolerance.

### Why it can be trusted

Every number in the mock traces to a measurement, not an estimate:

| Input | Value | Source |
|---|---|---|
| Font | Open Sans SemiBold 16px | `ThemeDB.fallback_font` — the theme sets **no** font, so the engine fallback is what renders |
| Line height | 23px | same |
| Tab content margins | L8 R8 T4 B4 | `blue_dark_mode.theme`, `TabContainer` `tab_*` styleboxes |
| Tab separation | 12px | `TabBar` `h_separation` |
| Derived tab width | text + 47px | 8+8 padding, 12 gap, ~19 close icon |
| Panel widths | 538 / 700 / 625 | pixel-scanned from a screenshot of the running app at 1920×1080, `content_scale_factor` 1.0 |
| Palette | `#002826` chrome, `#252b34` panels, `#1e2024` cards, `#1585f5` / `#00c745` bubbles | sampled from the same screenshot |

Cross-check: the derived tab-width model and the independently measured
screenshot agree within ~5px on every tab (`Chat` 83 vs 83, `Agenda` 106 vs 110,
`Autocoder` 128 vs 135).

Capacity this implies: a realistic 15-character chat title costs ~187px of
pitch, so **~2.9 tabs fit in the 545px chat column**.

### Verify it yourself

```bash
# numeric: page measures itself, pass/fail per item
google-chrome --headless --disable-gpu --virtual-time-budget=5000 \
  --window-size=1920,1155 --dump-dom Docs/prototypes/minerva-ui-mock.html \
  | grep -E 'OK |XX |RESULT'

# visual
google-chrome --headless --disable-gpu --virtual-time-budget=5000 \
  --window-size=1920,1155 --screenshot=/tmp/mock.png \
  Docs/prototypes/minerva-ui-mock.html
```

### Re-deriving the ground truth from Godot

Only needed if the theme changes. **Close Minerva first** — `--path src` starts a
second instance. Note that `--script` boots every autoload (MCP server, plugins,
CEF, docket), so use a throwaway project for pure font queries.

```gdscript
# theme values: run with `godot --headless --path src --script res://dump.gd`
var th: Theme = load(ProjectSettings.get_setting("gui/theme/custom"))
for s in th.get_stylebox_list("TabContainer"):
    var sb := th.get_stylebox(s, "TabContainer")
    print(s, " L=", sb.content_margin_left, " R=", sb.content_margin_right)
print(th.get_constant("h_separation", "TabBar"))

# font metrics: run in a bare temp project (no autoloads)
var f: Font = ThemeDB.fallback_font
print(f.get_font_name(), " ", ThemeDB.fallback_font_size)
print(f.get_string_size("Market research", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x)
```

### Known deviations

- Icons are hand-drawn SVG approximations, not Minerva's icon assets.
- The canvas drawing is decorative (real Caveat font, subset to the glyphs used).
- Checker-square phase is offset a few px from the original.
- Fonts are subset to the glyphs in use — metrics are unaffected (verified: all
  16 checks still pass post-subset), but arbitrary new text may show tofu.
- Vertical extent depends on the browser viewport, which is not the same as
  Godot's window height.

### Staleness

The calibration is a snapshot dated 2026-08-18 against `blue_dark_mode.theme`.
If that theme's tab styleboxes or the fallback font change, these numbers go
stale and the mock will quietly misrepresent capacity. The metrics panel catches
drift in the *mock*, not in the *source* — a guard test pinning the theme's
`tab_*` content margins and the fallback font would catch that, and does not
exist yet.

Discussion and full analysis: docket `minerva` item `01a011e91852`.
