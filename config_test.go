package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadCraniumConfig_FullConfig(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "cranium.yaml")
	os.WriteFile(cfgPath, []byte(`
matrix:
  homeserver: https://matrix.example.com
  username: agent
  password_file: /etc/secrets/password
socket_path: /tmp/test.sock
identity_file: /etc/identity.yaml
ops_room: operations
exclude_rooms:
  - internal-
  - draft-
`), 0644)

	cfg, err := LoadCraniumConfig(cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.Matrix.Homeserver != "https://matrix.example.com" {
		t.Errorf("homeserver = %q, want https://matrix.example.com", cfg.Matrix.Homeserver)
	}
	if cfg.Matrix.Username != "agent" {
		t.Errorf("username = %q, want agent", cfg.Matrix.Username)
	}
	if cfg.Matrix.PasswordFile != "/etc/secrets/password" {
		t.Errorf("password_file = %q, want /etc/secrets/password", cfg.Matrix.PasswordFile)
	}
	if cfg.SocketPath != "/tmp/test.sock" {
		t.Errorf("socket_path = %q, want /tmp/test.sock", cfg.SocketPath)
	}
	if cfg.IdentityFile != "/etc/identity.yaml" {
		t.Errorf("identity_file = %q, want /etc/identity.yaml", cfg.IdentityFile)
	}
	if cfg.OpsRoom != "operations" {
		t.Errorf("ops_room = %q, want operations", cfg.OpsRoom)
	}
	if len(cfg.ExcludeRooms) != 2 || cfg.ExcludeRooms[0] != "internal-" || cfg.ExcludeRooms[1] != "draft-" {
		t.Errorf("exclude_rooms = %v, want [internal- draft-]", cfg.ExcludeRooms)
	}
}

func TestLoadCraniumConfig_Defaults(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "cranium.yaml")
	os.WriteFile(cfgPath, []byte(`
matrix:
  homeserver: https://matrix.example.com
  username: agent
  password_file: /etc/secrets/password
identity_file: /etc/identity.yaml
`), 0644)

	cfg, err := LoadCraniumConfig(cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.SocketPath != "/tmp/cranium.sock" {
		t.Errorf("default socket_path = %q, want /tmp/cranium.sock", cfg.SocketPath)
	}
	if cfg.OpsRoom != "ops" {
		t.Errorf("default ops_room = %q, want ops", cfg.OpsRoom)
	}
	if len(cfg.ExcludeRooms) != 1 || cfg.ExcludeRooms[0] != "project-" {
		t.Errorf("default exclude_rooms = %v, want [project-]", cfg.ExcludeRooms)
	}
}

func TestLoadCraniumConfig_MissingRequired(t *testing.T) {
	tests := []struct {
		name    string
		yaml    string
		wantErr string
	}{
		{
			"missing homeserver",
			`matrix:
  username: agent
  password_file: /p
identity_file: /i`,
			"homeserver is required",
		},
		{
			"missing username",
			`matrix:
  homeserver: https://m.example.com
  password_file: /p
identity_file: /i`,
			"username is required",
		},
		{
			"missing password_file",
			`matrix:
  homeserver: https://m.example.com
  username: agent
identity_file: /i`,
			"password_file is required",
		},
		{
			"missing identity_file",
			`matrix:
  homeserver: https://m.example.com
  username: agent
  password_file: /p`,
			"identity_file is required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tmp := t.TempDir()
			cfgPath := filepath.Join(tmp, "cranium.yaml")
			os.WriteFile(cfgPath, []byte(tt.yaml), 0644)

			_, err := LoadCraniumConfig(cfgPath)
			if err == nil {
				t.Fatal("expected error, got nil")
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("error = %q, want it to contain %q", err.Error(), tt.wantErr)
			}
		})
	}
}

func TestLoadCraniumConfig_FileNotFound(t *testing.T) {
	_, err := LoadCraniumConfig("/nonexistent/path.yaml")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestLoadIdentityConfig_FullConfig(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "identity.yaml")
	os.WriteFile(cfgPath, []byte(`
system_prompt_file: /data/EXO.md
data_dir: /data/exocortex
display_name: Exo
attachments_dir: /data/exocortex/notes/attachments
projects_dir: /home/dev/Projects
summary_turn_threshold: 15
`), 0644)

	cfg, err := LoadIdentityConfig(cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.SystemPromptFile != "/data/EXO.md" {
		t.Errorf("system_prompt_file = %q, want /data/EXO.md", cfg.SystemPromptFile)
	}
	if cfg.DataDir != "/data/exocortex" {
		t.Errorf("data_dir = %q, want /data/exocortex", cfg.DataDir)
	}
	if cfg.DisplayName != "Exo" {
		t.Errorf("display_name = %q, want Exo", cfg.DisplayName)
	}
	if cfg.AttachmentsDir != "/data/exocortex/notes/attachments" {
		t.Errorf("attachments_dir = %q, want /data/exocortex/notes/attachments", cfg.AttachmentsDir)
	}
	if cfg.ProjectsDir != "/home/dev/Projects" {
		t.Errorf("projects_dir = %q, want /home/dev/Projects", cfg.ProjectsDir)
	}
	if cfg.SummaryTurnThreshold != 15 {
		t.Errorf("summary_turn_threshold = %d, want 15", cfg.SummaryTurnThreshold)
	}
}

func TestLoadIdentityConfig_Defaults(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "identity.yaml")
	os.WriteFile(cfgPath, []byte(`
system_prompt_file: /data/EXO.md
data_dir: /data/exocortex
`), 0644)

	cfg, err := LoadIdentityConfig(cfgPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.DisplayName != "Agent" {
		t.Errorf("default display_name = %q, want Agent", cfg.DisplayName)
	}
	if cfg.SummaryTurnThreshold != 10 {
		t.Errorf("default summary_turn_threshold = %d, want 10", cfg.SummaryTurnThreshold)
	}
}

func TestLoadIdentityConfig_MissingRequired(t *testing.T) {
	tests := []struct {
		name    string
		yaml    string
		wantErr string
	}{
		{
			"missing system_prompt_file",
			`data_dir: /data`,
			"system_prompt_file is required",
		},
		{
			"missing data_dir",
			`system_prompt_file: /data/EXO.md`,
			"data_dir is required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tmp := t.TempDir()
			cfgPath := filepath.Join(tmp, "identity.yaml")
			os.WriteFile(cfgPath, []byte(tt.yaml), 0644)

			_, err := LoadIdentityConfig(cfgPath)
			if err == nil {
				t.Fatal("expected error, got nil")
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("error = %q, want it to contain %q", err.Error(), tt.wantErr)
			}
		})
	}
}

func TestLoadIdentityConfig_FileNotFound(t *testing.T) {
	_, err := LoadIdentityConfig("/nonexistent/path.yaml")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestLoadCraniumConfig_InvalidYAML(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "cranium.yaml")
	os.WriteFile(cfgPath, []byte(`not: valid: yaml: [[[`), 0644)

	_, err := LoadCraniumConfig(cfgPath)
	if err == nil {
		t.Fatal("expected error for invalid YAML")
	}
}

func TestLoadIdentityConfig_InvalidYAML(t *testing.T) {
	tmp := t.TempDir()
	cfgPath := filepath.Join(tmp, "identity.yaml")
	os.WriteFile(cfgPath, []byte(`not: valid: yaml: [[[`), 0644)

	_, err := LoadIdentityConfig(cfgPath)
	if err == nil {
		t.Fatal("expected error for invalid YAML")
	}
}
