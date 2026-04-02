package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

var (
	namePattern    = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$`)
	releasePattern = regexp.MustCompile(`^[0-9]{2}\.[0-9]{2}$`)
	sizePattern    = regexp.MustCompile(`^[1-9][0-9]*[MG]$`)
)

type Config struct {
	SchemaVersion string         `yaml:"schema_version"`
	CloudInit     string         `yaml:"cloud_init"`
	Mount         *MountConfig   `yaml:"mount,omitempty"`
	Instance      InstanceConfig `yaml:"instance"`

	configDir string
}

type MountConfig struct {
	HostPath   string `yaml:"host_path"`
	GuestPath  string `yaml:"guest_path"`
	Privileged bool   `yaml:"privileged"`
}

type InstanceConfig struct {
	Name          string `yaml:"name"`
	UbuntuRelease string `yaml:"ubuntu_release"`
	CPUs          int    `yaml:"cpus"`
	Memory        string `yaml:"memory"`
	Disk          string `yaml:"disk"`
}

func Load(path string) (*Config, error) {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("resolve config path: %w", err)
	}

	data, err := os.ReadFile(absPath)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	cfg.configDir = filepath.Dir(absPath)

	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) Validate() error {
	var problems []string

	if c.SchemaVersion != "1.0" {
		problems = append(problems, "schema_version must be 1.0")
	}
	if c.Instance.UbuntuRelease == "" {
		problems = append(problems, "instance.ubuntu_release is required")
	} else if !releasePattern.MatchString(c.Instance.UbuntuRelease) {
		problems = append(problems, "instance.ubuntu_release must match ^[0-9]{2}\\.[0-9]{2}$")
	}
	if c.Instance.CPUs < 1 {
		problems = append(problems, "instance.cpus must be >= 1")
	}
	if !sizePattern.MatchString(c.Instance.Memory) {
		problems = append(problems, "instance.memory must match ^[1-9][0-9]*[MG]$")
	}
	if !sizePattern.MatchString(c.Instance.Disk) {
		problems = append(problems, "instance.disk must match ^[1-9][0-9]*[MG]$")
	}
	if c.Instance.Name != "" && !namePattern.MatchString(c.Instance.Name) {
		problems = append(problems, "instance.name must be a valid Multipass instance name")
	}
	if c.CloudInit == "" {
		problems = append(problems, "cloud_init is required")
	} else {
		c.CloudInit = c.resolvePath(c.CloudInit)
		info, err := os.Stat(c.CloudInit)
		if err != nil {
			problems = append(problems, fmt.Sprintf("cloud_init does not exist: %s", c.CloudInit))
		} else if info.IsDir() {
			problems = append(problems, fmt.Sprintf("cloud_init must be a file: %s", c.CloudInit))
		}
	}
	if c.Mount != nil {
		if c.Mount.HostPath == "" {
			problems = append(problems, "mount.host_path is required")
		} else {
			hostPath, err := c.resolveHostPath(c.Mount.HostPath)
			if err != nil {
				problems = append(problems, fmt.Sprintf("mount.host_path is invalid: %v", err))
			} else {
				c.Mount.HostPath = hostPath
				info, err := os.Stat(c.Mount.HostPath)
				if err != nil {
					problems = append(problems, fmt.Sprintf("mount.host_path does not exist: %s", c.Mount.HostPath))
				} else if !info.IsDir() {
					problems = append(problems, fmt.Sprintf("mount.host_path must be a directory: %s", c.Mount.HostPath))
				}
			}
		}
		if c.Mount.GuestPath == "" {
			problems = append(problems, "mount.guest_path is required")
		} else if !filepath.IsAbs(c.Mount.GuestPath) {
			problems = append(problems, "mount.guest_path must be an absolute path")
		}
	}

	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}

	if c.Instance.Name == "" {
		c.Instance.Name = autoName(c.configDir)
	}

	return nil
}

func (c *Config) resolvePath(path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(c.configDir, path)
}

func (c *Config) resolveHostPath(path string) (string, error) {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve home directory: %w", err)
		}
		if path == "~" {
			return home, nil
		}
		path = filepath.Join(home, strings.TrimPrefix(path, "~/"))
	}

	if filepath.IsAbs(path) {
		return path, nil
	}
	return filepath.Join(c.configDir, path), nil
}

func autoName(dir string) string {
	base := strings.ToLower(filepath.Base(dir))
	var b strings.Builder
	lastDash := false
	for _, r := range base {
		keep := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if keep {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteRune('-')
			lastDash = true
		}
	}
	name := strings.Trim(b.String(), "-")
	if name == "" {
		name = "devvm"
	}
	return name + "-devvm"
}
