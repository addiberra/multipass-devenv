# Secure Multipass Dev Environment

An isolated development environment for agentic coding tools like OpenCode.
The project now uses a thin Go `create` CLI that reads `devvm.yaml`, creates a
Multipass VM, transfers only the files needed for the session, and bootstraps
the guest without host mounts or SSH access.

## Features

- VM isolation through Multipass
- Config-driven startup with `devvm.yaml`
- No host workspace mounts
- Scoped provisioning-file delivery instead of host env inheritance
- UFW default-deny network posture with explicit outbound allow rules
- Non-root guest runtime with sudo removed after setup

## Prerequisites

- Multipass installed and running
- Go 1.26 or newer
- Git available on the host

## Quick Start

### 1. Create a secrets file

Create `secrets.env` in the project root:

```bash
OPENAI_API_KEY=sk-your-openai-api-key
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@example.com

# Optional
OPENCODE_API_KEY=your-opencode-api-key
```

Do not commit `secrets.env`.

### 2. Configure `devvm.yaml`

The repository includes a sample `devvm.yaml`. Update at least:

- `source.repo`
- `source.branch` if needed
- `secrets.env_file`
- `opencode.download_url`
- `opencode.sha256`

Security checks enforced by the CLI:

- `opencode.download_url` must use the official OpenCode GitHub release path
- SSH repository URLs are only supported for `github.com` and `gitlab.com`
- HTTPS repository URLs are the default and work with the default `53` and `443` egress policy

### 3. Create the environment

```bash
go run ./cmd/devvm create
```

Optional:

```bash
go run ./cmd/devvm create --config ./devvm.yaml
```

### 4. Enter the VM

```bash
multipass shell <vm-name>
```

The configured repository is cloned into `guest.repo_dir` inside the VM.

## Config File

`devvm.yaml` is validated against `schemas/devvm.schema.json`.

Top-level sections:

- `instance`
- `source`
- `base`
- `guest`
- `provisioning`
- `secrets`
- `security`
- `opencode`

Example:

```yaml
schema_version: "1.0"

instance:
  name: "my-project-dev"
  ubuntu_release: "24.04"
  cpus: 2
  memory: "4G"
  disk: "30G"

source:
  repo: "https://github.com/org/repo.git"
  branch: "main"

base:
  enabled: true
  instance_name: "opencode-base"

guest:
  user: "opencode"
  workspace_dir: "/home/opencode/workspace"
  repo_dir: "/home/opencode/workspace/repo"

provisioning:
  cloud_init: "./cloud-init/base.yaml"
  bootstrap_script: "./scripts/bootstrap-guest.sh"

secrets:
  env_file: "./secrets.env"

security:
  disable_ssh: true
  mount_workspace: false
  allowed_outbound_ports:
    - 53
    - 443

opencode:
  config_template: "./templates/opencode-config.yaml.j2"
  config_path: "/home/opencode/.config/opencode/config.yaml"
  download_url: "https://github.com/anomalyco/opencode/releases/download/example/opencode-linux-amd64"
  sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
```

## How It Works

1. The CLI reads and validates `devvm.yaml`.
2. It clones from a configured base instance when available, otherwise it launches a fresh Ubuntu VM with static cloud-init.
3. It waits for the guest to become ready.
4. It transfers scoped provisioning files into the guest.
5. It runs `scripts/bootstrap-guest.sh` inside the VM to configure UFW, install OpenCode, render config, and clone the repository.

## Security Model

- The primary isolation boundary is the Multipass VM
- Host directories are not mounted into the guest
- Secrets are provided through scoped files copied during setup
- SSH is disabled; access is through `multipass shell`
- The guest user is non-root and loses sudo access after provisioning
- SSH-based git clones use pinned host keys for `github.com` and `gitlab.com`

## Verification

Build the CLI:

```bash
go build ./...
```

After creating a VM:

```bash
whoami
sudo -n true
sudo ufw status verbose
opencode --version
git -C /home/opencode/workspace/repo branch --show-current
```

Expected results:

- `whoami` prints the configured guest user
- `sudo -n true` fails
- UFW shows deny-by-default with only the configured outbound allows
- `opencode --version` succeeds

## Repository Layout

```text
multipass-devenv/
├── cloud-init/
│   └── base.yaml
├── cmd/
│   └── devvm/
│       └── main.go
├── internal/
│   ├── config/
│   ├── create/
│   ├── multipass/
│   └── provisioning/
├── schemas/
│   └── devvm.schema.json
├── scripts/
│   └── bootstrap-guest.sh
├── templates/
│   └── opencode-config.yaml.j2
├── devvm.yaml
└── README.md
```

## Project Docs

- ADRs: `docs/adrs/`
- Constraints: `docs/constraints.yaml`
- Architecture: `docs/architecture.adoc`
- Feature artifacts: `docs/features/dev-env-setup/`
