# Secure Multipass Dev Environment

Minimal MVP for launching a Multipass VM from two checked-in inputs:

- `devvm.yaml`
- `opencode-sandbox.yaml`

The Go CLI reads `devvm.yaml`, passes the referenced cloud-init file to
Multipass, and waits for cloud-init to finish.

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

Run the create command from the repository root:

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

The `agent` user's workspace is `/home/agent/workspace`.

## Config File

`devvm.yaml` is validated against `schemas/devvm.schema.json`.

Example:

```yaml
schema_version: "1.0"
cloud_init: "./opencode-sandbox.yaml"

instance:
  name: "my-project-devvm"
  ubuntu_release: "24.04"
  cpus: 2
  memory: "4G"
  disk: "30G"
```

If `instance.name` is omitted, the CLI derives a valid Multipass name from the
project directory.

## How It Works

1. The CLI reads and validates `devvm.yaml`.
2. It resolves the configured cloud-init file path.
3. It launches a fresh Ubuntu VM with `multipass launch`.
4. It waits for `cloud-init status --wait` before reporting success.

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
```

Expected results:

- `whoami` prints the non-root guest user from `opencode-sandbox.yaml`
- `sudo -n true` fails
- UFW shows deny-by-default policies with outbound allows plus inbound SSH for Multipass access
- SSH remains available so `multipass exec` and `multipass shell` work

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
├── opencode-sandbox.yaml
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
