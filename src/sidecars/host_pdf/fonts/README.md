# Bundled fonts

These TTFs are embedded into the `host_pdf` sidecar binary via `go:embed`
(see `../fonts.go`). They are **never** read from an OS font path — bundling
them is the explicit fix for the original generator's `/usr/share/fonts/...`
hardcode, which was a guaranteed crash on macOS / Windows
(see `Docs/design/host_pdf_contract.md` §4).

| family | style | file |
|---|---|---|
| `DejaVuSans` | `""` (regular) | `DejaVuSans.ttf` |
| `DejaVuSans` | `"B"` (bold) | `DejaVuSans-Bold.ttf` |

## Source & license

Copied from the DejaVu fonts shipped with matplotlib's `mpl-data`. The DejaVu
fonts are **freely redistributable** under the DejaVu Fonts License (a permissive
Bitstream Vera–derived license that allows bundling and redistribution). They are
widely embedded in open-source tooling for exactly this reason.
