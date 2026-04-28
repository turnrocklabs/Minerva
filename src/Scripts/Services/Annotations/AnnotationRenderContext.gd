class_name AnnotationRenderContext
extends RefCounted
## Facade passed to AnnotationKind.render(). Abstracts the draw target so a
## kind's render() works identically across PCB canvas, CAD SubViewports,
## Graphics panel, and any future editor.
##
## Design §4.2. All drawing helpers apply ctx.transform before forwarding to
## Godot's RenderingServer so plugin kinds never need to deal with the
## document-to-screen mapping themselves.
##
## Units: ctx.unit is the editor's display unit string ("mm", "in", "deg", …).
## Per-primitive unit overrides take precedence (read primitive["unit"] first,
## fall back to ctx.unit). Design §5 / plan-decision §7.
##
## Author default colours (design §5):
##   human → Color(1.0, 0.5, 1.0)   light magenta — matches legacy PCB convention
##   ai    → Color(0.0, 1.0, 1.0)   cyan

# ── Draw-target state ─────────────────────────────────────────────────────────

## RID of the canvas item to draw on (RenderingServer draw target).
var canvas_item: RID

## Maps document-space coordinates to screen-space pixels.
var transform: Transform2D = Transform2D.IDENTITY

## Visible region in screen space. Renderers may cull outside this rect.
var viewport_rect: Rect2 = Rect2()

## Theme for colors and fonts. May be null; renderers should guard.
var theme: Theme = null

## Current editor zoom factor. Used to scale stroke widths / head sizes so
## annotations don't appear microscopic at high zoom or huge at low zoom.
var zoom: float = 1.0

## Editor-supplied coordinate context string (e.g. "pcb", "cad:top", "graphics").
## Read-only from the renderer's perspective.
var view_context: String = ""

## Editor display unit for measure primitives ("mm", "in", "deg", …).
## Per-primitive "unit" field overrides this (design §5 / §14 Q2).
var unit: String = "mm"

# ── Factory helper ─────────────────────────────────────────────────────────────

## Construct a fully populated context in one call.
static func create(
	p_canvas_item: RID,
	p_transform: Transform2D,
	p_viewport_rect: Rect2,
	p_theme: Theme,
	p_zoom: float,
	p_view_context: String,
	p_unit: String = "mm"
) -> AnnotationRenderContext:
	var ctx := AnnotationRenderContext.new()
	ctx.canvas_item   = p_canvas_item
	ctx.transform     = p_transform
	ctx.viewport_rect = p_viewport_rect
	ctx.theme         = p_theme
	ctx.zoom          = p_zoom
	ctx.view_context  = p_view_context
	ctx.unit          = p_unit
	return ctx

# ── Coordinate conversion ──────────────────────────────────────────────────────

## Converts a document-space point to screen-space pixels.
func to_screen(p: Vector2) -> Vector2:
	return transform * p

## Converts a screen-space point back to document-space.
func from_screen(p: Vector2) -> Vector2:
	return transform.affine_inverse() * p

# ── Drawing helpers ────────────────────────────────────────────────────────────
## All helpers transform coordinates before drawing so plugin kinds work in
## document space without knowing the camera setup.

func draw_line(a: Vector2, b: Vector2, color: Color, width: float = 1.0) -> void:
	RenderingServer.canvas_item_add_line(
		canvas_item,
		to_screen(a),
		to_screen(b),
		color,
		width
	)


func draw_polyline(points: PackedVector2Array, color: Color, width: float = 1.0) -> void:
	var screen_pts := PackedVector2Array()
	screen_pts.resize(points.size())
	for i in points.size():
		screen_pts[i] = to_screen(points[i])
	RenderingServer.canvas_item_add_polyline(canvas_item, screen_pts, PackedColorArray([color]), width)


func draw_polygon(points: PackedVector2Array, colors: PackedColorArray) -> void:
	var screen_pts := PackedVector2Array()
	screen_pts.resize(points.size())
	for i in points.size():
		screen_pts[i] = to_screen(points[i])
	RenderingServer.canvas_item_add_polygon(canvas_item, screen_pts, colors)


## Draws a string at document-space pos using the supplied font.
## Falls back to ThemeDB.fallback_font if font is null.
func draw_string(
	font: Font,
	pos: Vector2,
	text: String,
	color: Color,
	size: int = 16
) -> void:
	var f: Font = font
	if f == null:
		f = ThemeDB.fallback_font
	if f == null:
		return
	var screen_pos := to_screen(pos)
	f.draw_string(canvas_item, screen_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


## Draws a string at document-space `pos`, rotated by `rotation_rad` around `pos`.
## `size` is the desired pixel size — callers are expected to pre-multiply any
## scale factor into it. Resets the canvas-item transform to identity after
## drawing so subsequent draws are unaffected.
func draw_string_rotated(
	font: Font,
	pos: Vector2,
	text: String,
	color: Color,
	size: int = 16,
	rotation_rad: float = 0.0
) -> void:
	var f: Font = font
	if f == null:
		f = ThemeDB.fallback_font
	if f == null:
		return
	var screen_pos := to_screen(pos)
	if absf(rotation_rad) < 0.0001:
		f.draw_string(canvas_item, screen_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
		return
	# Set a canvas-item transform that translates to screen_pos and rotates by
	# rotation_rad. Draw at origin in that local frame; reset to identity after.
	var t := Transform2D(rotation_rad, screen_pos)
	RenderingServer.canvas_item_add_set_transform(canvas_item, t)
	f.draw_string(canvas_item, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
	RenderingServer.canvas_item_add_set_transform(canvas_item, Transform2D.IDENTITY)


## width applies to the stroke when filled=false.  Pass 1.0 / ctx.zoom for a
## zoom-invariant one-pixel border; omit (default 1.0) for a fixed-world-unit stroke.
## Added per follow-up item 2 (review comment 217).
func draw_rect(rect: Rect2, color: Color, filled: bool, width: float = 1.0) -> void:
	# Transform all four corners independently (handles rotated transforms).
	# Note: corners named with _corner suffix because plain `tr` shadows
	# Object.tr() (Godot's translation lookup method).
	var tl_corner := to_screen(rect.position)
	var br_corner := to_screen(rect.position + rect.size)
	var tr_corner := to_screen(Vector2(rect.position.x + rect.size.x, rect.position.y))
	var bl_corner := to_screen(Vector2(rect.position.x, rect.position.y + rect.size.y))

	if filled:
		var pts  := PackedVector2Array([tl_corner, tr_corner, br_corner, bl_corner])
		var cols := PackedColorArray([color, color, color, color])
		RenderingServer.canvas_item_add_polygon(canvas_item, pts, cols)
	else:
		# Stroke as a closed polyline.
		RenderingServer.canvas_item_add_line(canvas_item, tl_corner, tr_corner, color, width)
		RenderingServer.canvas_item_add_line(canvas_item, tr_corner, br_corner, color, width)
		RenderingServer.canvas_item_add_line(canvas_item, br_corner, bl_corner, color, width)
		RenderingServer.canvas_item_add_line(canvas_item, bl_corner, tl_corner, color, width)

# ── Author colour helper ───────────────────────────────────────────────────────

## Returns the default annotation colour for the given author string.
## Callers should check payload["color"] first and use this as a fallback.
static func author_color(author: String) -> Color:
	match author:
		"human": return Color(1.0, 0.5, 1.0)   # light magenta — legacy PCB convention
		"ai":    return Color(0.0, 1.0, 1.0)    # cyan
		_:       return Color(0.8, 0.8, 0.8)    # neutral grey for unknown / placeholder

# ── Unit helpers ───────────────────────────────────────────────────────────────

## Returns the effective unit for a primitive, respecting primitive-level override.
## Usage: var u := ctx.effective_unit(primitive_dict)
func effective_unit(primitive: Dictionary) -> String:
	if primitive.has("unit") and primitive["unit"] is String:
		return primitive["unit"]
	return unit
