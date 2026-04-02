# Manual Setup Guide

Use this guide if you do not want to use the Go CLI tool (`devvm create`). The CLI is a thin wrapper around Multipass commands—everything it does can be done manually.

## Overview

The manual setup follows the same steps as the CLI:

1. Read values from your config file
2. Launch a VM with a cloud-init file
3. Wait for cloud-init to complete
4. Optionally configure a host mount
5. Enter the VM and run OpenCode

## Prerequisites

- Multipass installed and running
- A valid `devvm.yaml` config file

## Step 1: Read Your Config

The manual commands require values from your `devvm.yaml`:

```yaml
# Example values from any devvm.yaml (repo or template)
cloud_init: "./opencode-sandbox.repo.yaml"

mount:
  host_path: "."
  guest_path: "/home/agent/workspace/multipass-devenv"
  privileged: true

instance:
  name: "my-devvm"
  ubuntu_release: "24.04"
  cpus: 2
  memory: "4G"
  disk: "30G"
```

Extract these values for use in the commands below:

- `<cloud-init-path>`: Path to your cloud-init file (resolve relative to `devvm.yaml` directory)
- `<vm-name>`: The instance name
- `<ubuntu-release>`: Ubuntu version (e.g., `24.04`)
- `<cpus>`, `<memory>`, `<disk>`: Resource limits
- `<host-path>`: Optional mount source on host (omit if no mount section)
- `<guest-path>`: Optional mount destination in VM (omit if no mount section)
- `<privileged>`: `true` or `false` for privileged mount setting (omit if no mount section)

## Step 2: Launch the VM

From the directory containing your `devvm.yaml`, run:

```bash
multipass launch <ubuntu-release> \
  --name <vm-name> \
  --cpus <cpus> \
  --memory <memory> \
  --disk <disk> \
  --cloud-init <cloud-init-path>
```

**Example** (using this repo's config):

```bash
multipass launch 24.04 \
  --name multipass-devenv-devvm \
  --cpus 2 \
  --memory 4G \
  --disk 30G \
  --cloud-init ./opencode-sandbox.repo.yaml
```

## Step 3: Wait for Cloud-Init

The VM is ready when cloud-init completes:

```bash
multipass exec <vm-name> -- cloud-init status --wait
```

This waits for all provisioning scripts to finish.

## Step 4: Configure Mount (Optional)

If your `devvm.yaml` includes a `mount` section:

1. Set the privileged mounts policy:

```bash
multipass set local.privileged-mounts=<privileged>
```

2. Mount the host directory into the VM:

```bash
multipass mount <host-path> <vm-name>:<guest-path>
```

**Example** (using this repo's config):

```bash
multipass set local.privileged-mounts=true
multipass mount . multipass-devenv-devvm:/home/agent/workspace/multipass-devenv
```

## Step 5: Enter the VM

Open a shell in the VM:

```bash
multipass shell <vm-name>
```

Then switch to the agent user and launch OpenCode:

```bash
sudo -iu agent
opencode
```

Or run it directly without opening an interactive shell:

```bash
multipass exec <vm-name> -- sudo -iu agent -- opencode
```

## Verification

After the VM is created, verify the environment matches your cloud-init:

```bash
# Check non-root user
whoami
# Expected: agent (or whatever user your cloud-init creates)

# Verify no sudo access
sudo -n true
# Expected: fails

# Check firewall
cat /etc/ufw/user.rules | grep -E "allow|deny"
# Expected: deny-by-default with explicit outbound allows

# Verify Homebrew tools
brew list --versions
# Expected: packages installed by your cloud-init (e.g., opencode, go)

# Check mount (if configured)
ls <guest-path>
# Expected: contents of your host directory
```

## Equivalent CLI Command

The manual steps above are equivalent to:

```bash
devvm create
# Or with explicit config path:
devvm create --config ./devvm.yaml
```

## Template Usage

This guide works for any valid `devvm.yaml`, including:

- **This repository's setup**: `devvm.yaml` + `opencode-sandbox.repo.yaml`
- **Reusable templates**: Copy `templates/devvm.template.yaml` and `templates/opencode-sandbox.template.yaml` to your project, adjust the paths, and follow this guide

For templates, update the placeholders to match your copied config values:

```yaml
# In your copied template
customize these:
  - instance.name
  - mount.host_path
  - mount.guest_path
  - cloud_init path (relative to your devvm.yaml)
```

## Cleanup

When done, delete the VM:

```bash
multipass delete <vm-name> --purge
```
