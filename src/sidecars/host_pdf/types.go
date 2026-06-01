package main

// Types mirror the FROZEN host.pdf.generate contract
// (Docs/design/host_pdf_contract.md §4–§6) field-for-field. JSON tags are the
// authoritative wire names; do not rename without a new docket item.

// Doc is the whole declarative document submitted in one host.pdf.generate call.
type Doc struct {
	Defaults *Defaults `json:"defaults,omitempty"`
	Metadata *Metadata `json:"metadata,omitempty"`
	Images   []Image   `json:"images,omitempty"`
	Pages    []Page    `json:"pages"`
}

// Defaults are document-level page defaults (§4). All optional.
type Defaults struct {
	Format      string `json:"format,omitempty"`      // page size; v1 guarantees "Letter"
	Orientation string `json:"orientation,omitempty"` // "portrait" | "landscape"
	Unit        string `json:"unit,omitempty"`        // v1 guarantees "pt"
}

// Metadata maps to SetTitle/SetAuthor/SetSubject/SetCreator (§4).
type Metadata struct {
	Title   string `json:"title,omitempty"`
	Author  string `json:"author,omitempty"`
	Subject string `json:"subject,omitempty"`
	Creator string `json:"creator,omitempty"`
}

// Image is one entry in the document image registry (§4). Bytes are embedded
// once; ops reference it by id.
type Image struct {
	ID       string `json:"id"`
	Format   string `json:"format"` // e.g. "png", "jpg"
	BytesB64 string `json:"bytes_b64"`
}

// Page is an ordered op list drawn back-to-front (§4). Optional per-page
// overrides of the document format/orientation.
type Page struct {
	Format      string `json:"format,omitempty"`
	Orientation string `json:"orientation,omitempty"`
	Ops         []Op   `json:"ops"`
}

// Op is the union of all op kinds (§5). Decoded permissively then validated
// strictly per-kind so unknown kinds / missing required fields are rejected
// with a precise location.
type Op struct {
	Kind string `json:"kind"`

	// draw_text
	Text  string   `json:"text,omitempty"`
	Font  *Font    `json:"font,omitempty"`
	W     *float64 `json:"w,omitempty"`
	H     *float64 `json:"h,omitempty"`
	Align string   `json:"align,omitempty"`
	Fit   *Fit     `json:"fit,omitempty"`

	// draw_image
	ImageID string `json:"image_id,omitempty"`

	// draw_line
	X1    *float64 `json:"x1,omitempty"`
	Y1    *float64 `json:"y1,omitempty"`
	X2    *float64 `json:"x2,omitempty"`
	Y2    *float64 `json:"y2,omitempty"`
	Width *float64 `json:"width,omitempty"`

	// draw_rect
	Style       string   `json:"style,omitempty"`
	StrokeWidth *float64 `json:"stroke_width,omitempty"`
	StrokeColor *RGB     `json:"stroke_color,omitempty"`
	FillColor   *RGB     `json:"fill_color,omitempty"`

	// shared geometry (draw_text / draw_image / draw_rect)
	X *float64 `json:"x,omitempty"`
	Y *float64 `json:"y,omitempty"`

	// shared color (draw_text / draw_line)
	Color *RGB `json:"color,omitempty"`
}

// Font names a font inline by family + style + size (§4 — no font handle).
type Font struct {
	Family string  `json:"family"`
	Style  string  `json:"style"`
	Size   float64 `json:"size"`
}

// Fit is the optional auto-shrink spec for draw_text (§5).
type Fit struct {
	MaxWidth float64  `json:"max_width"`
	MinSize  float64  `json:"min_size"`
	Step     *float64 `json:"step,omitempty"` // default 1
}

// RGB is an [r, g, b] color, integers 0–255 (§2).
type RGB [3]int

// Result is the success payload (§6).
type Result struct {
	BytesB64    string `json:"bytes_b64"`
	ByteSize    int    `json:"byte_size"`
	PageCount   int    `json:"page_count"`
	ContentType string `json:"content_type"`
}

// GenError carries a contract error code (§7) plus optional context fields.
type GenError struct {
	ErrorCode    string `json:"error_code"`
	ErrorMessage string `json:"error_message"`

	// font_not_available
	Family    string   `json:"family,omitempty"`
	Style     string   `json:"style,omitempty"`
	Available []string `json:"available,omitempty"`

	// unknown_image_id / image_decode_failed
	ImageID   string `json:"image_id,omitempty"`
	PageIndex *int   `json:"page_index,omitempty"`
	OpIndex   *int   `json:"op_index,omitempty"`

	// schema_validation_failed / pdf_generation_failed
	Detail string `json:"detail,omitempty"`
}

func (e *GenError) Error() string {
	if e.Detail != "" {
		return e.ErrorCode + ": " + e.ErrorMessage + " (" + e.Detail + ")"
	}
	return e.ErrorCode + ": " + e.ErrorMessage
}

// Error code constants (§7).
const (
	ErrSchemaValidation = "schema_validation_failed"
	ErrPayloadTooLarge  = "payload_too_large"
	ErrFontNotAvailable = "font_not_available"
	ErrUnknownImageID   = "unknown_image_id"
	ErrImageDecode      = "image_decode_failed"
	ErrPDFGeneration    = "pdf_generation_failed"
)
