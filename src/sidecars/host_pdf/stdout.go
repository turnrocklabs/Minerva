package main

import (
	"io"
	"os"
	"sync"
)

// serializedStdout wraps os.Stdout with a mutex so writes from the MCP SDK's
// transport cannot interleave mid-frame. JSON-RPC over stdio is
// newline-delimited; a partial frame from one goroutine followed by another
// produces invalid JSON on the host side. Mirrors the obs_controller sidecar.
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

// nopReadCloser wraps an io.Reader with a trivial Close so we can pass os.Stdin
// into mcp.IOTransport, which expects io.ReadCloser.
type nopReadCloser struct{ io.Reader }

func (nopReadCloser) Close() error { return nil }
