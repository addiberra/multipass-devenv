package multipass

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/addiberra/multipass-devenv/internal/config"
)

type Runner struct{}

func NewRunner() *Runner {
	return &Runner{}
}

func (r *Runner) Launch(ctx context.Context, cfg *config.Config, cloudInitPath string) error {
	args := []string{
		"launch", cfg.Instance.UbuntuRelease,
		"--name", cfg.Instance.Name,
		"--cpus", strconv.Itoa(cfg.Instance.CPUs),
		"--memory", cfg.Instance.Memory,
		"--disk", cfg.Instance.Disk,
		"--cloud-init", cloudInitPath,
	}
	return r.run(ctx, args...)
}

func (r *Runner) WaitCloudInit(ctx context.Context, instance string) error {
	return r.run(ctx, "exec", instance, "--", "cloud-init", "status", "--wait")
}

func (r *Runner) SetPrivilegedMounts(ctx context.Context, enabled bool) error {
	return r.run(ctx, "set", fmt.Sprintf("local.privileged-mounts=%t", enabled))
}

func (r *Runner) Mount(ctx context.Context, hostPath, instance, guestPath string) error {
	return r.run(ctx, "mount", hostPath, fmt.Sprintf("%s:%s", instance, guestPath))
}

func (r *Runner) run(ctx context.Context, args ...string) error {
	cmd := exec.CommandContext(ctx, "multipass", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	cmd.Stdout = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			return fmt.Errorf("multipass %s: %w", strings.Join(args, " "), err)
		}
		return fmt.Errorf("multipass %s: %s", strings.Join(args, " "), msg)
	}
	return nil
}
