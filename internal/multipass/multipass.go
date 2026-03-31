package multipass

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/addiberra/multipass-devenv/internal/config"
)

type Runner struct{}

func NewRunner() *Runner {
	return &Runner{}
}

func (r *Runner) Exists(ctx context.Context, instance string) bool {
	cmd := exec.CommandContext(ctx, "multipass", "info", instance)
	return cmd.Run() == nil
}

func (r *Runner) Clone(ctx context.Context, source, dest string) error {
	return r.run(ctx, "clone", source, "--name", dest)
}

func (r *Runner) Launch(ctx context.Context, cfg *config.Config) error {
	args := []string{
		"launch", cfg.Instance.UbuntuRelease,
		"--name", cfg.Instance.Name,
		"--cpus", strconv.Itoa(cfg.Instance.CPUs),
		"--memory", cfg.Instance.Memory,
		"--disk", cfg.Instance.Disk,
		"--cloud-init", cfg.Provisioning.CloudInit,
	}
	return r.run(ctx, args...)
}

func (r *Runner) WaitReady(ctx context.Context, instance string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := r.run(context.Background(), "exec", instance, "--", "true"); err == nil {
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("instance %s did not become ready within %s", instance, timeout)
}

func (r *Runner) Exec(ctx context.Context, instance string, args ...string) error {
	full := append([]string{"exec", instance, "--"}, args...)
	return r.run(ctx, full...)
}

func (r *Runner) Transfer(ctx context.Context, localPath, remotePath string) error {
	return r.run(ctx, "transfer", localPath, remotePath)
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
