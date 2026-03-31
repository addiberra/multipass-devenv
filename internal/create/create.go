package create

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/addiberra/multipass-devenv/internal/config"
	"github.com/addiberra/multipass-devenv/internal/multipass"
	"github.com/addiberra/multipass-devenv/internal/provisioning"
)

func Run(configPath string, stdout, stderr io.Writer) error {
	_ = stderr
	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}

	stage, err := provisioning.Prepare(cfg)
	if err != nil {
		return err
	}
	defer provisioning.Cleanup(stage)

	ctx := context.Background()
	mp := multipass.NewRunner()

	usedBase := false
	if cfg.Base.Enabled && mp.Exists(ctx, cfg.Base.InstanceName) {
		fmt.Fprintf(stdout, "Using base instance %s\n", cfg.Base.InstanceName)
		if err := mp.Clone(ctx, cfg.Base.InstanceName, cfg.Instance.Name); err != nil {
			return err
		}
		usedBase = true
	} else {
		if cfg.Base.Enabled {
			fmt.Fprintf(stdout, "Base instance %s not available, falling back to fresh launch\n", cfg.Base.InstanceName)
		}
		if err := mp.Launch(ctx, cfg); err != nil {
			return err
		}
	}

	if err := mp.WaitReady(ctx, cfg.Instance.Name, 2*time.Minute); err != nil {
		return err
	}

	if err := mp.Exec(ctx, cfg.Instance.Name, "bash", "-lc", fmt.Sprintf("mkdir -p %q", strings.TrimPrefix(stage.RemoteDir, cfg.Instance.Name+":"))); err != nil {
		return err
	}
	if err := mp.Transfer(ctx, stage.BootstrapLocalPath, stage.RemoteBootstrap); err != nil {
		return err
	}
	if err := mp.Transfer(ctx, stage.SecretsLocalPath, stage.RemoteSecrets); err != nil {
		return err
	}
	if err := mp.Transfer(ctx, stage.EnvLocalPath, stage.RemoteEnv); err != nil {
		return err
	}
	if stage.OpenCodeLocalPath != "" {
		if err := mp.Transfer(ctx, stage.OpenCodeLocalPath, stage.RemoteOpenCode); err != nil {
			return err
		}
	}
	if stage.KnownHostsLocalPath != "" {
		if err := mp.Transfer(ctx, stage.KnownHostsLocalPath, stage.RemoteKnownHosts); err != nil {
			return err
		}
	}

	bootstrapEnv := strings.TrimPrefix(stage.RemoteDir, cfg.Instance.Name+":")
	if err := mp.Exec(ctx, cfg.Instance.Name, "sudo", "bash", "-lc", fmt.Sprintf(
		"set -euo pipefail; export DEVVM_REMOTE_DIR=%q; source %q; bash %q",
		bootstrapEnv,
		strings.TrimPrefix(stage.RemoteEnv, cfg.Instance.Name+":"),
		strings.TrimPrefix(stage.RemoteBootstrap, cfg.Instance.Name+":"),
	)); err != nil {
		return fmt.Errorf("bootstrap guest %s: %w", cfg.Instance.Name, err)
	}

	if usedBase {
		fmt.Fprintf(stdout, "Created VM %s from base instance\n", cfg.Instance.Name)
	} else {
		fmt.Fprintf(stdout, "Created VM %s from Ubuntu %s\n", cfg.Instance.Name, cfg.Instance.UbuntuRelease)
	}
	fmt.Fprintf(stdout, "Enter with: multipass shell %s\n", cfg.Instance.Name)
	fmt.Fprintf(stdout, "Repository path: %s\n", cfg.Guest.RepoDir)
	return nil
}
