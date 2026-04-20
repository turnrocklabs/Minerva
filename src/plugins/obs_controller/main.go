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

	// Auto-connect lives in the panel now: the password is in Minerva's vault,
	// not in the on-disk config, so the plugin process can't initiate a
	// connection without help. The panel reads the password via the
	// secrets:get:obs_password capability and calls the connect tool.

	log.Println("Starting OBS Controller MCP server on stdio")

	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
