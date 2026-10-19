# Spreadsheet extraction boundary

`spreadsheet-extraction-inventory.tsv` is the frozen B4 disposition snapshot at
Minerva fa2424ea, enriched with the 20 retired class names extracted mechanically
from the exact recorded Git blobs. The gate refuses all 123 retired files and preserves all 19 B0
oracle blobs. Changing this authority requires reconciling the extraction plan;
adding another exception is a reviewed design change.

Host exceptions are narrow: PluginEditorRegistry owns the format descriptor,
RequiredPlugins owns the release coordinate, SpreadsheetSession and
LegacySpreadsheetNote forward opaque old saved data, Note preserves its exact
LinkedSpreadsheet serialization fields, and Editor retains numeric slot 6 as a
tombstone. Remove saved-data compatibility only after an owner-approved supported
file-version floor. Spreadsheet model/formula/render/undo behavior stays in Sheets.
The runtime-wide named-artifact boundary allows only these compatibility/recovery
resources, their generated UID companions, and the icon pair. The relocated 24px table icon and its import retain Presentation's public UID;
remove them only after that consumer has shipped without it.

`check-fast` runs the host boundary. The isolated two-repository static gate also
passes its explicit plugin checkout to the existing Sheets private-import census.
Retired identities are refused anywhere in runtime source, including comments;
keep historical examples in the excluded test fixtures. No language parser is
needed to decide whether to ignore a match. That census uses the archive packer's file inventory and the host's public SDK
paths; this gate adds no second SDK allowlist. Run `tests/test_spreadsheet_extraction.py`
in a disposable container for planted retired files, runtime references, unknown
assets, old skill tools, changed oracle bytes and missing ledger rows. The plugin
census's self-test supplies the private import/UID/global anti-cases.
