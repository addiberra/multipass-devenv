---
name: cloud-init-multipass
description: >
  Use this skill whenever the user wants to create, edit, debug, or understand cloud-init
  configuration files for use with Multipass. This includes provisioning Ubuntu VMs,
  setting up users/groups/SSH keys, installing packages, writing files, running shell
  commands, configuring hostname/mounts/locale/timezone, and setting up agent sandboxes
  with security controls (egress firewall, restricted users, config immutability).
  Trigger on any mention of cloud-init, cloud-config, #cloud-config, user-data,
  multipass launch --cloud-init, Multipass VM provisioning, or first-boot automation
  of Ubuntu VMs. Also trigger when users ask about sandboxing AI agents in VMs,
  bootstrapping Multipass instances, or automating local development environments.
---

# Cloud-Init for Multipass

Cloud-init is the standard for automating first-boot configuration of Ubuntu instances.
Multipass uses the NoCloud datasource — you write a YAML file and pass it at launch time:

```bash
multipass launch --name my-vm --cpus 2 --memory 2G --disk 20G --cloud-init config.yaml
```

Cloud-init reads the file on the very first boot and applies it before you can SSH in.
This skill helps produce correct cloud-config YAML and explain what each section does.

## Before you start writing

Read `references/cheatsheet.md` — it contains syntax, examples, and common patterns for
every supported module. Consult it for exact key names and option values.

## Output format

Every response should include:

1. **The complete cloud-config YAML** — saved as a `.yaml` file. Always start the file
   with `#cloud-config` on line 1 (this is how cloud-init recognises it).
2. **A section-by-section explanation** — after the YAML, walk through each top-level key
   and briefly explain what it does and why. Keep it concise but clear enough that the
   user can modify the config confidently.
3. **The multipass launch command** — include the full command with any relevant flags
   (`--cpus`, `--memory`, `--disk`, `--cloud-init`).

## Structuring the YAML

Order top-level keys in this sequence. Only include sections the user needs:

1. `groups` — create groups before users that reference them
2. `users` — user accounts, SSH keys, sudo rules
3. `ssh_pwauth` / `disable_root` — SSH authentication policy
4. `locale` / `timezone` — system locale and timezone
5. `ntp` — NTP configuration
6. `package_update` / `package_upgrade` — apt cache + upgrade
7. `packages` — apt packages to install
8. `snap` — snap packages to install
9. `ca_certs` — custom CA certificates (corporate proxies, internal CAs)
10. `write_files` — drop config files onto disk (before packages unless `defer: true`)
11. `mounts` — filesystem mounts and swap
12. `runcmd` — shell commands that run once on first boot (after packages)
13. `bootcmd` — commands that run on every boot (use sparingly)
14. `power_state` — reboot after provisioning if needed

## Key principles

**YAML correctness matters a lot.** A single indentation error silently breaks a section.
Use 2-space indentation, quote strings containing colons or special characters, use `|`
for multi-line file content. Never use tabs.

**Explain trade-offs.** When there are multiple approaches (e.g. `runcmd` vs
`write_files` + a systemd unit), briefly note why you chose one.

**Ask for SSH public keys.** If the config needs an SSH key and the user hasn't provided
one, ask for it. If they want a placeholder, use `ssh-ed25519 AAAA...YOUR_KEY_HERE` with
a comment reminding them to replace it.

**Security context matters.** The right security controls depend on the use case:

For **development VMs** (local dev environments, testing):
- Keep it simple — the default `ubuntu` user with sudo is usually fine
- Install the packages and tools the user needs
- No need for firewalls or SSH hardening on a local Multipass VM

For **agent sandboxes** (AI coding agents, agentic workflows):
- Network egress deny-by-default with scoped allowlists
- Dedicated low-privilege agent user with no sudo
- Empty environment — no inherited secrets
- Config file immutability to prevent persistence
- Ephemeral lifecycle — destroy and recreate, don't accumulate state
See the "Agent Sandbox Security" section in `references/cheatsheet.md`.

## Multipass-specific things to know

- Multipass creates a default `ubuntu` user with your host's SSH key. If you define a
  `users` block without `- default` as the first entry, the ubuntu user is NOT created.
  This can lock you out.
- `--cloud-init` only passes **user-data**. Network config and metadata are not supported.
- Multipass may mount the host home directory by default. Disable with
  `multipass set local.privileged-mounts=false` — important for agent sandboxes.
- Default image is the latest Ubuntu LTS. Specify others with e.g. `multipass launch 22.04`.
- Verify cloud-init status: `multipass exec my-vm -- cloud-init status --long`
- View output log: `multipass exec my-vm -- cat /var/log/cloud-init-output.log`
- The VM needs internet for `package_update` and `packages`. Check with
  `multipass exec my-vm -- ping -c1 archive.ubuntu.com`.

## Understanding boot stages

Cloud-init runs in stages. Knowing the order prevents subtle bugs:

**Init stage** (early): `bootcmd`, `write_files` (non-deferred), `growpart`, `mounts`,
`set_hostname`, `ca_certs`, `users_groups`, `ssh`.

**Config stage** (after networking): `snap`, `locale`, `ntp`, `timezone`, `runcmd`
(generates script only — does NOT execute yet).

**Final stage** (late boot): `package_update_upgrade_install` (apt), `write_files_deferred`,
`scripts_user` (executes runcmd script).

Key implications:
- `write_files` without `defer` runs before packages are installed — config files land
  on disk before the package that owns the directory exists. This usually works fine.
- `write_files` with `defer: true` runs in the Final stage, after packages.
- `runcmd` commands execute after packages are installed (Final stage), even though the
  runcmd module appears in the Config stage. Safe to reference newly installed packages.
- `bootcmd` runs on every boot. Use `cloud-init-per` if you need early + once-only.

## Common pitfalls

- **Forgetting `#cloud-config`** on line 1 — without it, cloud-init treats the file as
  a shell script.
- **Using `runcmd` for things `write_files` can do** — `echo` in runcmd is fragile. Use
  `write_files` for config files, reserve runcmd for commands.
- **Not setting `package_update: true`** — the apt cache may be stale, causing package
  installs to fail silently.
- **Omitting `- default` from `users`** — the `ubuntu` user won't be created and you
  lose SSH access.
- **Writing to /tmp** — may be cleared during boot. Use `/run/somedir` for temp files.
- **Blocking commands in runcmd** — a command that never exits (foreground daemon,
  accidental `cloud-init status --wait`) blocks everything after it. Use systemd units
  for long-running processes.
- **Forgetting `owner` and `permissions`** on `write_files` — defaults to root:root
  0644, which may not be what you want for scripts (need 0755) or secrets (need 0600).
- **Plain-text passwords** — use `mkpasswd --method=SHA-512` for hashes. Even hashed
  passwords persist in `/var/lib/cloud/instance/user-data.txt` inside the VM.

## Debugging

**Validate before launching:**
```bash
cloud-init schema --config-file config.yaml
```

**From the host (via Multipass):**
```bash
multipass exec my-vm -- cloud-init status --long
multipass exec my-vm -- cat /var/log/cloud-init-output.log
multipass exec my-vm -- cat /var/log/cloud-init.log | tail -50
multipass exec my-vm -- cat /var/lib/cloud/instance/user-data.txt
```

**Performance (if boot feels slow):**
```bash
multipass exec my-vm -- cloud-init analyze blame
```

**Re-run cloud-init for testing:**
```bash
multipass exec my-vm -- sudo cloud-init clean --logs
multipass restart my-vm
```

**Nuclear option — destroy and recreate:**
```bash
multipass delete my-vm --purge
multipass launch --name my-vm --cloud-init config.yaml
```
This is often faster than debugging. Multipass VMs are cheap.
