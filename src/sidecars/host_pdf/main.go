package main

import (
	"context"
	"encoding/json"
	"log"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// main is the thin MCP-over-stdio adapter. It mirrors the obs_controller sidecar:
// all logging to stderr, stdout reserved for JSON-RPC via the mutex-serialized
// sharedStdout writer, official go-sdk + mcp.IOTransport. The broker envelope
// handshake (wrapping into {success,result}) is P1.2's concern — this adapter
// returns the raw result payload (or a structured error) and stays thin.
func main() {
	log.SetOutput(os.Stderr)
	log.SetPrefix("[host_pdf] ")

	server := mcp.NewServer(
		&mcp.Implementation{
			Name:    "host_pdf",
			Version: "0.1.0",
		},
		nil,
	)

	registerTools(server)

	log.Println("Starting host.pdf MCP server on stdio")

	transport := &mcp.IOTransport{
		Reader: nopReadCloser{os.Stdin},
		Writer: sharedStdout,
	}
	if err := server.Run(context.Background(), transport); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

// registerTools registers the single host.pdf.generate tool. The input type is
// json.RawMessage so we can apply strict (unknown-key-rejecting) decoding via
// DecodeDoc rather than the SDK's lenient struct unmarshal.
func registerTools(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "host_pdf_generate",
		Description: "Generate a PDF from a declarative document (pages of draw ops). Returns base64 PDF bytes. Implements the host.pdf.generate capability contract.",
	}, generateHandler)
}

func generateHandler(ctx context.Context, req *mcp.CallToolRequest, args json.RawMessage) (*mcp.CallToolResult, any, error) {
	doc, gErr := DecodeDoc([]byte(args))
	if gErr != nil {
		return jsonError(gErr), nil, nil
	}
	result, gErr := Generate(doc)
	if gErr != nil {
		return jsonError(gErr), nil, nil
	}
	return jsonResult(result), result, nil
}

// jsonResult wraps a value as a JSON text-content tool result.
func jsonResult(v any) *mcp.CallToolResult {
	b, _ := json.Marshal(v)
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: string(b)}},
	}
}

// jsonError wraps a GenError as an error tool result. The structured error
// (with its contract error_code) is the JSON body so P1.2 broker wiring can
// lift it into the {success:false, error_code, ...} envelope.
func jsonError(e *GenError) *mcp.CallToolResult {
	b, _ := json.Marshal(e)
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: string(b)}},
		IsError: true,
	}
}
