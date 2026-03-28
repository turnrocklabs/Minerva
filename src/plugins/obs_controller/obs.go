package main

import (
	"fmt"
	"sync"

	"github.com/andreykaipov/goobs"
	"github.com/andreykaipov/goobs/api/requests/sceneitems"
	"github.com/andreykaipov/goobs/api/requests/scenes"
)

// OBSClient wraps the goobs client with connection state tracking.
type OBSClient struct {
	client    *goobs.Client
	connected bool
	mu        sync.RWMutex
}

func NewOBSClient() *OBSClient {
	return &OBSClient{}
}

func (o *OBSClient) Connect(host string, port int, password string) error {
	o.mu.Lock()
	defer o.mu.Unlock()

	// Disconnect existing connection if any.
	if o.client != nil {
		_ = o.client.Disconnect()
		o.client = nil
		o.connected = false
	}

	addr := fmt.Sprintf("%s:%d", host, port)
	var opts []goobs.Option
	if password != "" {
		opts = append(opts, goobs.WithPassword(password))
	}

	client, err := goobs.New(addr, opts...)
	if err != nil {
		return fmt.Errorf("connecting to OBS at %s: %w", addr, err)
	}

	o.client = client
	o.connected = true
	return nil
}

func (o *OBSClient) Disconnect() error {
	o.mu.Lock()
	defer o.mu.Unlock()

	if o.client == nil {
		return fmt.Errorf("not connected")
	}

	err := o.client.Disconnect()
	o.client = nil
	o.connected = false
	return err
}

func (o *OBSClient) IsConnected() bool {
	o.mu.RLock()
	defer o.mu.RUnlock()
	return o.connected
}

// ListScenes returns scene names, current scene name, and any error.
func (o *OBSClient) ListScenes() ([]string, string, error) {
	o.mu.RLock()
	defer o.mu.RUnlock()

	if !o.connected || o.client == nil {
		return nil, "", fmt.Errorf("not connected")
	}

	resp, err := o.client.Scenes.GetSceneList()
	if err != nil {
		o.connected = false
		return nil, "", fmt.Errorf("GetSceneList: %w", err)
	}

	names := make([]string, 0, len(resp.Scenes))
	for _, s := range resp.Scenes {
		names = append(names, s.SceneName)
	}

	return names, resp.CurrentProgramSceneName, nil
}

func (o *OBSClient) SwitchScene(name string) error {
	o.mu.Lock()
	defer o.mu.Unlock()

	if !o.connected || o.client == nil {
		return fmt.Errorf("not connected")
	}

	_, err := o.client.Scenes.SetCurrentProgramScene(
		scenes.NewSetCurrentProgramSceneParams().WithSceneName(name),
	)
	if err != nil {
		o.connected = false
		return fmt.Errorf("SetCurrentProgramScene: %w", err)
	}

	return nil
}

// GetStatus returns a status dict with keys: connected, scene, recording, sources_count.
func (o *OBSClient) GetStatus() (map[string]any, error) {
	o.mu.RLock()
	defer o.mu.RUnlock()

	status := map[string]any{
		"connected":     o.connected,
		"scene":         "",
		"recording":     false,
		"sources_count": 0,
	}

	if !o.connected || o.client == nil {
		return status, nil
	}

	// Get current scene.
	sceneResp, err := o.client.Scenes.GetSceneList()
	if err != nil {
		o.connected = false
		status["connected"] = false
		return status, nil
	}
	currentScene := sceneResp.CurrentProgramSceneName
	status["scene"] = currentScene

	// Get recording state.
	recResp, err := o.client.Record.GetRecordStatus()
	if err == nil {
		status["recording"] = recResp.OutputActive
	}

	// Get sources count for current scene.
	if currentScene != "" {
		itemsResp, err := o.client.SceneItems.GetSceneItemList(
			sceneitems.NewGetSceneItemListParams().WithSceneName(currentScene),
		)
		if err == nil {
			status["sources_count"] = len(itemsResp.SceneItems)
		}
	}

	return status, nil
}
