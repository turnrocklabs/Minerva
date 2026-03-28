package main

import (
	"context"
	"log"
	"os"
	"path/filepath"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func main() {
	// All logging goes to stderr; stdout is reserved for MCP JSON-RPC transport.
	log.SetOutput(os.Stderr)
	log.SetPrefix("[obs_controller] ")

	obs = NewOBSClient()

	server := mcp.NewServer(
		&mcp.Implementation{
			Name:    "obs_controller",
			Version: "0.1.0",
		},
		nil,
	)

	registerTools(server)
	registerGridTools(server)
	registerRecordingTools(server)

	// Load config from the directory the binary lives in.
	exePath, err := os.Executable()
	if err != nil {
		log.Printf("Could not determine executable path: %v (using defaults)", err)
		exePath = os.Args[0]
	}
	dataDir := filepath.Dir(exePath)
	if err := LoadConfig(dataDir); err != nil {
		log.Printf("Config load: %v (using defaults)", err)
	}

	// Auto-connect if configured.
	config := GetConfig()
	if config.AutoConnect && config.OBSHost != "" {
		log.Printf("Auto-connecting to OBS at %s:%d", config.OBSHost, config.OBSPort)
		if err := obs.Connect(config.OBSHost, config.OBSPort, config.OBSPassword); err != nil {
			log.Printf("Auto-connect failed (OBS may not be running): %v", err)
		} else {
			log.Println("Auto-connected to OBS")
		}
	}

	log.Println("Starting OBS Controller MCP server on stdio")

	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
