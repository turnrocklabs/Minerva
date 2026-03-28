package main

import "fmt"

type GridRow string
type GridColumn string
type GridSize string

const (
	RowTop    GridRow = "top"
	RowMiddle GridRow = "middle"
	RowBottom GridRow = "bottom"

	ColLeft   GridColumn = "left"
	ColCenter GridColumn = "center"
	ColRight  GridColumn = "right"

	SizeSmall  GridSize = "small"  // 15% of canvas width
	SizeMedium GridSize = "medium" // 25% of canvas width
	SizeLarge  GridSize = "large"  // 35% of canvas width
)

type CameraTransform struct {
	PositionX    float64
	PositionY    float64
	BoundsWidth  float64
	BoundsHeight float64
	BoundsType   string // "OBS_BOUNDS_STRETCH"
	Alignment    int    // 5 = top-left
}

// ComputeTransform maps a semantic grid position to an OBS scene item transform.
// canvasWidth/Height should come from OBS GetVideoSettings (BaseWidth/BaseHeight).
func ComputeTransform(row GridRow, col GridColumn, size GridSize, canvasWidth, canvasHeight int) CameraTransform {
	var fraction float64
	switch size {
	case SizeSmall:
		fraction = 0.15
	case SizeLarge:
		fraction = 0.35
	default: // SizeMedium
		fraction = 0.25
	}

	boundsWidth := float64(canvasWidth) * fraction
	boundsHeight := boundsWidth * 9.0 / 16.0 // maintain 16:9 aspect ratio

	const margin = 20.0

	var posX float64
	switch col {
	case ColLeft:
		posX = margin
	case ColRight:
		posX = float64(canvasWidth) - boundsWidth - margin
	default: // ColCenter
		posX = (float64(canvasWidth) - boundsWidth) / 2.0
	}

	var posY float64
	switch row {
	case RowTop:
		posY = margin
	case RowBottom:
		posY = float64(canvasHeight) - boundsHeight - margin
	default: // RowMiddle
		posY = (float64(canvasHeight) - boundsHeight) / 2.0
	}

	return CameraTransform{
		PositionX:    posX,
		PositionY:    posY,
		BoundsWidth:  boundsWidth,
		BoundsHeight: boundsHeight,
		BoundsType:   "OBS_BOUNDS_STRETCH",
		Alignment:    5, // top-left anchor
	}
}

// ValidateRow validates and converts a string to a GridRow.
func ValidateRow(s string) (GridRow, error) {
	switch GridRow(s) {
	case RowTop, RowMiddle, RowBottom:
		return GridRow(s), nil
	default:
		return "", fmt.Errorf("invalid row %q: must be one of top, middle, bottom", s)
	}
}

// ValidateColumn validates and converts a string to a GridColumn.
func ValidateColumn(s string) (GridColumn, error) {
	switch GridColumn(s) {
	case ColLeft, ColCenter, ColRight:
		return GridColumn(s), nil
	default:
		return "", fmt.Errorf("invalid column %q: must be one of left, center, right", s)
	}
}

// ValidateSize validates and converts a string to a GridSize.
func ValidateSize(s string) (GridSize, error) {
	switch GridSize(s) {
	case SizeSmall, SizeMedium, SizeLarge:
		return GridSize(s), nil
	default:
		return "", fmt.Errorf("invalid size %q: must be one of small, medium, large", s)
	}
}
