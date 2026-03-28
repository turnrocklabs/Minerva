package main

import (
	"context"
	"encoding/json"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// obs is the global OBS client, initialized in main.
var obs *OBSClient

// jsonResult wraps data as a JSON text content tool result.
func jsonResult(data any) *mcp.CallToolResult {
	bytes, _ := json.Marshal(data)
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: string(bytes)}},
	}
}

// errorResult returns a tool result marked as an error.
func errorResult(msg string) *mcp.CallToolResult {
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: msg}},
		IsError: true,
	}
}

// --- connect ---

type ConnectArgs struct {
	Host     string `json:"host,omitempty"`
	Port     int    `json:"port,omitempty"`
	Password string `json:"password,omitempty"`
}

func connectHandler(ctx context.Context, req *mcp.CallToolRequest, args ConnectArgs) (*mcp.CallToolResult, any, error) {
	host := args.Host
	if host == "" {
		host = "localhost"
	}
	port := args.Port
	if port == 0 {
		port = 4455
	}

	if err := obs.Connect(host, port, args.Password); err != nil {
		return errorResult("Failed to connect: " + err.Error()), nil, nil
	}

	status, _ := obs.GetStatus()
	return jsonResult(status), nil, nil
}

// --- disconnect ---

type DisconnectArgs struct{}

func disconnectHandler(ctx context.Context, req *mcp.CallToolRequest, args DisconnectArgs) (*mcp.CallToolResult, any, error) {
	if !obs.IsConnected() {
		return errorResult("Not connected to OBS"), nil, nil
	}

	if err := obs.Disconnect(); err != nil {
		return errorResult("Failed to disconnect: " + err.Error()), nil, nil
	}

	return jsonResult(map[string]any{"disconnected": true}), nil, nil
}

// --- get_status ---

type GetStatusArgs struct{}

func getStatusHandler(ctx context.Context, req *mcp.CallToolRequest, args GetStatusArgs) (*mcp.CallToolResult, any, error) {
	status, _ := obs.GetStatus()
	return jsonResult(status), nil, nil
}

// --- list_scenes ---

type ListScenesArgs struct{}

func listScenesHandler(ctx context.Context, req *mcp.CallToolRequest, args ListScenesArgs) (*mcp.CallToolResult, any, error) {
	if !obs.IsConnected() {
		return errorResult("Not connected to OBS"), nil, nil
	}

	sceneNames, currentScene, err := obs.ListScenes()
	if err != nil {
		return errorResult("Failed to list scenes: " + err.Error()), nil, nil
	}

	return jsonResult(map[string]any{
		"scenes":        sceneNames,
		"current_scene": currentScene,
	}), nil, nil
}

// --- switch_scene ---

type SwitchSceneArgs struct {
	Scene string `json:"scene"`
}

func switchSceneHandler(ctx context.Context, req *mcp.CallToolRequest, args SwitchSceneArgs) (*mcp.CallToolResult, any, error) {
	if !obs.IsConnected() {
		return errorResult("Not connected to OBS"), nil, nil
	}

	if args.Scene == "" {
		return errorResult("scene argument is required"), nil, nil
	}

	if err := obs.SwitchScene(args.Scene); err != nil {
		return errorResult("Failed to switch scene: " + err.Error()), nil, nil
	}

	status, _ := obs.GetStatus()
	return jsonResult(status), nil, nil
}

// registerTools registers all OBS MCP tools on the server.
func registerTools(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_connect",
		Description: "Connect to OBS WebSocket server. Defaults to localhost:4455.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"host": {
					"type": "string",
					"description": "OBS WebSocket host (default: localhost)"
				},
				"port": {
					"type": "integer",
					"description": "OBS WebSocket port (default: 4455)"
				},
				"password": {
					"type": "string",
					"description": "OBS WebSocket password (leave empty if authentication is disabled)"
				}
			}
		}`),
	}, connectHandler)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_disconnect",
		Description: "Disconnect from the OBS WebSocket server.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, disconnectHandler)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_get_status",
		Description: "Get current OBS connection status and scene info. Always works, even when disconnected.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, getStatusHandler)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_list_scenes",
		Description: "List all scenes in OBS and identify the current program scene.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, listScenesHandler)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "minerva_obs_controller_switch_scene",
		Description: "Switch the current OBS program scene.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"scene": {
					"type": "string",
					"description": "Name of the scene to switch to"
				}
			},
			"required": ["scene"]
		}`),
	}, switchSceneHandler)
}
