package create

import (
	"context"
	"fmt"
	"io"

	"github.com/addiberra/multipass-devenv/internal/config"
	"github.com/addiberra/multipass-devenv/internal/multipass"
)

func Run(configPath string, stdout, stderr io.Writer) error {
	_ = stderr

	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}

	ctx := context.Background()
	mp := multipass.NewRunner()

	if err := mp.Launch(ctx, cfg, cfg.CloudInit); err != nil {
		return err
	}
	if err := mp.WaitCloudInit(ctx, cfg.Instance.Name); err != nil {
		return err
	}

	fmt.Fprintf(stdout, "Created VM %s from Ubuntu %s\n", cfg.Instance.Name, cfg.Instance.UbuntuRelease)
	fmt.Fprintf(stdout, "Cloud-init: %s\n", cfg.CloudInit)
	fmt.Fprintf(stdout, "Enter with: multipass shell %s\n", cfg.Instance.Name)
	return nil
}
