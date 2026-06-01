package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/go-pdf/fpdf"
)

// maxPayloadBytes is the 8 MB request cap (contract §9, matching _FILES_MAX_BYTES).
const maxPayloadBytes = 8 * 1024 * 1024

// bundledFonts is the v1-guaranteed font set (contract §4). Keyed "family|style".
// The TTF bytes are embedded via go:embed (see fonts.go) — never read from the OS.
var bundledFonts = map[string][]byte{
	"DejaVuSans|":  dejaVuSansRegular,
	"DejaVuSans|B": dejaVuSansBold,
}

// availableFonts returns the family/style pairs the sidecar bundles, for the
// font_not_available error payload.
func availableFonts() []string {
	return []string{"DejaVuSans (regular)", "DejaVuSans B (bold)"}
}

// Generate is the pure core: declarative document in, PDF bytes out. It does NOT
// touch stdio. Tests drive this directly. Returns a *GenError carrying a contract
// error code (§7) on any failure.
func Generate(doc Doc) (Result, *GenError) {
	// --- payload cap (§9): measure the decoded image payload + a generous
	// headroom for the structural JSON. We bound the dominant cost (images).
	var imageBytesTotal int
	for _, img := range doc.Images {
		// base64 decoded size estimate; exact decode happens lazily on first use.
		imageBytesTotal += base64.StdEncoding.DecodedLen(len(img.BytesB64))
	}
	if imageBytesTotal > maxPayloadBytes {
		return Result{}, &GenError{
			ErrorCode:    ErrPayloadTooLarge,
			ErrorMessage: fmt.Sprintf("decoded image payload %d bytes exceeds %d byte cap", imageBytesTotal, maxPayloadBytes),
		}
	}

	// --- defaults (§2, §4)
	format := "Letter"
	orientation := "portrait"
	if doc.Defaults != nil {
		if doc.Defaults.Format != "" {
			format = doc.Defaults.Format
		}
		if doc.Defaults.Orientation != "" {
			orientation = doc.Defaults.Orientation
		}
		// unit is guaranteed "pt"; we always build in points regardless.
	}

	pdf := fpdf.New(orientationFlag(orientation), "pt", format, "")
	pdf.SetAutoPageBreak(false, 0) // §2: always off — precise absolute positioning.

	// --- metadata (§4)
	if doc.Metadata != nil {
		if doc.Metadata.Title != "" {
			pdf.SetTitle(doc.Metadata.Title, true)
		}
		if doc.Metadata.Author != "" {
			pdf.SetAuthor(doc.Metadata.Author, true)
		}
		if doc.Metadata.Subject != "" {
			pdf.SetSubject(doc.Metadata.Subject, true)
		}
		if doc.Metadata.Creator != "" {
			pdf.SetCreator(doc.Metadata.Creator, true)
		}
	}

	// --- fonts: register the bundled set up front (§4). Embedded bytes only.
	for key, data := range bundledFonts {
		family, style := splitFontKey(key)
		pdf.AddUTF8FontFromBytes(family, style, data)
	}
	if err := pdf.Error(); err != nil {
		return Result{}, &GenError{ErrorCode: ErrPDFGeneration, ErrorMessage: "font registration failed", Detail: err.Error()}
	}

	// --- images: decode + register each by id (§4). Registered lazily on first
	// draw so an unused/bad image only fails if actually referenced... but the
	// contract's image_decode_failed is about the registry entry itself, so we
	// validate-decode here and register eagerly (gofpdf caches by name).
	imageRegistry := map[string]Image{}
	for i := range doc.Images {
		img := doc.Images[i]
		if _, dup := imageRegistry[img.ID]; dup {
			return Result{}, &GenError{
				ErrorCode:    ErrSchemaValidation,
				ErrorMessage: "duplicate image id",
				Detail:       fmt.Sprintf("images[%d]: id %q already declared", i, img.ID),
			}
		}
		imageRegistry[img.ID] = img
	}
	registered := map[string]bool{}

	// --- pages + ops
	for pi := range doc.Pages {
		page := doc.Pages[pi]
		// per-page format/orientation overrides (§4)
		pageOrient := orientation
		if page.Orientation != "" {
			pageOrient = page.Orientation
		}
		pageFmt := format
		if page.Format != "" {
			pageFmt = page.Format
		}
		pdf.AddPageFormat(orientationFlag(pageOrient), pageSize(pdf, pageFmt))

		for oi := range page.Ops {
			op := page.Ops[oi]
			if gErr := drawOp(pdf, op, pi, oi, imageRegistry, registered); gErr != nil {
				return Result{}, gErr
			}
			if err := pdf.Error(); err != nil {
				return Result{}, &GenError{
					ErrorCode:    ErrPDFGeneration,
					ErrorMessage: "fpdf error while drawing op",
					Detail:       fmt.Sprintf("pages[%d].ops[%d]: %s", pi, oi, err.Error()),
				}
			}
		}
	}

	// --- serialize (§6)
	var buf bytes.Buffer
	if err := pdf.Output(&buf); err != nil {
		return Result{}, &GenError{ErrorCode: ErrPDFGeneration, ErrorMessage: "pdf serialization failed", Detail: err.Error()}
	}
	raw := buf.Bytes()
	if len(raw) > maxPayloadBytes {
		return Result{}, &GenError{
			ErrorCode:    ErrPayloadTooLarge,
			ErrorMessage: fmt.Sprintf("generated PDF %d bytes exceeds %d byte cap", len(raw), maxPayloadBytes),
		}
	}

	return Result{
		BytesB64:    base64.StdEncoding.EncodeToString(raw),
		ByteSize:    len(raw),
		PageCount:   pdf.PageCount(),
		ContentType: "application/pdf",
	}, nil
}

// drawOp dispatches one op by kind with strict validation (§5, §7).
func drawOp(pdf *fpdf.Fpdf, op Op, pi, oi int, registry map[string]Image, registered map[string]bool) *GenError {
	loc := fmt.Sprintf("pages[%d].ops[%d]", pi, oi)
	switch op.Kind {
	case "draw_text":
		return drawText(pdf, op, loc)
	case "draw_image":
		return drawImage(pdf, op, pi, oi, loc, registry, registered)
	case "draw_line":
		return drawLine(pdf, op, loc)
	case "draw_rect":
		return drawRect(pdf, op, loc)
	case "":
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "missing op kind", Detail: loc + ": op has no \"kind\""}
	default:
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "unknown op kind", Detail: fmt.Sprintf("%s: unknown kind %q", loc, op.Kind)}
	}
}

// computeFitSize shrinks startSize by fit.Step (default 1, and any non-positive
// step is treated as 1 to prevent a non-terminating loop) until the measured
// width of text is <= fit.MaxWidth, flooring at fit.MinSize (§5). The caller
// must have already selected the font family/style via SetFont; this only
// varies the size. Returns the chosen size, leaving the pdf's font size set to
// it as a side effect of the final measurement.
func computeFitSize(pdf *fpdf.Fpdf, text string, startSize float64, fit *Fit) float64 {
	step := 1.0
	if fit.Step != nil && *fit.Step > 0 {
		step = *fit.Step
	}
	size := startSize
	for size > fit.MinSize {
		pdf.SetFontSize(size)
		if pdf.GetStringWidth(text) <= fit.MaxWidth {
			break
		}
		next := size - step
		if next < fit.MinSize {
			size = fit.MinSize
			break
		}
		size = next
	}
	pdf.SetFontSize(size)
	return size
}

func drawText(pdf *fpdf.Fpdf, op Op, loc string) *GenError {
	if op.Text == "" {
		// An empty string is a no-op visually but allowed; treat absent text field as ok.
	}
	if op.Font == nil {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "draw_text requires font", Detail: loc + ": draw_text missing \"font\""}
	}
	if op.X == nil || op.Y == nil {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "draw_text requires x and y", Detail: loc + ": draw_text missing \"x\"/\"y\""}
	}
	fontKey := op.Font.Family + "|" + op.Font.Style
	if _, ok := bundledFonts[fontKey]; !ok {
		return &GenError{
			ErrorCode:    ErrFontNotAvailable,
			ErrorMessage: fmt.Sprintf("font %q style %q is not bundled", op.Font.Family, op.Font.Style),
			Family:       op.Font.Family,
			Style:        op.Font.Style,
			Available:    availableFonts(),
		}
	}

	size := op.Font.Size
	pdf.SetFont(op.Font.Family, op.Font.Style, size)

	// fit: shrink size until measured width <= max_width, floor at min_size (§5).
	if op.Fit != nil {
		size = computeFitSize(pdf, op.Text, size, op.Fit)
	}

	// color: default black (§5).
	r, g, b := 0, 0, 0
	if op.Color != nil {
		r, g, b = op.Color[0], op.Color[1], op.Color[2]
	}
	pdf.SetTextColor(r, g, b)

	// w: omit → measured text width (§5).
	w := 0.0
	if op.W != nil {
		w = *op.W
	} else {
		w = pdf.GetStringWidth(op.Text)
	}
	// h: omit → size * 1.2 (§5).
	h := size * 1.2
	if op.H != nil {
		h = *op.H
	}
	align := op.Align
	if align == "" {
		align = "L"
	}
	if align != "L" && align != "C" && align != "R" {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "invalid align", Detail: fmt.Sprintf("%s: draw_text align %q must be L|C|R", loc, op.Align)}
	}

	pdf.SetXY(*op.X, *op.Y)
	pdf.CellFormat(w, h, op.Text, "", 0, align, false, 0, "")
	return nil
}

func drawImage(pdf *fpdf.Fpdf, op Op, pi, oi int, loc string, registry map[string]Image, registered map[string]bool) *GenError {
	if op.ImageID == "" {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "draw_image requires image_id", Detail: loc + ": draw_image missing \"image_id\""}
	}
	if op.X == nil || op.Y == nil || op.W == nil {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "draw_image requires x, y and w", Detail: loc + ": draw_image missing \"x\"/\"y\"/\"w\""}
	}
	img, ok := registry[op.ImageID]
	if !ok {
		pIdx, oIdx := pi, oi
		return &GenError{
			ErrorCode:    ErrUnknownImageID,
			ErrorMessage: fmt.Sprintf("image_id %q not found in doc.images", op.ImageID),
			ImageID:      op.ImageID,
			PageIndex:    &pIdx,
			OpIndex:      &oIdx,
		}
	}

	// Decode + register once (gofpdf caches by name).
	if !registered[op.ImageID] {
		decoded, err := base64.StdEncoding.DecodeString(img.BytesB64)
		if err != nil {
			return &GenError{
				ErrorCode:    ErrImageDecode,
				ErrorMessage: fmt.Sprintf("image %q is not valid base64", op.ImageID),
				ImageID:      op.ImageID,
			}
		}
		opts := fpdf.ImageOptions{ImageType: strings.ToUpper(img.Format), ReadDpi: false}
		info := pdf.RegisterImageOptionsReader(op.ImageID, opts, bytes.NewReader(decoded))
		if pdf.Error() != nil || info == nil {
			// Reset the latched error so generation can report a clean code.
			detail := ""
			if e := pdf.Error(); e != nil {
				detail = e.Error()
			}
			pdf.ClearError()
			return &GenError{
				ErrorCode:    ErrImageDecode,
				ErrorMessage: fmt.Sprintf("image %q failed to decode as %s: %s", op.ImageID, img.Format, detail),
				ImageID:      op.ImageID,
			}
		}
		registered[op.ImageID] = true
	}

	h := 0.0 // 0/omit → preserve aspect ratio (§5).
	if op.H != nil {
		h = *op.H
	}
	pdf.ImageOptions(op.ImageID, *op.X, *op.Y, *op.W, h, false, fpdf.ImageOptions{ImageType: strings.ToUpper(img.Format)}, 0, "")
	return nil
}

func drawLine(pdf *fpdf.Fpdf, op Op, loc string) *GenError {
	if op.X1 == nil || op.Y1 == nil || op.X2 == nil || op.Y2 == nil {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "draw_line requires x1,y1,x2,y2", Detail: loc + ": draw_line missing endpoint(s)"}
	}
	width := 0.2 // default (§5)
	if op.Width != nil {
		width = *op.Width
	}
	r, g, b := 0, 0, 0 // default black (§5)
	if op.Color != nil {
		r, g, b = op.Color[0], op.Color[1], op.Color[2]
	}
	pdf.SetLineWidth(width)
	pdf.SetDrawColor(r, g, b)
	pdf.Line(*op.X1, *op.Y1, *op.X2, *op.Y2)
	return nil
}

func drawRect(pdf *fpdf.Fpdf, op Op, loc string) *GenError {
	if op.X == nil || op.Y == nil || op.W == nil || op.H == nil {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "draw_rect requires x,y,w,h", Detail: loc + ": draw_rect missing \"x\"/\"y\"/\"w\"/\"h\""}
	}
	style := op.Style
	if style == "" {
		style = "D" // default (§5)
	}
	if style != "D" && style != "F" && style != "DF" {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "invalid rect style", Detail: fmt.Sprintf("%s: draw_rect style %q must be D|F|DF", loc, op.Style)}
	}
	if strings.Contains(style, "F") && op.FillColor == nil {
		return &GenError{ErrorCode: ErrSchemaValidation, ErrorMessage: "rect fill requires fill_color", Detail: fmt.Sprintf("%s: draw_rect style %q requires fill_color", loc, style)}
	}

	width := 0.2 // default (§5)
	if op.StrokeWidth != nil {
		width = *op.StrokeWidth
	}
	sr, sg, sb := 0, 0, 0 // default black (§5)
	if op.StrokeColor != nil {
		sr, sg, sb = op.StrokeColor[0], op.StrokeColor[1], op.StrokeColor[2]
	}
	pdf.SetLineWidth(width)
	pdf.SetDrawColor(sr, sg, sb)
	if op.FillColor != nil {
		pdf.SetFillColor(op.FillColor[0], op.FillColor[1], op.FillColor[2])
	}
	pdf.Rect(*op.X, *op.Y, *op.W, *op.H, style)
	return nil
}

// --- helpers

func orientationFlag(orientation string) string {
	if strings.EqualFold(orientation, "landscape") {
		return "L"
	}
	return "P"
}

func splitFontKey(key string) (family, style string) {
	i := strings.LastIndex(key, "|")
	return key[:i], key[i+1:]
}

// pageSize returns the SizeType for a named format. For known fpdf format names
// (Letter, Legal, A3, A4, A5, Tabloid) we pass an empty SizeType and let
// AddPageFormat resolve by re-using the current page size; but AddPageFormat
// takes a concrete SizeType, so we resolve via the doc's initial format which
// fpdf already parsed. For a per-page override of a standard name we look it up.
func pageSize(pdf *fpdf.Fpdf, format string) fpdf.SizeType {
	if sz, ok := standardSizes[strings.ToLower(format)]; ok {
		return sz
	}
	// Unknown format name: fall back to the document's current page size.
	w, h := pdf.GetPageSize()
	return fpdf.SizeType{Wd: w, Ht: h}
}

// standardSizes are the point dimensions of the formats fpdf recognizes,
// portrait orientation. AddPageFormat applies the orientation flag itself.
var standardSizes = map[string]fpdf.SizeType{
	"letter":  {Wd: 612, Ht: 792},
	"legal":   {Wd: 612, Ht: 1008},
	"tabloid": {Wd: 792, Ht: 1224},
	"a3":      {Wd: 841.89, Ht: 1190.55},
	"a4":      {Wd: 595.28, Ht: 841.89},
	"a5":      {Wd: 420.94, Ht: 595.28},
}
