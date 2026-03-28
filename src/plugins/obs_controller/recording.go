package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// --- start_recording ---

type StartRecordingArgs struct{}

func startRecordingHandler(ctx context.Context, req *mcp.CallToolRequest, args StartRecordingArgs) (*mcp.CallToolResult, any, error) {
	if !obs.IsConnected() {
		return errorResult("Not connected to OBS"), nil, nil
	}

	obs.mu.Lock()
	_, err := obs.client.Record.StartRecord()
	obs.mu.Unlock()

	if err != nil {
		return errorResult("Failed to start recording: " + err.Error()), nil, nil
	}

	// Return current recording status.
	obs.mu.RLock()
	statusResp, statusErr := obs.client.Record.GetRecordStatus()
	obs.mu.RUnlock()

	result := map[string]any{"started": true}
	if statusErr == nil {
		result["recording"] = statusResp.OutputActive
		result["timecode"] = statusResp.OutputTimecode
	}

	go emitCurrentState()
	return jsonResult(result), nil, nil
}

// --- stop_recording ---

type StopRecordingArgs struct{}

func stopRecordingHandler(ctx context.Context, req *mcp.CallToolRequest, args StopRecordingArgs) (*mcp.CallToolResult, any, error) {
	if !obs.IsConnected() {
		return errorResult("Not connected to OBS"), nil, nil
	}

	obs.mu.Lock()
	resp, err := obs.client.Record.StopRecord()
	obs.mu.Unlock()

	if err != nil {
		return errorResult("Failed to stop recording: " + err.Error()), nil, nil
	}

	go emitCurrentState()
	return jsonResult(map[string]any{
		"stopped":     true,
		"output_path": resp.OutputPath,
	}), nil, nil
}

// --- list_recordings ---

type ListRecordingsArgs struct {
	Limit int `json:"limit,omitempty"`
}

var videoExtensions = map[string]bool{
	".mp4": true,
	".mkv": true,
	".mov": true,
	".flv": true,
	".avi": true,
	".ts":  true,
}

type recordingEntry struct {
	Filename string    `json:"filename"`
	Path     string    `json:"path"`
	SizeMB   float64   `json:"size_mb"`
	Modified time.Time `json:"modified"`
}

func listRecordingsHandler(ctx context.Context, req *mcp.CallToolRequest, args ListRecordingsArgs) (*mcp.CallToolResult, any, error) {
	limit := args.Limit
	if limit <= 0 {
		limit = 10
	}

	// Determine output directory: prefer config, fall back to querying OBS.
	dir := GetConfig().OutputDirectory
	if dir == "" {
		if !obs.IsConnected() {
			return errorResult("output_directory not configured and not connected to OBS"), nil, nil
		}
		obs.mu.RLock()
		dirResp, err := obs.client.Config.GetRecordDirectory()
		obs.mu.RUnlock()
		if err != nil {
			return errorResult("Failed to get record directory from OBS: " + err.Error()), nil, nil
		}
		dir = dirResp.RecordDirectory
	}

	if dir == "" {
		return errorResult("Could not determine OBS output directory"), nil, nil
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to read directory %s: %v", dir, err)), nil, nil
	}

	var recordings []recordingEntry
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if !videoExtensions[ext] {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		fullPath := filepath.Join(dir, entry.Name())
		sizeMB := float64(info.Size()) / (1024 * 1024)

		recordings = append(recordings, recordingEntry{
			Filename: entry.Name(),
			Path:     fullPath,
			SizeMB:   sizeMB,
			Modified: info.ModTime(),
		})
	}

	// Sort newest first.
	sort.Slice(recordings, func(i, j int) bool {
		return recordings[i].Modified.After(recordings[j].Modified)
	})

	if len(recordings) > limit {
		recordings = recordings[:limit]
	}

	return jsonResult(map[string]any{
		"directory":  dir,
		"recordings": recordings,
		"count":      len(recordings),
	}), nil, nil
}

// --- configure ---

type ConfigureArgs struct {
	OBSHost         *string `json:"obs_host,omitempty"`
	OBSPort         *int    `json:"obs_port,omitempty"`
	OBSPassword     *string `json:"obs_password,omitempty"`
	CameraSource    *string `json:"camera_source,omitempty"`
	OutputDirectory *string `json:"output_directory,omitempty"`
	AutoConnect     *bool   `json:"auto_connect,omitempty"`
}

func configureHandler(ctx context.Context, req *mcp.CallToolRequest, args ConfigureArgs) (*mcp.CallToolResult, any, error) {
	updates := make(map[string]any)

	if args.OBSHost != nil {
		updates["obs_host"] = *args.OBSHost
	}
	if args.OBSPort != nil {
		updates["obs_port"] = *args.OBSPort
	}
	if args.OBSPassword != nil {
		updates["obs_password"] = *args.OBSPassword
	}
	if args.CameraSource != nil {
		updates["camera_source"] = *args.CameraSource
	}
	if args.OutputDirectory != nil {
		updates["output_directory"] = *args.OutputDirectory
	}
	if args.AutoConnect != nil {
		updates["auto_connect"] = *args.AutoConnect
	}

	if len(updates) == 0 {
		return jsonResult(RedactedConfig()), nil, nil
	}

	if err := UpdateConfig(updates); err != nil {
		return errorResult("Failed to save config: " + err.Error()), nil, nil
	}

	return jsonResult(RedactedConfig()), nil, nil
}

// registerRecordingTools registers recording and config MCP tools on the server.
func registerRecordingTools(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_start_recording",
		Description: "Start OBS recording.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, startRecordingHandler)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_stop_recording",
		Description: "Stop OBS recording and return the output file path.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, stopRecordingHandler)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_list_recordings",
		Description: "List video recordings in the OBS output directory, sorted by newest first.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"limit": {
					"type": "integer",
					"description": "Max recordings to return (default: 10)"
				}
			}
		}`),
	}, listRecordingsHandler)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_configure",
		Description: "Set OBS connection details, webcam source name, and output directory. Saved to disk for persistence.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"obs_host":         {"type": "string",  "description": "OBS WebSocket host (default: localhost)"},
				"obs_port":         {"type": "integer", "description": "OBS WebSocket port (default: 4455)"},
				"obs_password":     {"type": "string",  "description": "OBS WebSocket password"},
				"camera_source":    {"type": "string",  "description": "Name of the webcam source in OBS"},
				"output_directory": {"type": "string",  "description": "Directory where OBS saves recordings"},
				"auto_connect":     {"type": "boolean", "description": "Auto-connect to OBS on plugin start"}
			}
		}`),
	}, configureHandler)
}
