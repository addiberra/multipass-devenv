# Secure Multipass Dev Environment

A secure, ephemeral development environment for agentic AI coding tools like OpenCode CLI. Uses Multipass to launch Ubuntu VMs with kernel-level isolation from the host, following security best practices for sandboxing AI workloads.

## Features

- **Kernel-level isolation**: Full VM virtualization (not containers) separates agent execution from host
- **No host mounts**: Repositories are cloned inside the VM, not mounted from host
- **Network egress controls**: iptables whitelist restricts outbound traffic
- **Filesystem isolation**: AppArmor confines writes to designated workspace
- **Secret injection**: Credentials injected via cloud-init, not inherited from host
- **Ephemeral lifecycle**: VM destroyed after session to prevent accumulation

## Prerequisites

- **Multipass**: Installed and running
  ```bash
  # macOS
  brew install --cask multipass

  # Linux
  sudo snap install multipass
  ```

- **Git**: For cloning repositories

## Quick Start

### 1. Create a secrets file

Create a `secrets.env` file with your credentials:

```bash
# Required
OPENAI_API_KEY=sk-your-openai-api-key
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=your@email.com

# Optional
OPENCODE_API_KEY=your-opencode-api-key
```

**Security Note**: Never commit `secrets.env` to version control. Add it to `.gitignore`.

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

Your repository is cloned to `/home/opencode/workspace/`. OpenCode is preconfigured with your API keys.

### 4. Tear down when done

```bash
./scripts/teardown.sh --name <vm-name>
```

Or force without confirmation:

```bash
./scripts/teardown.sh --name <vm-name> --force
```

## Usage

### launch.sh Options

```
Usage: ./scripts/launch.sh [OPTIONS]

Required:
  --repo <url>           Git repository URL to clone inside VM
  --secrets <file>       Path to secrets.env file with API keys and git config

Optional:
  --name <name>          VM name (default: auto-generated from repo)
  --network <file>       Custom network whitelist YAML (default: config/network-whitelist.default.yaml)
  --dry-run              Show configuration without creating VM
  --help                 Show this help message
```

### teardown.sh Options

```
Usage: ./scripts/teardown.sh [OPTIONS]

Required:
  --name <vm-name>       Name of the Multipass VM to destroy

Optional:
  --force                Skip confirmation prompt
  --help                 Show this help message
```

## Security Model

### Network Whitelist

By default, outbound network access is restricted to:

| Service | Ports | Purpose |
|---------|-------|---------|
| GitHub | 22, 443 | Git clone/push |
| GitLab | 22, 443 | Git clone/push |
| OpenAI API | 443 | LLM provider |
| OpenCode API | 443 | Alternative LLM |
| PyPI | 443 | Python packages |
| npm registry | 443 | Node.js packages |
| crates.io | 443 | Rust packages |

DNS is restricted to trusted resolvers (8.8.8.8, 1.1.1.1).

### Custom Network Whitelist

Create a custom `network-whitelist.yaml`:

```yaml
egress_allowed:
  - domain: github.com
    ports: [22, 443]
  - domain: internal-api.company.com
    ports: [443]

dns_servers:
  - 8.8.8.8
  - 1.1.1.1
```

Launch with custom whitelist:

```bash
./scripts/launch.sh \
  --repo <url> \
  --secrets secrets.env \
  --network network-whitelist.yaml
```

### Filesystem Isolation

AppArmor restricts writes to:
- `/home/opencode/workspace/` - Read/write (work files)
- `/home/opencode/.config/opencode/` - Read-only after setup (credentials)
- `/home/opencode/.gitconfig` - Read-only after setup (git config)

All other paths are read-only or denied.

### Supply Chain Security

- **apt packages**: Official Ubuntu repositories only
- **Python packages**: Hash verification via `pip install --require-hashes`
- **npm packages**: Integrity verification via package-lock.json
- **OpenCode CLI**: SHA256 checksum verification before installation

## Directory Structure

```
multipass-devenv/
├── config/
│   └── network-whitelist.default.yaml   # Default network egress rules
├── cloud-init/
│   ├── base.yaml                         # Base VM configuration
│   ├── security.yaml                     # Security hardening
│   └── apparmor-profile                  # AppArmor profile
├── scripts/
│   ├── launch.sh                         # VM launch orchestration
│   ├── teardown.sh                      # VM destruction
│   └── inject-secrets.sh                # Secret processing helper
├── templates/
│   ├── opencode-config.yaml.j2          # OpenCode config template
│   └── requirements.pinned.txt.j2        # Python requirements template
└── README.md
```

## Verification

After launching a VM, verify security controls:

```bash
# Inside the VM (multipass shell <name>)

# Verify non-root user
whoami  # Should output: opencode

# Verify network restrictions (should fail)
curl https://example.com

# Verify allowed network (should succeed)
curl https://github.com

# Verify filesystem isolation (should fail)
touch /tmp/test-write

# Verify workspace write (should succeed)
touch /home/opencode/workspace/test-write

# Verify OpenCode is installed
opencode --version

# Verify git is configured
git config --global user.name
git config --global user.email
```

## Troubleshooting

### VM fails to start

1. Check Multipass is running: `multipass list`
2. Check available resources: `multipass info`
3. Check cloud-init logs: `multipass shell <name>` → `cat /var/log/cloud-init-output.log`

### Network access blocked

1. Verify the domain is in your whitelist
2. Check iptables rules: `sudo iptables -L OUTPUT -n -v`
3. Check logs: `dmesg | grep IPTABLES_DROP`

### AppArmor blocking writes

1. Check AppArmor status: `sudo apparmor_status`
2. Check profile is loaded: `sudo aa-status`
3. View denials: `dmesg | grep apparmor`

## Architecture Decisions

See [docs/adrs/0001-multipass-sandbox.yaml](docs/adrs/0001-multipass-sandbox.yaml) for the rationale behind using Multipass VMs.

## Security Constraints

See [docs/constraints.yaml](docs/constraints.yaml) for the complete list of security constraints enforced by this system.

## Development Workflow

This project follows the proven-needs state transition workflow. See [AGENTS.md](AGENTS.md) for details.

## License

MIT License - see [LICENSE](LICENSE) for details.