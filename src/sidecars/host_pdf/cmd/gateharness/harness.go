//go:build gateharness

// Command gateharness builds a host.pdf `Doc` that reproduces the original
// generate_tags.py nametag deck for the committed fixtures, calls the sidecar's
// pure Generate(), and writes candidate.pdf. It is the "candidate" side of the
// P1.1 pixel-diff acceptance gate.
//
// IT IS NOT BUILT INTO THE SIDECAR. Because Generate/Doc/types live in the
// sidecar's `package main`, this file is compiled together with the core source
// files (excluding main.go to avoid a duplicate `main`) via:
//
//	go run generate.go types.go fonts.go cmd/gateharness/harness.go \
//	   -- <icon.png> <out candidate.pdf>
//
// The run script does exactly that. All layout/geometry is ported here (the
// host is a dumb renderer; the plugin owns layout — contract §8): the
// cardstock_4x2 grid, centered positioning, 0.125in padding, the 4mm corner
// marks, the 0.40in icon, the name auto-shrink, and the back-page column
// reversal with registration offsets.
package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"os"

	"github.com/go-pdf/fpdf"
)

// ---- unit helpers (mirror generate_tags.py) ----

func inToPt(in float64) float64 { return in * 72.0 }
func mmToPt(mm float64) float64 { return mm * 2.83465 }

// ---- layout (mirror LayoutConfig.cardstock_4x2) ----

type layoutConfig struct {
	pageW, pageH         float64
	tagW, tagH           float64
	marginLeft, marginTop float64
	gutterH, gutterV     float64
	rows, cols           int
}

func cardstock4x2() layoutConfig {
	pageW := inToPt(8.5)
	pageH := inToPt(11)
	tagW := inToPt(3.375)
	tagH := inToPt(2.333)
	rows, cols := 4, 2
	gutterH := inToPt(0.20)
	gutterV := inToPt(0.20)
	totalW := float64(cols)*tagW + float64(cols-1)*gutterH
	totalH := float64(rows)*tagH + float64(rows-1)*gutterV
	return layoutConfig{
		pageW: pageW, pageH: pageH, tagW: tagW, tagH: tagH,
		marginLeft: (pageW - totalW) / 2, marginTop: (pageH - totalH) / 2,
		gutterH: gutterH, gutterV: gutterV, rows: rows, cols: cols,
	}
}

func (l layoutConfig) cellPositions() [][2]float64 {
	var p [][2]float64
	for row := 0; row < l.rows; row++ {
		for col := 0; col < l.cols; col++ {
			x := l.marginLeft + float64(col)*(l.tagW+l.gutterH)
			y := l.marginTop + float64(row)*(l.tagH+l.gutterV)
			p = append(p, [2]float64{x, y})
		}
	}
	return p
}

func (l layoutConfig) backCellIndex(front int) int {
	row := front / l.cols
	col := front % l.cols
	backCol := l.cols - 1 - col
	return row*l.cols + backCol
}

// ---- tag box (mirror TagBox; padding = 0.125in) ----

type tagBox struct{ x, y, w, h float64 }

const padding = 9.0 // inToPt(0.125)

func (b tagBox) contentX() float64 { return b.x + padding }
func (b tagBox) contentY() float64 { return b.y + padding }
func (b tagBox) contentW() float64 { return b.w - 2*padding }
func (b tagBox) contentH() float64 { return b.h - 2*padding }

// ---- fixtures: the 8 rows from sample.xlsx (kept in sync with make_fixtures.py) ----

type tag struct{ name, classNum, group, room string }

var tags = []tag{
	{"Ada", "Math 1", "1", "A101"},
	{"Maximilian Hohenzollern-Sigmaringen", "Physics", "2", "B205"},
	{"Bob Smith", "Chem", "3", "C300"},
	{"Grace Hopper", "CS 200", "1", "A101"},
	{"Wolfgang Amadeus Mozart-Beethoven", "Music", "2", "D404"},
	{"Liu", "Art", "3", "E12"},
	{"Katherine Johnson", "Math 2", "1", "A102"},
	{"Bartholomew Featherstonehaugh III", "History", "2", "F555"},
}

const (
	iconWidthPt = 28.8        // inToPt(0.40)
	fontFamily  = "DejaVuSans"
	imageID     = "icon"
)

// measurePDF is a throwaway fpdf instance used ONLY to compute the name
// auto-shrink decision and string widths with the SAME font engine + TTF the
// sidecar uses (AddUTF8FontFromBytes). This mirrors fpdf2's get_string_width
// inside _draw_name's shrink loop. The chosen size + width then become concrete
// coordinates in the emitted ops, so the candidate Doc carries exactly the
// geometry the original computed — no reliance on the contract's sidecar-side
// `fit` for positioning (the sidecar `fit` is exercised by go test separately).
func newMeasurer() *fpdf.Fpdf {
	m := fpdf.New("P", "pt", "Letter", "")
	m.SetAutoPageBreak(false, 0)
	m.AddUTF8FontFromBytes(fontFamily, "", dejaVuSansRegular)
	m.AddUTF8FontFromBytes(fontFamily, "B", dejaVuSansBold)
	m.AddPage()
	return m
}

// fitName reproduces _draw_name's shrink loop EXACTLY, including its subtle
// quirk. The original:
//
//	font_size = 20
//	while font_size >= 12:
//	    set_font('DejaVu','B', font_size)      # <- last set_font wins as DRAWN size
//	    text_width = get_string_width(name)    # <- measured at that drawn size
//	    if text_width <= max_width: break
//	    font_size -= 1
//	line_height = font_size * 1.2              # <- uses the DECREMENTED loop var
//	cell(text_width, line_height, name, align='C')
//
// For a name that never fits, the loop sets the font at 12, fails the check,
// decrements font_size to 11, and 11>=12 ends the loop — so the glyphs are DRAWN
// at 12 (last set_font) and text_width is measured at 12, while line_height is
// computed from 11. We mirror all three:
//   drawnSize – size glyphs are actually drawn at (last set_font in the loop)
//   twDrawn   – string width at drawnSize (drives horizontal centering)
//   loopVar   – final loop-variable value (drives line_height = loopVar*1.2)
func fitName(m *fpdf.Fpdf, name string, maxWidth float64) (drawnSize, twDrawn, loopVar float64) {
	const minSize = 12.0
	fs := 20.0
	var tw float64
	drawn := fs
	for fs >= minSize {
		m.SetFont(fontFamily, "B", fs)
		drawn = fs
		tw = m.GetStringWidth(name)
		if tw <= maxWidth {
			break
		}
		fs -= 1
	}
	return drawn, tw, fs
}

func strWidth(m *fpdf.Fpdf, style string, size float64, text string) float64 {
	m.SetFont(fontFamily, style, size)
	return m.GetStringWidth(text)
}

// renderTagOps emits the ops for one tag, mirroring TagRenderer.render_tag with
// corner marks (full_guides=False). Draw order matches the original:
// corner marks, icon, class, name, room, group.
func renderTagOps(m *fpdf.Fpdf, b tagBox, t tag) []Op {
	var ops []Op
	ops = append(ops, cornerMarkOps(b)...)
	ops = append(ops, iconOp(b))
	if op, ok := classOp(m, b, t.classNum); ok {
		ops = append(ops, op)
	}
	if op, ok := nameOp(m, b, t.name); ok {
		ops = append(ops, op)
	}
	if op, ok := roomOp(m, b, t.room); ok {
		ops = append(ops, op)
	}
	if op, ok := groupOp(m, b, t.group); ok {
		ops = append(ops, op)
	}
	return ops
}

func f(v float64) *float64 { return &v }

func iconOp(b tagBox) Op {
	return Op{Kind: "draw_image", ImageID: imageID, X: f(b.contentX()), Y: f(b.contentY()), W: f(iconWidthPt)}
}

// nameOp mirrors _draw_name (see fitName for the shrink-loop quirk):
//   drawn glyph size = drawnSize ; tw = width at drawnSize
//   line_height = loopVar * 1.2   (NOT drawnSize)
//   x = content_x + (content_w - tw)/2 ; y = content_y + (content_h - line_height)/2
//   cell(tw, line_height, name, align='C')
func nameOp(m *fpdf.Fpdf, b tagBox, name string) (Op, bool) {
	if name == "" {
		return Op{}, false
	}
	drawnSize, tw, loopVar := fitName(m, name, b.contentW())
	lineHeight := loopVar * 1.2
	x := b.contentX() + (b.contentW()-tw)/2
	y := b.contentY() + (b.contentH()-lineHeight)/2
	return Op{
		Kind: "draw_text", Text: name,
		X: f(x), Y: f(y), W: f(tw), H: f(lineHeight), Align: "C",
		Font: &Font{Family: fontFamily, Style: "B", Size: drawnSize},
	}, true
}

// classOp mirrors _draw_class: DejaVu regular 10, upper-right.
//   x = box.x + box.w - padding - tw ; y = content_y ; cell(tw, 10, text)
func classOp(m *fpdf.Fpdf, b tagBox, classNum string) (Op, bool) {
	if classNum == "" {
		return Op{}, false
	}
	text := "Class: " + classNum
	tw := strWidth(m, "", 10, text)
	x := b.x + b.w - padding - tw
	y := b.contentY()
	return Op{Kind: "draw_text", Text: text, X: f(x), Y: f(y), W: f(tw), H: f(10),
		Font: &Font{Family: fontFamily, Style: "", Size: 10}}, true
}

// roomOp mirrors _draw_room: DejaVu regular 10, lower-left.
//   x = content_x ; y = box.y + box.h - padding - 10 ; cell(tw, 10, text)
func roomOp(m *fpdf.Fpdf, b tagBox, room string) (Op, bool) {
	if room == "" {
		return Op{}, false
	}
	text := "Room: " + room
	tw := strWidth(m, "", 10, text)
	x := b.contentX()
	y := b.y + b.h - padding - 10
	return Op{Kind: "draw_text", Text: text, X: f(x), Y: f(y), W: f(tw), H: f(10),
		Font: &Font{Family: fontFamily, Style: "", Size: 10}}, true
}

// groupOp mirrors _draw_group: DejaVu regular 10, lower-right.
//   x = box.x + box.w - padding - tw ; y = box.y + box.h - padding - 10
func groupOp(m *fpdf.Fpdf, b tagBox, group string) (Op, bool) {
	if group == "" {
		return Op{}, false
	}
	text := "Group: " + group
	tw := strWidth(m, "", 10, text)
	x := b.x + b.w - padding - tw
	y := b.y + b.h - padding - 10
	return Op{Kind: "draw_text", Text: text, X: f(x), Y: f(y), W: f(tw), H: f(10),
		Font: &Font{Family: fontFamily, Style: "", Size: 10}}, true
}

// cornerMarkOps mirrors _draw_corner_marks: 4mm marks, gray 200, width 0.35,
// with the left/top clamps at the page edge.
func cornerMarkOps(b tagBox) []Op {
	mark := mmToPt(4)
	markLeft := mark
	if b.x < markLeft {
		markLeft = b.x
	}
	markTop := mark
	if b.y < markTop {
		markTop = b.y
	}
	gray := &RGB{200, 200, 200}
	w := 0.35
	xR := b.x + b.w
	yB := b.y + b.h
	line := func(x1, y1, x2, y2 float64) Op {
		return Op{Kind: "draw_line", X1: f(x1), Y1: f(y1), X2: f(x2), Y2: f(y2), Width: f(w), Color: gray}
	}
	return []Op{
		// top-left
		line(b.x-markLeft, b.y, b.x, b.y),
		line(b.x, b.y-markTop, b.x, b.y),
		// top-right
		line(xR, b.y, xR+mark, b.y),
		line(xR, b.y-markTop, xR, b.y),
		// bottom-left
		line(b.x-markLeft, yB, b.x, yB),
		line(b.x, yB, b.x, yB+mark),
		// bottom-right
		line(xR, yB, xR+mark, yB),
		line(xR, yB, xR, yB+mark),
	}
}

func buildDoc(iconPNG []byte) Doc {
	layout := cardstock4x2()
	positions := layout.cellPositions()
	m := newMeasurer()

	frontOps := []Op{}
	backOps := []Op{}
	for i, t := range tags {
		// front: normal order
		fx, fy := positions[i][0], positions[i][1]
		fb := tagBox{x: fx, y: fy, w: layout.tagW, h: layout.tagH}
		frontOps = append(frontOps, renderTagOps(m, fb, t)...)

		// back: column-reversed cell, registration offset 0,0 (back_mode 'same')
		bi := layout.backCellIndex(i)
		bx, by := positions[bi][0], positions[bi][1]
		bb := tagBox{x: bx, y: by, w: layout.tagW, h: layout.tagH}
		backOps = append(backOps, renderTagOps(m, bb, t)...)
	}

	return Doc{
		Defaults: &Defaults{Format: "Letter", Orientation: "portrait", Unit: "pt"},
		Metadata: &Metadata{
			Title:   "Name Tags",
			Author:  "Name Tag Generator",
			Subject: "Duplex Name Tags",
			Creator: "fpdf2",
		},
		Images: []Image{{ID: imageID, Format: "png", BytesB64: base64.StdEncoding.EncodeToString(iconPNG)}},
		Pages: []Page{
			{Ops: frontOps},
			{Ops: backOps},
		},
	}
}

func main() {
	args := os.Args[1:]
	// allow a leading "--" separator
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: gateharness <icon.png> <out candidate.pdf>")
		os.Exit(2)
	}
	iconPath, outPath := args[0], args[1]

	iconPNG, err := os.ReadFile(iconPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read icon:", err)
		os.Exit(1)
	}

	doc := buildDoc(iconPNG)
	res, gErr := Generate(doc)
	if gErr != nil {
		fmt.Fprintln(os.Stderr, "Generate failed:", gErr.Error())
		os.Exit(1)
	}

	raw, err := base64.StdEncoding.DecodeString(res.BytesB64)
	if err != nil {
		fmt.Fprintln(os.Stderr, "decode result:", err)
		os.Exit(1)
	}
	if err := os.WriteFile(outPath, raw, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "write candidate:", err)
		os.Exit(1)
	}
	// sanity: ensure it is a 2-op-list, non-empty
	_ = bytes.NewReader(raw)
	fmt.Printf("wrote %s  pages=%d  bytes=%d\n", outPath, res.PageCount, res.ByteSize)
}
