package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// Config holds non-secret OBS settings persisted to disk.
// The OBS WebSocket password is intentionally NOT here — it lives in
// Minerva's docket vault and is supplied by the panel via the connect tool.
type Config struct {
	OBSHost         string `json:"obs_host"`
	OBSPort         int    `json:"obs_port"`
	CameraSource    string `json:"camera_source"`
	OutputDirectory string `json:"output_directory"`
	AutoConnect     bool   `json:"auto_connect"`
}

var (
	cfg     Config
	cfgMu   sync.RWMutex
	cfgPath string
)

func DefaultConfig() Config {
	return Config{
		OBSHost:     "localhost",
		OBSPort:     4455,
		AutoConnect: true,
	}
}

// LoadConfig loads config from dataDir/config.json, falling back to defaults if the file
// doesn't exist. Sets cfgPath for future saves.
func LoadConfig(dataDir string) error {
	cfgMu.Lock()
	defer cfgMu.Unlock()

	cfgPath = filepath.Join(dataDir, "config.json")
	cfg = DefaultConfig()

	data, err := os.ReadFile(cfgPath)
	if err != nil {
		if os.IsNotExist(err) {
			// No config file yet — defaults are fine.
			return nil
		}
		return fmt.Errorf("reading config %s: %w", cfgPath, err)
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return fmt.Errorf("parsing config %s: %w", cfgPath, err)
	}

	return nil
}

// SaveConfig writes cfg to cfgPath.
func SaveConfig() error {
	cfgMu.RLock()
	path := cfgPath
	data, err := json.MarshalIndent(cfg, "", "  ")
	cfgMu.RUnlock()

	if err != nil {
		return fmt.Errorf("marshalling config: %w", err)
	}

	if path == "" {
		return fmt.Errorf("config path not set; call LoadConfig first")
	}

	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("writing config %s: %w", path, err)
	}

	return nil
}

// GetConfig returns a copy of the current config under a read lock.
func GetConfig() Config {
	cfgMu.RLock()
	defer cfgMu.RUnlock()
	return cfg
}

// UpdateConfig merges the provided key/value map into cfg and saves.
// Recognised keys mirror the Config JSON field names.
func UpdateConfig(updates map[string]any) error {
	cfgMu.Lock()

	for k, v := range updates {
		switch k {
		case "obs_host":
			if s, ok := v.(string); ok {
				cfg.OBSHost = s
			}
		case "obs_port":
			switch n := v.(type) {
			case int:
				cfg.OBSPort = n
			case float64:
				cfg.OBSPort = int(n)
			}
		case "camera_source":
			if s, ok := v.(string); ok {
				cfg.CameraSource = s
			}
		case "output_directory":
			if s, ok := v.(string); ok {
				cfg.OutputDirectory = s
			}
		case "auto_connect":
			if b, ok := v.(bool); ok {
				cfg.AutoConnect = b
			}
		}
	}

	cfgMu.Unlock()

	return SaveConfig()
}

// PublicConfig returns the on-disk config as a map. The OBS password is not
// stored on disk — it lives in the docket vault and is fetched separately by
// the panel via the secrets capability.
func PublicConfig() map[string]any {
	cfgMu.RLock()
	c := cfg
	cfgMu.RUnlock()

	return map[string]any{
		"obs_host":         c.OBSHost,
		"obs_port":         c.OBSPort,
		"camera_source":    c.CameraSource,
		"output_directory": c.OutputDirectory,
		"auto_connect":     c.AutoConnect,
	}
}
