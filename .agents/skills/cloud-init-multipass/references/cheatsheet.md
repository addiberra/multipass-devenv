# Cloud-Init Cheat Sheet for Multipass

Quick reference for cloud-init modules relevant to Multipass Ubuntu VMs. Every example
is a fragment — combine them under a single `#cloud-config` header in one YAML file.

## Table of Contents

1. [Users and Groups](#users-and-groups)
2. [SSH Configuration](#ssh-configuration)
3. [Package Management](#package-management)
4. [Write Files](#write-files)
5. [Run Commands](#run-commands)
6. [Boot Commands](#boot-commands)
7. [Hostname](#hostname)
8. [Locale and Timezone](#locale-timezone)
9. [NTP Configuration](#ntp)
10. [Snap Packages](#snap)
11. [Mounts and Swap](#mounts-and-swap)
12. [CA Certificates](#ca-certificates)
13. [Power State](#power-state)
14. [Agent Sandbox Security](#agent-sandbox)
15. [Boot Stage Execution Order](#boot-stages)

---

## Users and Groups <a name="users-and-groups"></a>

Groups are created before users. Include `- default` as the first user entry to keep the
`ubuntu` user that Multipass creates — omitting it locks you out of SSH.

```yaml
groups:
  - admingroup: [root, sys]
  - deploy-users

users:
  - default                          # keep the Multipass ubuntu user
  - name: deploy
    gecos: Deploy User
    shell: /bin/bash
    groups: [sudo, deploy-users]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true                # disable password login
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... user@host
```

**Key user fields:**
- `name` (required) — username
- `gecos` — comment / real name
- `shell` — login shell (default: system default)
- `primary_group` — override the auto-created group
- `groups` — supplementary groups (list or comma-separated string)
- `sudo` — sudoers rule(s), string or list
- `lock_passwd` — if true, disable password login (recommended with SSH keys)
- `passwd` — hashed password (generate with `mkpasswd --method=SHA-512`)
- `ssh_authorized_keys` — list of public keys
- `ssh_import_id` — import keys from GitHub (`gh:username`) or Launchpad (`lp:username`)
- `system` — if true, create as a system user (no home dir by default)
- `no_create_home` — skip home directory creation
- `no_log_init` — don't initialize lastlog/faillog databases

Most user options are ignored if the user already exists. Exceptions that can be applied
to existing users: `plain_text_passwd`, `hashed_passwd`, `lock_passwd`, `sudo`,
`ssh_authorized_keys`, `ssh_redirect_user`.

---

## SSH Configuration <a name="ssh-configuration"></a>

```yaml
ssh_pwauth: false        # disable password auth for SSH
disable_root: true       # disable root SSH login

ssh_genkeytypes: [ed25519, ecdsa]   # host key types to generate

ssh:
  emit_keys_to_console: false       # don't print host keys to console
```

SSH keys for individual users go in the `users` block. In Multipass, the `ubuntu` user
already gets your host's SSH key automatically.

---

## Package Management <a name="package-management"></a>

```yaml
package_update: true             # apt-get update before install
package_upgrade: true            # apt-get upgrade existing packages
package_reboot_if_required: true # reboot if needed after upgrades

packages:
  - curl
  - git
  - htop
  - vim
  - jq
  - build-essential
  - [nginx, "1.24.0-1ubuntu1"]   # pin a specific version
```

Packages are installed in the Final boot stage, after `write_files` (non-deferred) have
already been written. So config files you drop via `write_files` will be in place when
the package's post-install scripts run.

**Adding apt repositories** (e.g. Docker):
```yaml
apt:
  sources:
    docker.list:
      source: "deb [arch=amd64] https://download.docker.com/linux/ubuntu $RELEASE stable"
      keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
```

---

## Write Files <a name="write-files"></a>

Files are written in the Init stage (before packages) by default. Use `defer: true` to
write in the Final stage (after packages), useful when the target directory only exists
after a package is installed.

```yaml
write_files:
  - path: /etc/myapp/config.yaml
    owner: root:root
    permissions: "0644"
    content: |
      setting_a: true
      setting_b: 42

  - path: /usr/local/bin/setup.sh
    owner: root:root
    permissions: "0755"              # executable
    content: |
      #!/bin/bash
      echo "Hello from first boot"

  - path: /etc/nginx/sites-available/myapp
    defer: true                      # written after nginx package is installed
    owner: root:root
    permissions: "0644"
    content: |
      server {
        listen 80;
        server_name _;
        location / {
          proxy_pass http://127.0.0.1:3000;
        }
      }
```

**Fields:**
- `path` (required) — absolute path
- `content` — file content (use `|` for multi-line)
- `owner` — owner:group (default: root:root)
- `permissions` — octal string (default: "0644")
- `encoding` — `text` (default), `b64`, `gz`, or `gz+b64`
- `append` — if true, append instead of overwrite
- `defer` — if true, write in Final stage after packages are installed

---

## Run Commands <a name="run-commands"></a>

Commands run as root on first boot only, in the Final stage — after packages are installed
and non-deferred files are written.

```yaml
runcmd:
  # Simple string (shell interpretation: pipes, redirects, globbing work)
  - echo "First boot at $(date)" >> /var/log/first-boot.log

  # List form (no shell — safer, passed directly to execve)
  - [systemctl, enable, --now, nginx]

  # Multi-line script
  - |
    if [ -f /etc/myapp/config.yaml ]; then
      systemctl restart myapp
    fi
```

Use the list form `[cmd, arg1, arg2]` when you don't need shell features. Use string
form when you need pipes, redirects, or variable expansion.

**Don't write files via runcmd** — use `write_files` instead. It's more reliable and the
intent is clearer.

---

## Boot Commands <a name="boot-commands"></a>

Unlike runcmd, bootcmd runs on **every boot**, very early (before networking on some
platforms). Use sparingly.

```yaml
bootcmd:
  - echo "Booting..." > /dev/console
  - [cloud-init-per, once, mymkfs, mkfs, /dev/vdb]
```

`cloud-init-per` ensures a command runs only once even though bootcmd fires every boot.

---

## Hostname <a name="hostname"></a>

```yaml
hostname: dev-vm
fqdn: dev-vm.local
manage_etc_hosts: true        # regenerate /etc/hosts from template
preserve_hostname: false      # allow cloud-init to set hostname
```

---

## Locale and Timezone <a name="locale-timezone"></a>

```yaml
locale: en_US.UTF-8
timezone: Europe/Stockholm
```

These are first-class modules — don't use runcmd for them.

---

## NTP Configuration <a name="ntp"></a>

On Ubuntu 20.04+, chrony is the default NTP client.

```yaml
ntp:
  enabled: true
  ntp_client: chrony
  pools:
    - 0.ubuntu.pool.ntp.org
    - 1.ubuntu.pool.ntp.org
  servers:
    - ntp.example.com
```

If no pools/servers are specified, cloud-init provides 4 defaults:
`{0-3}.ubuntu.pool.ntp.org`.

---

## Snap Packages <a name="snap"></a>

```yaml
snap:
  commands:
    - snap install lxd
    - snap install docker
    - snap install --classic code
    - snap install --classic go
```

Use `--classic` for snaps that need classic confinement.

---

## Mounts and Swap <a name="mounts-and-swap"></a>

```yaml
mounts:
  - [/dev/vdb, /mnt/data, ext4, "defaults,noatime", "0", "2"]

swap:
  filename: /swapfile
  size: 2G
  maxsize: 4G
```

Mount entries follow fstab format: `[device, mountpoint, fstype, options, dump, pass]`.

Note: Multipass has its own mount mechanism (`multipass mount`) for sharing host
directories. Use that instead of cloud-init mounts for host-to-VM sharing.

---

## CA Certificates <a name="ca-certificates"></a>

Useful when behind a corporate proxy or using internal CAs:

```yaml
ca_certs:
  remove_defaults: false
  trusted:
    - |
      -----BEGIN CERTIFICATE-----
      YOUR-ORG-CA-CERT-HERE
      -----END CERTIFICATE-----
```

Certificates are added to the system trust store and `update-ca-certificates` runs
automatically.

---

## Power State <a name="power-state"></a>

```yaml
power_state:
  delay: now
  mode: reboot
  message: "Rebooting after first-boot setup"
  timeout: 30
  condition: true
```

Useful when kernel updates or config changes require a reboot after provisioning.

---

## Agent Sandbox Security <a name="agent-sandbox"></a>

When using a Multipass VM as an isolation boundary for AI coding agents, the threat model
is different from a server. You're constraining what processes *inside* the VM can do if
an agent is manipulated via indirect prompt injection.

This follows guidance from the NVIDIA AI Red Team on sandboxing agentic workflows.

**What Multipass already gives you (no cloud-init needed):**
- Kernel isolation from host (full hardware virtualization)
- Filesystem isolation (host FS not mounted unless you explicitly opt in)
- Process isolation (everything runs inside the VM)

**What cloud-init needs to configure:**

### 1. Network egress deny-by-default

The most critical control. Without it, a manipulated agent can exfiltrate data or open a
reverse shell. Default UFW only filters inbound — you need to restrict outbound.

```yaml
packages:
  - ufw

runcmd:
  # Default deny all traffic
  - ufw default deny outgoing
  - ufw default deny incoming

  # Allow DNS to specific resolvers only
  - ufw allow out to 1.1.1.1 port 53 proto udp
  - ufw allow out to 1.0.0.1 port 53 proto udp

  # Allow HTTP/HTTPS for package repos and APIs
  # For tighter control, replace with specific IP ranges
  - ufw allow out to any port 80 proto tcp
  - ufw allow out to any port 443 proto tcp

  # Allow loopback (required for local services)
  - ufw allow out on lo

  - ufw --force enable
```

For maximum security, replace the broad port 80/443 rules with specific IP ranges for
only the services the agent needs.

**DNS restriction** — lock DNS to specific resolvers to prevent DNS-based exfiltration:

```yaml
write_files:
  - path: /etc/systemd/resolved.conf.d/restricted-dns.conf
    owner: root:root
    permissions: "0644"
    content: |
      [Resolve]
      DNS=1.1.1.1 1.0.0.1
      DNSOverTLS=yes
      Domains=~.

runcmd:
  - systemctl restart systemd-resolved
```

### 2. Dedicated low-privilege agent user

Run the agent as a restricted user — no sudo, no shell history, confined to a workspace.

```yaml
users:
  - default
  - name: agent
    gecos: Sandboxed Agent User
    shell: /bin/bash
    groups: []
    sudo: false
    lock_passwd: true
    no_log_init: true

write_files:
  - path: /home/agent/.bashrc
    owner: agent:agent
    permissions: "0644"
    defer: true
    content: |
      export HISTFILE=/dev/null
      export HISTSIZE=0
      export PATH=/usr/local/bin:/usr/bin:/bin
      export WORKSPACE=/home/agent/workspace
      cd "$WORKSPACE" 2>/dev/null || true

runcmd:
  - mkdir -p /home/agent/workspace
  - chown agent:agent /home/agent/workspace
```

The `default` (ubuntu) user keeps sudo for your own administration.

### 3. Config file immutability

Prevent the agent from modifying files that could enable persistence or escape — shell
profiles, git config, agent config files.

```yaml
runcmd:
  - chattr +i /home/agent/.bashrc
  - chattr +i /home/agent/.profile 2>/dev/null || true
  - chattr +i /home/agent/.bash_logout 2>/dev/null || true
  # Home dir owned by root; workspace writable by agent
  - chown root:agent /home/agent
  - chmod 750 /home/agent
  - chown agent:agent /home/agent/workspace
```

After this, the agent can write freely inside `workspace/` but cannot create or modify
dotfiles anywhere in the home directory. `chattr +i` makes files immutable even to root.

### 4. Clean environment — no inherited secrets

Don't mount your host `.ssh`, `.aws`, `.env`, or credential directories into the VM.
Disable default Multipass mounts:
```bash
multipass set local.privileged-mounts=false
```

If the agent needs specific credentials, inject them at runtime:
```bash
multipass transfer ./deploy-key my-vm:/home/agent/workspace/.deploy-key
multipass exec my-vm -- chmod 600 /home/agent/workspace/.deploy-key
```

### 5. Ephemeral lifecycle

Treat Multipass VMs as disposable. Don't reuse them across sessions.

```bash
# Create
multipass launch --name agent-session-1 --cloud-init agent-sandbox.yaml

# Work happens (may span multiple tasks within the session)...

# Extract results
multipass transfer agent-session-1:/home/agent/workspace/output ./results/

# Destroy
multipass delete agent-session-1 --purge
```

### Complete agent sandbox cloud-config

```yaml
#cloud-config

users:
  - default
  - name: agent
    gecos: Sandboxed Agent User
    shell: /bin/bash
    sudo: false
    lock_passwd: true
    no_log_init: true

package_update: true

packages:
  - ufw

write_files:
  - path: /home/agent/.bashrc
    owner: agent:agent
    permissions: "0644"
    defer: true
    content: |
      export HISTFILE=/dev/null
      export HISTSIZE=0
      export PATH=/usr/local/bin:/usr/bin:/bin
      export WORKSPACE=/home/agent/workspace
      cd "$WORKSPACE" 2>/dev/null || true

  - path: /etc/systemd/resolved.conf.d/restricted-dns.conf
    owner: root:root
    permissions: "0644"
    content: |
      [Resolve]
      DNS=1.1.1.1 1.0.0.1
      DNSOverTLS=yes
      Domains=~.

  - path: /etc/motd
    owner: root:root
    permissions: "0644"
    content: |
      *** EPHEMERAL AGENT SANDBOX ***
      Destroy after use: multipass delete <name> --purge

runcmd:
  # Workspace
  - mkdir -p /home/agent/workspace
  - chown agent:agent /home/agent/workspace

  # Lock home directory
  - chown root:agent /home/agent
  - chmod 750 /home/agent
  - chattr +i /home/agent/.bashrc
  - chattr +i /home/agent/.profile 2>/dev/null || true

  # Egress firewall
  - ufw default deny outgoing
  - ufw default deny incoming
  - ufw allow out to 1.1.1.1 port 53 proto udp
  - ufw allow out to 1.0.0.1 port 53 proto udp
  - ufw allow out to any port 80 proto tcp
  - ufw allow out to any port 443 proto tcp
  - ufw allow out on lo
  - ufw --force enable

  # Restricted DNS
  - systemctl restart systemd-resolved
```

Launch with:
```bash
multipass set local.privileged-mounts=false
multipass launch --name sandbox --cpus 2 --memory 4G --cloud-init agent-sandbox.yaml
```

---

## Boot Stage Execution Order <a name="boot-stages"></a>

```
INIT STAGE (early boot):
  bootcmd → write_files → growpart → resizefs →
  mounts → set_hostname → ca_certs → users_groups → ssh

CONFIG STAGE (after networking):
  snap → locale → ntp → timezone → runcmd (generates script only)

FINAL STAGE (late boot):
  package_update_upgrade_install → write_files_deferred →
  scripts_user (executes runcmd) → final_message
```

Key: `runcmd` generates a script in Config but executes in Final. So runcmd commands
run after packages are installed — safe to reference newly installed binaries.
