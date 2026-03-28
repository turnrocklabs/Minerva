package main

import (
	"encoding/json"
	"log"
	"os"
	"sync"

	"github.com/andreykaipov/goobs/api/events"
)

// stdoutMu serializes all writes to stdout.
// MCP tool responses and event notifications share stdout, so we need a mutex.
var stdoutMu sync.Mutex

// emitEvent sends a minerva/plugin_event JSON-RPC notification on stdout.
func emitEvent(name string, payload map[string]any) {
	msg := map[string]any{
		"jsonrpc": "2.0",
		"method":  "minerva/plugin_event",
		"params": map[string]any{
			"event":   name,
			"payload": payload,
		},
	}
	writeStdoutJSON(msg)
	log.Printf("Emitted event: %s", name)
}

// emitState sends a minerva/plugin_state JSON-RPC notification on stdout.
func emitState(state map[string]any) {
	msg := map[string]any{
		"jsonrpc": "2.0",
		"method":  "minerva/plugin_state",
		"params": map[string]any{
			"state": state,
		},
	}
	writeStdoutJSON(msg)
	log.Printf("Emitted state update")
}

// writeStdoutJSON writes a JSON message to stdout with newline, thread-safe.
func writeStdoutJSON(msg map[string]any) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal event: %v", err)
		return
	}
	data = append(data, '\n')

	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	os.Stdout.Write(data)
}

// buildCurrentState returns the current OBS state as a map.
func buildCurrentState() map[string]any {
	state := map[string]any{
		"connected": obs.IsConnected(),
		"scene":     "",
		"recording": false,
		"camera":    map[string]any{},
	}

	if obs.IsConnected() {
		status, err := obs.GetStatus()
		if err == nil {
			if scene, ok := status["scene"]; ok {
				state["scene"] = scene
			}
			if recording, ok := status["recording"]; ok {
				state["recording"] = recording
			}
		}
	}

	state["camera"] = getLastCameraPosition()

	return state
}

// emitCurrentState emits a full state snapshot.
func emitCurrentState() {
	emitState(buildCurrentState())
}

// StartEventListener subscribes to OBS events and emits them to Minerva.
// Must be called after a successful Connect().
func (o *OBSClient) StartEventListener() {
	go func() {
		for event := range o.client.IncomingEvents {
			switch e := event.(type) {
			case *events.CurrentProgramSceneChanged:
				emitEvent("obs.scene_changed", map[string]any{
					"scene": e.SceneName,
				})
				go emitCurrentState()
			case *events.RecordStateChanged:
				if e.OutputActive {
					emitEvent("obs.recording_started", map[string]any{})
				} else {
					emitEvent("obs.recording_stopped", map[string]any{
						"output_path": e.OutputPath,
					})
				}
				go emitCurrentState()
			case *events.ExitStarted:
				emitEvent("obs.disconnected", map[string]any{})
				o.mu.Lock()
				o.connected = false
				o.mu.Unlock()
				go emitCurrentState()
			}
		}
	}()
}
