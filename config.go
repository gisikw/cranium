package main

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// CraniumConfig holds infrastructure configuration for the dispatcher.
// Lives in cranium.yaml (in-repo, .gitignored).
type CraniumConfig struct {
	Matrix struct {
		Homeserver   string `yaml:"homeserver"`
		Username     string `yaml:"username"`
		PasswordFile string `yaml:"password_file"`
	} `yaml:"matrix"`
	SocketPath   string   `yaml:"socket_path"`
	IdentityFile string   `yaml:"identity_file"`
	OpsRoom      string   `yaml:"ops_room"`
	ExcludeRooms []string `yaml:"exclude_rooms"`
}

// IdentityConfig holds personality/identity configuration.
// Lives outside the cranium repo (e.g. in the "brain" repo).
type IdentityConfig struct {
	SystemPromptFile     string `yaml:"system_prompt_file"`
	DataDir              string `yaml:"data_dir"`
	DisplayName          string `yaml:"display_name"`
	AttachmentsDir       string `yaml:"attachments_dir"`
	ProjectsDir          string `yaml:"projects_dir"`
	SummaryTurnThreshold int    `yaml:"summary_turn_threshold"`
}

// LoadCraniumConfig reads and parses a cranium.yaml file, applying defaults.
func LoadCraniumConfig(path string) (*CraniumConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read cranium config: %w", err)
	}

	var cfg CraniumConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse cranium config: %w", err)
	}

	// Apply defaults
	if cfg.SocketPath == "" {
		cfg.SocketPath = "/tmp/cranium.sock"
	}
	if cfg.OpsRoom == "" {
		cfg.OpsRoom = "ops"
	}
	if cfg.ExcludeRooms == nil {
		cfg.ExcludeRooms = []string{"project-"}
	}

	// Validate required fields
	if cfg.Matrix.Homeserver == "" {
		return nil, fmt.Errorf("cranium config: matrix.homeserver is required")
	}
	if cfg.Matrix.Username == "" {
		return nil, fmt.Errorf("cranium config: matrix.username is required")
	}
	if cfg.Matrix.PasswordFile == "" {
		return nil, fmt.Errorf("cranium config: matrix.password_file is required")
	}
	if cfg.IdentityFile == "" {
		return nil, fmt.Errorf("cranium config: identity_file is required")
	}

	return &cfg, nil
}

// LoadIdentityConfig reads and parses an identity.yaml file, applying defaults.
func LoadIdentityConfig(path string) (*IdentityConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read identity config: %w", err)
	}

	var cfg IdentityConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse identity config: %w", err)
	}

	// Apply defaults
	if cfg.DisplayName == "" {
		cfg.DisplayName = "Agent"
	}
	if cfg.SummaryTurnThreshold == 0 {
		cfg.SummaryTurnThreshold = 10
	}

	// Validate required fields
	if cfg.SystemPromptFile == "" {
		return nil, fmt.Errorf("identity config: system_prompt_file is required")
	}
	if cfg.DataDir == "" {
		return nil, fmt.Errorf("identity config: data_dir is required")
	}

	return &cfg, nil
}
