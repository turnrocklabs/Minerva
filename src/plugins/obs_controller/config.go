package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type Config struct {
	OBSHost         string `json:"obs_host"`
	OBSPort         int    `json:"obs_port"`
	OBSPassword     string `json:"obs_password"`
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
		case "obs_password":
			if s, ok := v.(string); ok {
				cfg.OBSPassword = s
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

// RedactedConfig returns the config as a map with the password replaced by "***" if set.
func RedactedConfig() map[string]any {
	cfgMu.RLock()
	c := cfg
	cfgMu.RUnlock()

	password := ""
	if c.OBSPassword != "" {
		password = "***"
	}

	return map[string]any{
		"obs_host":         c.OBSHost,
		"obs_port":         c.OBSPort,
		"obs_password":     password,
		"camera_source":    c.CameraSource,
		"output_directory": c.OutputDirectory,
		"auto_connect":     c.AutoConnect,
	}
}
