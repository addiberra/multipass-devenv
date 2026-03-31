package provisioning

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"text/template"

	"github.com/addiberra/multipass-devenv-worktrees/feature-secure-dev-env-setup/internal/config"
)

type StagedFiles struct {
	TempDir            string
	BootstrapLocalPath string
	SecretsLocalPath   string
	EnvLocalPath       string
	OpenCodeLocalPath  string
	RemoteDir          string

	RemoteBootstrap string
	RemoteSecrets   string
	RemoteEnv       string
	RemoteOpenCode  string
}

func Prepare(cfg *config.Config) (*StagedFiles, error) {
	tempDir, err := os.MkdirTemp("", "devvm-stage-")
	if err != nil {
		return nil, fmt.Errorf("create temp dir: %w", err)
	}

	stage := &StagedFiles{
		TempDir:            tempDir,
		BootstrapLocalPath: filepath.Join(tempDir, "bootstrap-guest.sh"),
		SecretsLocalPath:   filepath.Join(tempDir, "secrets.env"),
		EnvLocalPath:       filepath.Join(tempDir, "bootstrap.env"),
		RemoteDir:          fmt.Sprintf("%s:/tmp/devvm-%s", cfg.Instance.Name, cfg.Instance.Name),
	}
	stage.RemoteBootstrap = stage.RemoteDir + "/bootstrap-guest.sh"
	stage.RemoteSecrets = stage.RemoteDir + "/secrets.env"
	stage.RemoteEnv = stage.RemoteDir + "/bootstrap.env"

	if err := copyFile(cfg.Provisioning.BootstrapScript, stage.BootstrapLocalPath, 0o755); err != nil {
		return nil, err
	}
	if err := copyFile(cfg.Secrets.EnvFile, stage.SecretsLocalPath, 0o600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(stage.EnvLocalPath, []byte(buildBootstrapEnv(cfg, "")), 0o600); err != nil {
		return nil, fmt.Errorf("write bootstrap env: %w", err)
	}

	if cfg.OpenCode.ConfigTemplate != "" {
		stage.OpenCodeLocalPath = filepath.Join(tempDir, "opencode-config.yaml")
		stage.RemoteOpenCode = stage.RemoteDir + "/opencode-config.yaml"
		if err := os.WriteFile(stage.EnvLocalPath, []byte(buildBootstrapEnv(cfg, stage.RemoteOpenCode)), 0o600); err != nil {
			return nil, fmt.Errorf("rewrite bootstrap env: %w", err)
		}
		content, err := renderOpenCodeConfig(cfg)
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(stage.OpenCodeLocalPath, []byte(content), 0o600); err != nil {
			return nil, fmt.Errorf("write rendered OpenCode config: %w", err)
		}
	}

	if stage.RemoteOpenCode == "" {
		if err := os.WriteFile(stage.EnvLocalPath, []byte(buildBootstrapEnv(cfg, "")), 0o600); err != nil {
			return nil, fmt.Errorf("finalize bootstrap env: %w", err)
		}
	}

	return stage, nil
}

func Cleanup(stage *StagedFiles) {
	if stage != nil && stage.TempDir != "" {
		_ = os.RemoveAll(stage.TempDir)
	}
}

func copyFile(src, dst string, mode os.FileMode) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("read %s: %w", src, err)
	}
	if err := os.WriteFile(dst, data, mode); err != nil {
		return fmt.Errorf("write %s: %w", dst, err)
	}
	return nil
}

func buildBootstrapEnv(cfg *config.Config, remoteOpenCodePath string) string {
	lines := []string{
		fmt.Sprintf("DEVVM_GUEST_USER=%s", shellQuote(cfg.Guest.User)),
		fmt.Sprintf("DEVVM_WORKSPACE_DIR=%s", shellQuote(cfg.Guest.WorkspaceDir)),
		fmt.Sprintf("DEVVM_REPO_DIR=%s", shellQuote(cfg.Guest.RepoDir)),
		fmt.Sprintf("DEVVM_SOURCE_REPO=%s", shellQuote(cfg.Source.Repo)),
		fmt.Sprintf("DEVVM_SOURCE_BRANCH=%s", shellQuote(cfg.Source.Branch)),
		fmt.Sprintf("DEVVM_DISABLE_SSH=%s", shellQuote(boolString(cfg.Security.DisableSSH))),
		fmt.Sprintf("DEVVM_ALLOWED_OUTBOUND_PORTS=%s", shellQuote(joinPorts(cfg.Security.AllowedOutboundPorts))),
		fmt.Sprintf("DEVVM_OPENCODE_DOWNLOAD_URL=%s", shellQuote(cfg.OpenCode.DownloadURL)),
		fmt.Sprintf("DEVVM_OPENCODE_SHA256=%s", shellQuote(cfg.OpenCode.SHA256)),
	}
	if cfg.OpenCode.ConfigPath != "" {
		lines = append(lines,
			fmt.Sprintf("DEVVM_OPENCODE_CONFIG_PATH=%s", shellQuote(cfg.OpenCode.ConfigPath)),
			fmt.Sprintf("DEVVM_OPENCODE_CONFIG_STAGED=%s", shellQuote(strings.TrimPrefix(remoteOpenCodePath, cfg.Instance.Name+":"))),
		)
	}
	return strings.Join(lines, "\n") + "\n"
}

func renderOpenCodeConfig(cfg *config.Config) (string, error) {
	secrets, err := parseEnvFile(cfg.Secrets.EnvFile)
	if err != nil {
		return "", err
	}
	tplData, err := os.ReadFile(cfg.OpenCode.ConfigTemplate)
	if err != nil {
		return "", fmt.Errorf("read OpenCode template: %w", err)
	}
	tpl, err := template.New(filepath.Base(cfg.OpenCode.ConfigTemplate)).Option("missingkey=error").Parse(string(tplData))
	if err != nil {
		return "", fmt.Errorf("parse OpenCode template: %w", err)
	}
	var out bytes.Buffer
	if err := tpl.Execute(&out, map[string]string{
		"OPENAI_API_KEY":   secrets["OPENAI_API_KEY"],
		"OPENCODE_API_KEY": secrets["OPENCODE_API_KEY"],
		"GIT_USER_NAME":    secrets["GIT_USER_NAME"],
		"GIT_USER_EMAIL":   secrets["GIT_USER_EMAIL"],
	}); err != nil {
		return "", fmt.Errorf("render OpenCode template: %w", err)
	}
	return out.String(), nil
}

func parseEnvFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read secrets env file: %w", err)
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("invalid env line in %s: %q", path, line)
		}
		values[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	for _, required := range []string{"OPENAI_API_KEY", "GIT_USER_NAME", "GIT_USER_EMAIL"} {
		if values[required] == "" {
			return nil, fmt.Errorf("missing required key %s in %s", required, path)
		}
	}
	return values, nil
}

func joinPorts(ports []int) string {
	parts := make([]string, 0, len(ports))
	for _, port := range ports {
		parts = append(parts, fmt.Sprintf("%d", port))
	}
	return strings.Join(parts, ",")
}

func boolString(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

func shellQuote(value string) string {
	trimmed := strings.ReplaceAll(value, "\n", "")
	return "'" + strings.ReplaceAll(trimmed, "'", "'\"'\"'") + "'"
}
