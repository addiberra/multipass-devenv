# Secure Multipass Dev Environment

This repo provides a small Go CLI plus reusable OpenCode-focused Multipass
templates for agent workflows.

It also includes a repo-specific self-hosting setup so you can work on this
repository inside a Multipass VM.

## Artifact Roles

- Root `devvm.yaml` plus `opencode-sandbox.repo.yaml`: this repository's own dev VM setup
- `templates/devvm.template.yaml` plus `templates/opencode-sandbox.template.yaml`: reusable starter files for other repos

The Go CLI reads `devvm.yaml`, passes the referenced cloud-init file to
Multipass, waits for cloud-init to finish, and can optionally mount one
explicit host repo into the VM.

## Templates

Start from the reusable templates when you want to adopt this workflow in a
different repository:

- Copy `templates/devvm.template.yaml`
- Copy `templates/opencode-sandbox.template.yaml`
- Adjust instance sizing, mount paths, workspace path, package policy, and OpenCode settings

The template config already points at the template cloud-init using a relative
path, so the pair stays portable when copied together.

## Package Policy

- Use `apt` for Ubuntu bootstrap and guest hardening packages
- Use Homebrew for userland tools that are better supported there

The checked-in cloud-init files implement that policy by:

- installing bootstrap packages from official Ubuntu repositories only
- downloading the official Homebrew installer from a pinned `Homebrew/install` commit
- verifying the installer SHA-256 before executing it
- checking out a pinned `homebrew/core` commit before any `brew install`
- disabling Homebrew auto-update during provisioning

The reusable template installs pinned `opencode` only. The repo-specific VM
installs pinned `opencode` plus pinned `go` because this repository is a Go
project.

## Prerequisites

- Multipass installed and running
- Go 1.26 or newer

## Install As a CLI

Install from the current checkout:

```bash
go install ./cmd/devvm
```

If your Go bin directory is not already on `PATH`, add it:

```bash
export PATH="$(go env GOPATH)/bin:$PATH"
```

Then run the command directly:

```bash
devvm create
```

If you want a project-local binary instead of `go install`:

```bash
mkdir -p .bin
go build -o ./.bin/devvm ./cmd/devvm
./.bin/devvm create
```

## Quick Start

Run the repo-specific setup from the repository root:

```bash
go run ./cmd/devvm create
```

Or pass an explicit config path:

```bash
go run ./cmd/devvm create --config ./devvm.yaml
```

Enter the VM:

```bash
multipass shell <vm-name>
```

Launch OpenCode as the `agent` user:

```bash
sudo -iu agent
opencode
```

Or run it directly from the host without opening an interactive shell first:

```bash
multipass exec <vm-name> -- sudo -iu agent -- opencode
```

The repo-specific setup uses `/home/agent/workspace/multipass-devenv` as the
agent workspace.

The repo-specific VM also provisions these Homebrew-managed tools during first
boot:

- `opencode 1.3.10`
- `go 1.26.1`

If you configure a mount, the repo appears at the `mount.guest_path` you chose.

## Config File

`devvm.yaml` is validated against `schemas/devvm.schema.json`.

Example:

```yaml
schema_version: "1.0"
cloud_init: "./opencode-sandbox.repo.yaml"

mount:
  host_path: "."
  guest_path: "/home/agent/workspace/multipass-devenv"
  privileged: true

instance:
  name: "multipass-devenv-devvm"
  ubuntu_release: "24.04"
  cpus: 2
  memory: "4G"
  disk: "30G"
```

The reusable starter config lives at `templates/devvm.template.yaml` and points
to `templates/opencode-sandbox.template.yaml`.

If `instance.name` is omitted, the CLI derives a valid Multipass name from the
project directory.

The `mount` section is optional. When present:

- `host_path` must resolve to an existing host directory
- `guest_path` must be an absolute path inside the VM
- `privileged` controls whether the CLI runs `multipass set local.privileged-mounts=<bool>` before mounting

## How It Works

1. The CLI reads and validates `devvm.yaml`.
2. It resolves the configured cloud-init file path.
3. It launches a fresh Ubuntu VM with `multipass launch`.
4. It waits for `cloud-init status --wait`.
5. If `mount` is configured, it sets `local.privileged-mounts` and runs `multipass mount`.
6. It reports success.

## Verification

Build and test the CLI:

```bash
go test ./...
go build ./...
```

After creating a VM:

```bash
whoami
sudo -n true
sudo ufw status verbose
systemctl is-enabled ssh || systemctl is-enabled sshd
brew --version
brew list --versions opencode go
```

Expected results:

- `whoami` prints the non-root guest user from the referenced cloud-init file
- `sudo -n true` fails
- UFW shows deny-by-default policies with outbound allows plus inbound SSH for Multipass access
- SSH remains available so `multipass exec` and `multipass shell` work
- Homebrew is available from `/home/linuxbrew/.linuxbrew`
- `brew list --versions opencode go` matches the pinned versions in `opencode-sandbox.repo.yaml`

For the reusable starter artifacts, expect `brew list --versions opencode` to
report the pinned OpenCode version and `go` to be absent unless you add it.

If you configured a mount, also verify:

```bash
ls /home/agent/workspace/multipass-devenv
```

## Repository Layout

```text
multipass-devenv/
├── cmd/
│   └── devvm/
│       └── main.go
├── internal/
│   ├── config/
│   ├── create/
│   └── multipass/
├── opencode-sandbox.repo.yaml
├── templates/
│   ├── devvm.template.yaml
│   └── opencode-sandbox.template.yaml
├── schemas/
│   └── devvm.schema.json
├── devvm.yaml
└── README.md
```

## Project Docs

- ADRs: `docs/adrs/`
- Constraints: `docs/constraints.yaml`
- Architecture: `docs/architecture.adoc`
- Feature artifacts: `docs/features/dev-env-setup/`
