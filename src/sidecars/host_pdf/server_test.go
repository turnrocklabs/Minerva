package main

import (
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// TestRegisterToolsNoPanic guards the server-construction path that the pure
// Generate() tests never exercise. Regression: AddTool with an In type of
// json.RawMessage made the SDK infer a non-object input schema and panic at
// startup ("input schema must have type object"). The sidecar then exited
// immediately, so every spawn surfaced as broker "Can't connect" — yet the
// Generate() unit tests stayed green because they bypass the MCP server. This
// test builds a real server and registers the tool; a panic here means the
// shipped binary would fail to start.
func TestRegisterToolsNoPanic(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("registerTools panicked — the sidecar binary would not start: %v", r)
		}
	}()
	server := mcp.NewServer(&mcp.Implementation{Name: "host_pdf", Version: "test"}, nil)
	registerTools(server)
}
