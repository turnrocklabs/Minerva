package main

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/color"
	"image/png"
	"testing"

	"github.com/go-pdf/fpdf"
)

// tinyPNGB64 builds a small valid PNG and returns its base64 encoding.
func tinyPNGB64(t *testing.T) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for x := 0; x < 8; x++ {
		for y := 0; y < 8; y++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 32), G: uint8(y * 32), B: 128, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode test png: %v", err)
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func f64(v float64) *float64 { return &v }

// fullDoc exercises every primitive: explicit-font text, fit text, image,
// line, rect (DF), metadata, 2 pages.
func fullDoc(t *testing.T) Doc {
	return Doc{
		Defaults: &Defaults{Format: "Letter", Orientation: "portrait", Unit: "pt"},
		Metadata: &Metadata{Title: "Name Tags", Author: "Minerva", Subject: "test", Creator: "Minerva host.pdf"},
		Images: []Image{
			{ID: "icon", Format: "png", BytesB64: tinyPNGB64(t)},
		},
		Pages: []Page{
			{
				Ops: []Op{
					{Kind: "draw_text", Text: "Ada Lovelace", X: f64(24.5), Y: f64(30), Font: &Font{Family: "DejaVuSans", Style: "B", Size: 20}, W: f64(219), Align: "C", Color: &RGB{0, 0, 0}},
					{Kind: "draw_text", Text: "A Very Long Name That Must Shrink Down", X: f64(24.5), Y: f64(60), Font: &Font{Family: "DejaVuSans", Style: "", Size: 30}, Fit: &Fit{MaxWidth: 120, MinSize: 8, Step: f64(1)}},
					{Kind: "draw_image", ImageID: "icon", X: f64(24.5), Y: f64(100), W: f64(28.8)},
					{Kind: "draw_line", X1: f64(0), Y1: f64(0), X2: f64(50), Y2: f64(0), Width: f64(0.35), Color: &RGB{200, 200, 200}},
					{Kind: "draw_rect", X: f64(36), Y: f64(54), W: f64(243), H: f64(168), Style: "DF", StrokeWidth: f64(0.25), StrokeColor: &RGB{200, 200, 200}, FillColor: &RGB{255, 255, 255}},
				},
			},
			{
				Ops: []Op{
					{Kind: "draw_text", Text: "Page 2", X: f64(40), Y: f64(40), Font: &Font{Family: "DejaVuSans", Style: "", Size: 12}},
					{Kind: "draw_image", ImageID: "icon", X: f64(40), Y: f64(80), W: f64(20)}, // reuse cached image
				},
			},
		},
	}
}

func TestGenerateAllPrimitives(t *testing.T) {
	res, gErr := Generate(fullDoc(t))
	if gErr != nil {
		t.Fatalf("unexpected error: %v", gErr)
	}
	if res.ContentType != "application/pdf" {
		t.Errorf("content_type = %q, want application/pdf", res.ContentType)
	}
	if res.PageCount != 2 {
		t.Errorf("page_count = %d, want 2", res.PageCount)
	}
	if res.ByteSize <= 0 {
		t.Errorf("byte_size = %d, want > 0", res.ByteSize)
	}
	decoded, err := base64.StdEncoding.DecodeString(res.BytesB64)
	if err != nil {
		t.Fatalf("bytes_b64 did not decode: %v", err)
	}
	if len(decoded) != res.ByteSize {
		t.Errorf("decoded len %d != byte_size %d", len(decoded), res.ByteSize)
	}
	if !bytes.HasPrefix(decoded, []byte("%PDF")) {
		t.Errorf("decoded bytes do not start with %%PDF: %q", decoded[:min(8, len(decoded))])
	}
}

func TestUnknownFont(t *testing.T) {
	doc := Doc{Pages: []Page{{Ops: []Op{
		{Kind: "draw_text", Text: "x", X: f64(10), Y: f64(10), Font: &Font{Family: "Helvetica", Style: "", Size: 12}},
	}}}}
	_, gErr := Generate(doc)
	if gErr == nil || gErr.ErrorCode != ErrFontNotAvailable {
		t.Fatalf("want font_not_available, got %v", gErr)
	}
	if len(gErr.Available) == 0 {
		t.Errorf("font_not_available should list available fonts")
	}
}

func TestUnknownImageID(t *testing.T) {
	doc := Doc{Pages: []Page{{Ops: []Op{
		{Kind: "draw_image", ImageID: "missing", X: f64(10), Y: f64(10), W: f64(20)},
	}}}}
	_, gErr := Generate(doc)
	if gErr == nil || gErr.ErrorCode != ErrUnknownImageID {
		t.Fatalf("want unknown_image_id, got %v", gErr)
	}
	if gErr.ImageID != "missing" || gErr.PageIndex == nil || gErr.OpIndex == nil {
		t.Errorf("unknown_image_id should carry image_id/page_index/op_index, got %+v", gErr)
	}
}

func TestBadBase64Image(t *testing.T) {
	doc := Doc{
		Images: []Image{{ID: "bad", Format: "png", BytesB64: "!!!not base64!!!"}},
		Pages: []Page{{Ops: []Op{
			{Kind: "draw_image", ImageID: "bad", X: f64(10), Y: f64(10), W: f64(20)},
		}}},
	}
	_, gErr := Generate(doc)
	if gErr == nil || gErr.ErrorCode != ErrImageDecode {
		t.Fatalf("want image_decode_failed, got %v", gErr)
	}
	if gErr.ImageID != "bad" {
		t.Errorf("image_decode_failed should carry image_id, got %+v", gErr)
	}
}

func TestUnknownOpKind(t *testing.T) {
	doc := Doc{Pages: []Page{{Ops: []Op{
		{Kind: "draw_circle", X: f64(10), Y: f64(10)},
	}}}}
	_, gErr := Generate(doc)
	if gErr == nil || gErr.ErrorCode != ErrSchemaValidation {
		t.Fatalf("want schema_validation_failed, got %v", gErr)
	}
	if gErr.Detail == "" {
		t.Errorf("schema_validation_failed should carry a detail location")
	}
}

func TestRectFillRequiresFillColor(t *testing.T) {
	doc := Doc{Pages: []Page{{Ops: []Op{
		{Kind: "draw_rect", X: f64(0), Y: f64(0), W: f64(10), H: f64(10), Style: "DF"},
	}}}}
	_, gErr := Generate(doc)
	if gErr == nil || gErr.ErrorCode != ErrSchemaValidation {
		t.Fatalf("want schema_validation_failed for missing fill_color, got %v", gErr)
	}
}

func TestStrictUnknownKeyRejected(t *testing.T) {
	raw := []byte(`{"pages":[{"ops":[{"kind":"draw_line","x1":0,"y1":0,"x2":1,"y2":1,"bogus_field":7}]}]}`)
	_, gErr := DecodeDoc(raw)
	if gErr == nil || gErr.ErrorCode != ErrSchemaValidation {
		t.Fatalf("want schema_validation_failed for unknown key, got %v", gErr)
	}
}

func TestImageDefaultsCheck(t *testing.T) {
	// missing required w on draw_image -> schema_validation_failed
	doc := Doc{
		Images: []Image{{ID: "icon", Format: "png", BytesB64: tinyPNGB64(t)}},
		Pages:  []Page{{Ops: []Op{{Kind: "draw_image", ImageID: "icon", X: f64(1), Y: f64(1)}}}},
	}
	_, gErr := Generate(doc)
	if gErr == nil || gErr.ErrorCode != ErrSchemaValidation {
		t.Fatalf("want schema_validation_failed for missing w, got %v", gErr)
	}
}

// newFitTestPDF builds a points/Letter pdf with the bundled DejaVu fonts
// registered and DejaVuSans regular selected — the precondition computeFitSize
// documents (caller has already selected the font). It needs a page so the
// font machinery is live for measurement.
func newFitTestPDF(t *testing.T) *fpdf.Fpdf {
	t.Helper()
	pdf := fpdf.New("P", "pt", "Letter", "")
	pdf.SetAutoPageBreak(false, 0)
	for key, data := range bundledFonts {
		family, style := splitFontKey(key)
		pdf.AddUTF8FontFromBytes(family, style, data)
	}
	pdf.AddPage()
	pdf.SetFont("DejaVuSans", "", 30)
	if err := pdf.Error(); err != nil {
		t.Fatalf("test pdf setup: %v", err)
	}
	return pdf
}

func TestComputeFitSizeShrinks(t *testing.T) {
	pdf := newFitTestPDF(t)
	const long = "A Very Long Name That Must Shrink Down"
	fit := &Fit{MaxWidth: 120, MinSize: 8, Step: f64(1)}

	// Sanity: the string overflows at the start size, so a real shrink is required.
	pdf.SetFontSize(30)
	if pdf.GetStringWidth(long) <= fit.MaxWidth {
		t.Fatalf("test premise broken: %q already fits at size 30", long)
	}

	got := computeFitSize(pdf, long, 30, fit)
	if got >= 30 {
		t.Fatalf("fit did not shrink: got %v, want < 30", got)
	}
	if got < fit.MinSize {
		t.Fatalf("fit undershot floor: got %v, want >= %v", got, fit.MinSize)
	}
	// At the chosen size the text must fit — unless we bottomed out at the floor.
	pdf.SetFontSize(got)
	if pdf.GetStringWidth(long) > fit.MaxWidth && got != fit.MinSize {
		t.Fatalf("chosen size %v neither fits nor is at floor %v", got, fit.MinSize)
	}
}

func TestComputeFitSizeNoShrinkWhenFits(t *testing.T) {
	pdf := newFitTestPDF(t)
	fit := &Fit{MaxWidth: 1000, MinSize: 8, Step: f64(1)}
	got := computeFitSize(pdf, "Hi", 12, fit)
	if got != 12 {
		t.Fatalf("short text should keep start size: got %v, want 12", got)
	}
}

func TestComputeFitSizeFloorsAtMinSize(t *testing.T) {
	pdf := newFitTestPDF(t)
	// MaxWidth=1pt is unreachable; the loop must bottom out exactly at MinSize.
	fit := &Fit{MaxWidth: 1, MinSize: 8, Step: f64(1)}
	got := computeFitSize(pdf, "Unfittable string", 30, fit)
	if got != fit.MinSize {
		t.Fatalf("want floor %v, got %v", fit.MinSize, got)
	}
}

func TestComputeFitSizeNonPositiveStepTerminates(t *testing.T) {
	pdf := newFitTestPDF(t)
	// step=0 must be treated as 1, not loop forever. (Guard regression test.)
	fit := &Fit{MaxWidth: 120, MinSize: 8, Step: f64(0)}
	got := computeFitSize(pdf, "A Very Long Name That Must Shrink Down", 30, fit)
	if got >= 30 || got < fit.MinSize {
		t.Fatalf("step=0 guard failed: got %v", got)
	}
}

// TestDrawImageRotation: a draw_image with an angle renders without error for
// both explicit-height and auto-aspect (h=0) cases — the rotation pivot path
// (center derived from intrinsic aspect when h is auto) must not fault.
func TestDrawImageRotation(t *testing.T) {
	png := tinyPNGB64(t)
	cases := []struct {
		name string
		op   Op
	}{
		{"explicit-h, 45deg", Op{Kind: "draw_image", ImageID: "icon", X: f64(50), Y: f64(50), W: f64(40), H: f64(40), Angle: f64(45)}},
		{"auto-h, 90deg", Op{Kind: "draw_image", ImageID: "icon", X: f64(50), Y: f64(150), W: f64(40), Angle: f64(90)}},
		{"negative angle", Op{Kind: "draw_image", ImageID: "icon", X: f64(50), Y: f64(250), W: f64(40), Angle: f64(-30)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			doc := Doc{
				Images: []Image{{ID: "icon", Format: "png", BytesB64: png}},
				Pages:  []Page{{Ops: []Op{tc.op}}},
			}
			res, gErr := Generate(doc)
			if gErr != nil {
				t.Fatalf("rotation render errored: %v", gErr)
			}
			decoded, err := base64.StdEncoding.DecodeString(res.BytesB64)
			if err != nil || !bytes.HasPrefix(decoded, []byte("%PDF")) {
				t.Fatalf("rotated image did not produce a valid PDF")
			}
		})
	}
}
