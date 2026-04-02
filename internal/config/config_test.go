package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadResolvesCloudInitAndDerivesName(t *testing.T) {
	tempDir := t.TempDir()
	cloudInitPath := filepath.Join(tempDir, "opencode-sandbox.yaml")
	if err := os.WriteFile(cloudInitPath, []byte("#cloud-config\n"), 0o600); err != nil {
		t.Fatalf("write cloud-init: %v", err)
	}
	configPath := filepath.Join(tempDir, "devvm.yaml")
	configYAML := []byte("schema_version: \"1.0\"\ncloud_init: \"./opencode-sandbox.yaml\"\ninstance:\n  ubuntu_release: \"24.04\"\n  cpus: 2\n  memory: \"4G\"\n  disk: \"30G\"\n")
	if err := os.WriteFile(configPath, configYAML, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := Load(configPath)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.CloudInit != cloudInitPath {
		t.Fatalf("CloudInit = %q, want %q", cfg.CloudInit, cloudInitPath)
	}
	if cfg.Instance.Name != filepath.Base(tempDir)+"-devvm" {
		t.Fatalf("Instance.Name = %q, want %q", cfg.Instance.Name, filepath.Base(tempDir)+"-devvm")
	}
}

func TestLoadRejectsInvalidConfig(t *testing.T) {
	tempDir := t.TempDir()
	configPath := filepath.Join(tempDir, "devvm.yaml")
	configYAML := []byte("schema_version: \"1.0\"\ncloud_init: \"./missing.yaml\"\ninstance:\n  ubuntu_release: \"latest\"\n  cpus: 0\n  memory: \"4G\"\n  disk: \"30G\"\n")
	if err := os.WriteFile(configPath, configYAML, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	if _, err := Load(configPath); err == nil {
		t.Fatal("Load() error = nil, want validation error")
	}
}

func TestLoadResolvesMountPathAndPrivilegedSetting(t *testing.T) {
	tempDir := t.TempDir()
	hostRepo := filepath.Join(tempDir, "repo")
	if err := os.Mkdir(hostRepo, 0o755); err != nil {
		t.Fatalf("mkdir repo: %v", err)
	}
	cloudInitPath := filepath.Join(tempDir, "opencode-sandbox.yaml")
	if err := os.WriteFile(cloudInitPath, []byte("#cloud-config\n"), 0o600); err != nil {
		t.Fatalf("write cloud-init: %v", err)
	}
	configPath := filepath.Join(tempDir, "devvm.yaml")
	configYAML := []byte("schema_version: \"1.0\"\ncloud_init: \"./opencode-sandbox.yaml\"\nmount:\n  host_path: \"./repo\"\n  guest_path: \"/home/agent/workspace/my-repo\"\n  privileged: true\ninstance:\n  ubuntu_release: \"24.04\"\n  cpus: 2\n  memory: \"4G\"\n  disk: \"30G\"\n")
	if err := os.WriteFile(configPath, configYAML, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := Load(configPath)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Mount == nil {
		t.Fatal("Mount = nil, want populated mount config")
	}
	if cfg.Mount.HostPath != hostRepo {
		t.Fatalf("Mount.HostPath = %q, want %q", cfg.Mount.HostPath, hostRepo)
	}
	if !cfg.Mount.Privileged {
		t.Fatal("Mount.Privileged = false, want true")
	}
}

func TestLoadRejectsRelativeGuestMountPath(t *testing.T) {
	tempDir := t.TempDir()
	hostRepo := filepath.Join(tempDir, "repo")
	if err := os.Mkdir(hostRepo, 0o755); err != nil {
		t.Fatalf("mkdir repo: %v", err)
	}
	cloudInitPath := filepath.Join(tempDir, "opencode-sandbox.yaml")
	if err := os.WriteFile(cloudInitPath, []byte("#cloud-config\n"), 0o600); err != nil {
		t.Fatalf("write cloud-init: %v", err)
	}
	configPath := filepath.Join(tempDir, "devvm.yaml")
	configYAML := []byte("schema_version: \"1.0\"\ncloud_init: \"./opencode-sandbox.yaml\"\nmount:\n  host_path: \"./repo\"\n  guest_path: \"workspace/my-repo\"\n  privileged: false\ninstance:\n  ubuntu_release: \"24.04\"\n  cpus: 2\n  memory: \"4G\"\n  disk: \"30G\"\n")
	if err := os.WriteFile(configPath, configYAML, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	if _, err := Load(configPath); err == nil {
		t.Fatal("Load() error = nil, want validation error")
	}
}
