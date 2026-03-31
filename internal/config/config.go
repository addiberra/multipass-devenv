package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

var (
	namePattern    = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$`)
	sizePattern    = regexp.MustCompile(`^[1-9][0-9]*[MG]$`)
	pinnedSSHHosts = map[string]struct{}{
		"github.com": {},
		"gitlab.com": {},
	}
)

const officialOpenCodeReleasePrefix = "https://github.com/anomalyco/opencode/releases/download/"

type Config struct {
	SchemaVersion string             `yaml:"schema_version"`
	Instance      InstanceConfig     `yaml:"instance"`
	Source        SourceConfig       `yaml:"source"`
	Base          BaseConfig         `yaml:"base"`
	Guest         GuestConfig        `yaml:"guest"`
	Provisioning  ProvisioningConfig `yaml:"provisioning"`
	Secrets       SecretsConfig      `yaml:"secrets"`
	Security      SecurityConfig     `yaml:"security"`
	OpenCode      OpenCodeConfig     `yaml:"opencode"`

	configDir string
}

type InstanceConfig struct {
	Name          string `yaml:"name"`
	UbuntuRelease string `yaml:"ubuntu_release"`
	CPUs          int    `yaml:"cpus"`
	Memory        string `yaml:"memory"`
	Disk          string `yaml:"disk"`
}

type SourceConfig struct {
	Repo   string `yaml:"repo"`
	Branch string `yaml:"branch"`
}

type BaseConfig struct {
	Enabled      bool   `yaml:"enabled"`
	InstanceName string `yaml:"instance_name"`
}

type GuestConfig struct {
	User         string `yaml:"user"`
	WorkspaceDir string `yaml:"workspace_dir"`
	RepoDir      string `yaml:"repo_dir"`
}

type ProvisioningConfig struct {
	CloudInit       string `yaml:"cloud_init"`
	BootstrapScript string `yaml:"bootstrap_script"`
}

type SecretsConfig struct {
	EnvFile string `yaml:"env_file"`
}

type SecurityConfig struct {
	DisableSSH           bool  `yaml:"disable_ssh"`
	MountWorkspace       bool  `yaml:"mount_workspace"`
	AllowedOutboundPorts []int `yaml:"allowed_outbound_ports"`
}

type OpenCodeConfig struct {
	ConfigTemplate string `yaml:"config_template"`
	ConfigPath     string `yaml:"config_path"`
	DownloadURL    string `yaml:"download_url"`
	SHA256         string `yaml:"sha256"`
}

type SourceRepo struct {
	Host    string
	UsesSSH bool
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
	if c.Source.Repo == "" {
		problems = append(problems, "source.repo is required")
	} else if _, err := ParseSourceRepo(c.Source.Repo); err != nil {
		problems = append(problems, fmt.Sprintf("source.repo %v", err))
	}
	if c.Base.Enabled && c.Base.InstanceName == "" {
		problems = append(problems, "base.instance_name is required when base.enabled is true")
	}
	if c.Base.InstanceName != "" && !namePattern.MatchString(c.Base.InstanceName) {
		problems = append(problems, "base.instance_name must be a valid Multipass instance name")
	}
	if c.Guest.User == "" {
		problems = append(problems, "guest.user is required")
	}
	if !strings.HasPrefix(c.Guest.WorkspaceDir, "/") {
		problems = append(problems, "guest.workspace_dir must be an absolute path")
	}
	if !strings.HasPrefix(c.Guest.RepoDir, "/") {
		problems = append(problems, "guest.repo_dir must be an absolute path")
	}
	if c.Guest.WorkspaceDir != "" && c.Guest.RepoDir != "" {
		rel, err := filepath.Rel(c.Guest.WorkspaceDir, c.Guest.RepoDir)
		if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
			problems = append(problems, "guest.repo_dir must be inside guest.workspace_dir")
		}
	}
	if c.Security.MountWorkspace {
		problems = append(problems, "security.mount_workspace must be false")
	}
	if len(c.Security.AllowedOutboundPorts) == 0 {
		problems = append(problems, "security.allowed_outbound_ports must not be empty")
	}
	seenPorts := map[int]struct{}{}
	for _, port := range c.Security.AllowedOutboundPorts {
		if port < 1 || port > 65535 {
			problems = append(problems, fmt.Sprintf("security.allowed_outbound_ports contains invalid port %d", port))
		}
		if _, ok := seenPorts[port]; ok {
			problems = append(problems, fmt.Sprintf("security.allowed_outbound_ports contains duplicate port %d", port))
		}
		seenPorts[port] = struct{}{}
	}
	if c.Provisioning.CloudInit == "" {
		problems = append(problems, "provisioning.cloud_init is required")
	}
	if c.Provisioning.BootstrapScript == "" {
		problems = append(problems, "provisioning.bootstrap_script is required")
	}
	if c.Secrets.EnvFile == "" {
		problems = append(problems, "secrets.env_file is required")
	}
	if c.OpenCode.DownloadURL == "" {
		problems = append(problems, "opencode.download_url is required")
	} else if err := validateOpenCodeDownloadURL(c.OpenCode.DownloadURL); err != nil {
		problems = append(problems, fmt.Sprintf("opencode.download_url %v", err))
	}
	if c.OpenCode.SHA256 == "" {
		problems = append(problems, "opencode.sha256 is required")
	}
	if (c.OpenCode.ConfigTemplate == "") != (c.OpenCode.ConfigPath == "") {
		problems = append(problems, "opencode.config_template and opencode.config_path must be set together")
	}
	if c.OpenCode.ConfigPath != "" && !strings.HasPrefix(c.OpenCode.ConfigPath, "/") {
		problems = append(problems, "opencode.config_path must be an absolute path")
	}

	paths := []struct {
		name  string
		value *string
	}{
		{name: "provisioning.cloud_init", value: &c.Provisioning.CloudInit},
		{name: "provisioning.bootstrap_script", value: &c.Provisioning.BootstrapScript},
		{name: "secrets.env_file", value: &c.Secrets.EnvFile},
	}
	if c.OpenCode.ConfigTemplate != "" {
		paths = append(paths, struct {
			name  string
			value *string
		}{name: "opencode.config_template", value: &c.OpenCode.ConfigTemplate})
	}
	for _, item := range paths {
		resolved := item.value
		*resolved = c.resolvePath(*resolved)
		info, err := os.Stat(*resolved)
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s does not exist: %s", item.name, *resolved))
			continue
		}
		if info.IsDir() {
			problems = append(problems, fmt.Sprintf("%s must be a file: %s", item.name, *resolved))
		}
	}

	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}

	if c.Instance.Name == "" {
		c.Instance.Name = autoName(c.Source.Repo)
	}
	return nil
}

func (c *Config) SourceRepo() (SourceRepo, error) {
	return ParseSourceRepo(c.Source.Repo)
}

func ParseSourceRepo(repo string) (SourceRepo, error) {
	if strings.HasPrefix(repo, "https://") {
		u, err := url.Parse(repo)
		if err != nil {
			return SourceRepo{}, fmt.Errorf("must be a valid HTTPS URL: %w", err)
		}
		if u.Host == "" || strings.TrimPrefix(u.Path, "/") == "" {
			return SourceRepo{}, fmt.Errorf("must include a host and repository path")
		}
		return SourceRepo{Host: strings.ToLower(u.Hostname())}, nil
	}

	if strings.HasPrefix(repo, "ssh://") {
		u, err := url.Parse(repo)
		if err != nil {
			return SourceRepo{}, fmt.Errorf("must be a valid SSH URL: %w", err)
		}
		if u.User == nil || u.User.Username() != "git" {
			return SourceRepo{}, fmt.Errorf("must use the git SSH user")
		}
		host := strings.ToLower(u.Hostname())
		if _, ok := pinnedSSHHosts[host]; !ok {
			return SourceRepo{}, fmt.Errorf("must use a supported SSH host with pinned keys (github.com or gitlab.com)")
		}
		if strings.TrimPrefix(u.Path, "/") == "" {
			return SourceRepo{}, fmt.Errorf("must include a repository path")
		}
		return SourceRepo{Host: host, UsesSSH: true}, nil
	}

	user, hostPath, ok := strings.Cut(repo, "@")
	if !ok {
		return SourceRepo{}, fmt.Errorf("must use https://, ssh://git@..., or git@host:path syntax")
	}
	if user != "git" {
		return SourceRepo{}, fmt.Errorf("must use the git SSH user")
	}
	host, repoPath, ok := strings.Cut(hostPath, ":")
	if !ok || strings.TrimSpace(host) == "" || strings.TrimSpace(repoPath) == "" {
		return SourceRepo{}, fmt.Errorf("must use git@host:path syntax for SSH repositories")
	}
	host = strings.ToLower(strings.TrimSpace(host))
	if _, supported := pinnedSSHHosts[host]; !supported {
		return SourceRepo{}, fmt.Errorf("must use a supported SSH host with pinned keys (github.com or gitlab.com)")
	}
	return SourceRepo{Host: host, UsesSSH: true}, nil
}

func validateOpenCodeDownloadURL(raw string) error {
	if !strings.HasPrefix(raw, officialOpenCodeReleasePrefix) {
		return fmt.Errorf("must use the official OpenCode GitHub release URL prefix %q", officialOpenCodeReleasePrefix)
	}
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("must be a valid HTTPS URL: %w", err)
	}
	if u.Scheme != "https" {
		return fmt.Errorf("must use https")
	}
	if strings.ToLower(u.Hostname()) != "github.com" {
		return fmt.Errorf("must use github.com")
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("must not include a query string or fragment")
	}
	return nil
}

func (c *Config) resolvePath(path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(c.configDir, path)
}

func autoName(repo string) string {
	base := repo
	if idx := strings.LastIndex(base, "/"); idx >= 0 {
		base = base[idx+1:]
	}
	base = strings.TrimSuffix(base, ".git")
	base = strings.ToLower(base)
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
	return fmt.Sprintf("%s-%s", name, time.Now().UTC().Format("20060102150405"))
}
