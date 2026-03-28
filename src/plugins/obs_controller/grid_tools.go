package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/andreykaipov/goobs/api/requests/sceneitems"
	"github.com/andreykaipov/goobs/api/typedefs"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// getCameraSource returns the configured webcam source name from the plugin config.
func getCameraSource() string {
	return GetConfig().CameraSource
}

// SetCameraArgs are the input parameters for set_camera_position.
type SetCameraArgs struct {
	Row    string `json:"row"`
	Column string `json:"column"`
	Size   string `json:"size,omitempty"` // default: "medium"
}

// ListSourcesArgs are the input parameters for list_sources (none required).
type ListSourcesArgs struct{}

func setCameraPositionHandler(
	ctx context.Context,
	req *mcp.CallToolRequest,
	args SetCameraArgs,
) (*mcp.CallToolResult, any, error) {
	if obs == nil || obs.client == nil {
		return errorResult("not connected to OBS. Call minerva_obs_controller_connect first."), nil, nil
	}

	row, err := ValidateRow(args.Row)
	if err != nil {
		return errorResult(err.Error()), nil, nil
	}
	col, err := ValidateColumn(args.Column)
	if err != nil {
		return errorResult(err.Error()), nil, nil
	}

	sizeStr := args.Size
	if sizeStr == "" {
		sizeStr = "medium"
	}
	size, err := ValidateSize(sizeStr)
	if err != nil {
		return errorResult(err.Error()), nil, nil
	}

	camSrc := getCameraSource()
	if camSrc == "" {
		return errorResult("camera_source not configured. Call minerva_obs_controller_configure or use list_sources to find it."), nil, nil
	}

	// Get canvas dimensions from OBS.
	videoResp, err := obs.client.Config.GetVideoSettings()
	if err != nil {
		return errorResult(fmt.Sprintf("failed to get video settings: %v", err)), nil, nil
	}
	canvasWidth := int(videoResp.BaseWidth)
	canvasHeight := int(videoResp.BaseHeight)
	log.Printf("canvas size: %dx%d", canvasWidth, canvasHeight)

	transform := ComputeTransform(row, col, size, canvasWidth, canvasHeight)
	log.Printf("computed transform: pos=(%.1f,%.1f) bounds=(%.1fx%.1f)",
		transform.PositionX, transform.PositionY, transform.BoundsWidth, transform.BoundsHeight)

	// Get current scene.
	sceneResp, err := obs.client.Scenes.GetCurrentProgramScene()
	if err != nil {
		return errorResult(fmt.Sprintf("failed to get current scene: %v", err)), nil, nil
	}
	sceneName := sceneResp.SceneName

	// Resolve scene item ID for the camera source.
	idResp, err := obs.client.SceneItems.GetSceneItemId(&sceneitems.GetSceneItemIdParams{
		SceneName:  &sceneName,
		SourceName: &camSrc,
	})
	if err != nil {
		return errorResult(fmt.Sprintf("failed to get scene item ID for source %q in scene %q: %v", camSrc, sceneName, err)), nil, nil
	}
	sceneItemID := idResp.SceneItemId

	// Build the OBS transform.
	// IMPORTANT: Width/Height are read-only computed values in OBS — setting them is silently ignored.
	// Use BoundsWidth/BoundsHeight + BoundsType=OBS_BOUNDS_STRETCH for sizing.
	alignment := float64(transform.Alignment)
	obsTransform := &typedefs.SceneItemTransform{
		PositionX:    transform.PositionX,
		PositionY:    transform.PositionY,
		BoundsWidth:  transform.BoundsWidth,
		BoundsHeight: transform.BoundsHeight,
		BoundsType:   transform.BoundsType,
		Alignment:    alignment,
	}

	// Apply the transform.
	_, err = obs.client.SceneItems.SetSceneItemTransform(&sceneitems.SetSceneItemTransformParams{
		SceneName:          &sceneName,
		SceneItemId:        &sceneItemID,
		SceneItemTransform: obsTransform,
	})
	if err != nil {
		return errorResult(fmt.Sprintf("failed to set scene item transform: %v", err)), nil, nil
	}

	result := map[string]any{
		"row":          string(row),
		"column":       string(col),
		"size":         string(size),
		"position_x":   transform.PositionX,
		"position_y":   transform.PositionY,
		"bounds_width": transform.BoundsWidth,
		"bounds_height": transform.BoundsHeight,
	}
	data, err := json.Marshal(result)
	if err != nil {
		return nil, nil, fmt.Errorf("marshal response: %w", err)
	}
	return &mcp.CallToolResult{
		Content: []mcp.Content{
			&mcp.TextContent{Text: string(data)},
		},
	}, nil, nil
}

func listSourcesHandler(
	ctx context.Context,
	req *mcp.CallToolRequest,
	args ListSourcesArgs,
) (*mcp.CallToolResult, any, error) {
	if obs == nil || obs.client == nil {
		return errorResult("not connected to OBS. Call minerva_obs_controller_connect first."), nil, nil
	}

	// Get current scene.
	sceneResp, err := obs.client.Scenes.GetCurrentProgramScene()
	if err != nil {
		return errorResult(fmt.Sprintf("failed to get current scene: %v", err)), nil, nil
	}
	sceneName := sceneResp.SceneName

	// List all scene items.
	listResp, err := obs.client.SceneItems.GetSceneItemList(&sceneitems.GetSceneItemListParams{
		SceneName: &sceneName,
	})
	if err != nil {
		return errorResult(fmt.Sprintf("failed to list scene items: %v", err)), nil, nil
	}

	type sourceInfo struct {
		Name        string `json:"name"`
		Type        string `json:"type"`
		SceneItemID int    `json:"scene_item_id"`
	}

	sources := make([]sourceInfo, 0, len(listResp.SceneItems))
	for _, item := range listResp.SceneItems {
		sources = append(sources, sourceInfo{
			Name:        item.SourceName,
			Type:        item.SourceType,
			SceneItemID: item.SceneItemID,
		})
	}

	result := map[string]any{
		"scene":   sceneName,
		"sources": sources,
	}
	data, err := json.Marshal(result)
	if err != nil {
		return nil, nil, fmt.Errorf("marshal response: %w", err)
	}
	return &mcp.CallToolResult{
		Content: []mcp.Content{
			&mcp.TextContent{Text: string(data)},
		},
	}, nil, nil
}

// registerGridTools registers the semantic camera grid tools with the MCP server.
func registerGridTools(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_set_camera_position",
		Description: "Position the webcam overlay using a semantic 3x3 grid. Row: top/middle/bottom, Column: left/center/right, Size: small/medium/large.",
	}, setCameraPositionHandler)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_list_sources",
		Description: "List all sources in the current OBS scene. Use this to discover the webcam source name for camera positioning.",
	}, listSourcesHandler)
}
