package main

import _ "embed"

// Bundled fonts (contract §4). Embedded into the binary via go:embed so they are
// NEVER read from an OS path (the original /usr/share/fonts hardcode was the
// guaranteed mac/Windows crash this fixes). DejaVu fonts are freely
// redistributable; see fonts/README.md.

//go:embed fonts/DejaVuSans.ttf
var dejaVuSansRegular []byte

//go:embed fonts/DejaVuSans-Bold.ttf
var dejaVuSansBold []byte
