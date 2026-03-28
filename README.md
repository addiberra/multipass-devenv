# Secure Multipass Dev Environment

An isolated development environment for agentic AI coding tools like OpenCode CLI. It launches an Ubuntu VM with Multipass, clones your repo inside the guest, injects only the secrets you provide, and restricts outbound network access via UFW.

## Features

- **VM isolation**: Multipass provides the primary boundary between host and agent execution
- **No host mounts**: Repositories are cloned inside the VM
- **Network egress controls**: UFW applies a default-deny outbound policy allowing only ports 443, 22, and 53
- **Secret injection**: Credentials are written via cloud-init instead of inherited from the host environment
- **Non-root execution**: OpenCode runs as the `opencode` user with no sudo access

## Prerequisites

- **Multipass** installed and running
  ```bash
  # macOS
  brew install --cask multipass

  # Linux
  sudo snap install multipass
  ```
- **Git** available on the host

## Quick Start

### 1. Create a secrets file

```bash
# Required
OPENAI_API_KEY=sk-your-openai-api-key
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=your@email.com

# Optional
OPENCODE_API_KEY=your-opencode-api-key
```

Do not commit `secrets.env` to version control.

### 2. Launch the environment

```bash
./scripts/launch.sh \
  --repo https://github.com/your-org/your-repo.git \
  --secrets secrets.env
```

### 3. Connect to the VM

```bash
multipass shell <vm-name>
```

Your repository is cloned to `/home/opencode/workspace/`.

## Usage

### `launch.sh`

```text
Usage: ./scripts/launch.sh [OPTIONS]

Required:
  --repo <url>           Git repository URL to clone inside VM
  --secrets <file>       Path to secrets.env file with API keys and git config

Optional:
  --name <name>          VM name (default: auto-generated from repo)
  --dry-run              Show configuration without creating VM
  --help                 Show this help message
```

### Dry run

```bash
./scripts/launch.sh --dry-run --repo <url> --secrets secrets.env
```

## Network Rules

UFW is configured with a default-deny outbound policy. The following ports are allowed:

| Port | Protocol | Purpose |
|------|----------|---------|
| 443 | TCP | HTTPS (APIs, package registries, git over HTTPS) |
| 22 | TCP | SSH (git clone/push) |
| 53 | UDP/TCP | DNS resolution |

## Security Model

- The primary isolation boundary is the Multipass VM
- Repositories live only inside the guest workspace
- SSH is disabled; access is through `multipass shell`
- Secrets are injected through cloud-init and stored in the guest
- OpenCode runs as a non-root user with sudo revoked after setup

## Directory Structure

```text
multipass-devenv/
├── cloud-init/
│   ├── base.yaml
│   └── security.yaml
├── scripts/
│   ├── launch.sh
│   ├── inject-secrets.sh
│   └── validate.sh
├── templates/
│   ├── opencode-config.yaml.j2
│   └── requirements.pinned.txt.j2
└── README.md
```

## Verification

After launching a VM:

```bash
# Inside the VM
whoami
sudo ufw status verbose
curl https://github.com
opencode --version
git config --global user.name
git config --global user.email
```

Expected results:

- `whoami` prints `opencode`
- `ufw status` shows default deny with allow rules for 443, 22, 53
- `curl https://github.com` succeeds
- `opencode --version` prints a version

## Troubleshooting

### VM fails to start

1. Check `multipass list`
2. Check `multipass info <name>`
3. Review `/var/log/cloud-init-output.log` inside the VM

### Network access issues

1. Check `sudo ufw status verbose`
2. Check `/var/log/ufw.log`

## Project Docs

- ADR: `docs/adrs/0001-multipass-sandbox.yaml`
- Constraints: `docs/constraints.yaml`
- Architecture: `docs/architecture.adoc`

## License

MIT License - see `LICENSE`
