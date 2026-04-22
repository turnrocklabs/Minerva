package main

import (
	"io"
	"os"
	"sync"
)

// serializedStdout wraps os.Stdout with a mutex so writes from the MCP SDK's
// transport and the plugin's own emitEvent/emitState paths cannot interleave
// mid-frame. JSON-RPC over stdio is newline-delimited — a partial frame from
// one goroutine followed by a partial frame from another produces invalid
// JSON on the host side and causes Minerva to drop subsequent tool responses.
//
// Wire this into main.go's MCP server via `&mcp.IOTransport{Writer: sharedStdout, ...}`
// and have writeStdoutJSON in events.go also write through `sharedStdout`
// rather than os.Stdout directly.
type serializedStdout struct {
	mu sync.Mutex
	w  io.Writer
}

func (s *serializedStdout) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
}

func (s *serializedStdout) Close() error { return nil }

var sharedStdout = &serializedStdout{w: os.Stdout}

// nopReadCloser wraps an io.Reader with a trivial Close method so we can pass
// os.Stdin into mcp.IOTransport, which expects io.ReadCloser.
type nopReadCloser struct{ io.Reader }

func (nopReadCloser) Close() error { return nil }
