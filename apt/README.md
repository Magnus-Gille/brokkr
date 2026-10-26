# apt — OS / package update policy

This directory contains the version-controlled apt configuration pushed to every Pi host
by `scripts/setup-host-patching.sh` (`make patching`).

## Files

| File | Pi path | Purpose |
|------|---------|---------|
| `20auto-upgrades` | `/etc/apt/apt.conf.d/20auto-upgrades` | Enables the stock `apt-daily` / `apt-daily-upgrade` timers to refresh package lists and run unattended-upgrades |
| `50unattended-upgrades` | `/etc/apt/apt.conf.d/50unattended-upgrades` | Policy: **security archive only**, no automatic reboot |
| `51brokkr-claude-code` | `/etc/apt/apt.conf.d/51brokkr-claude-code` | Adds the Claude Code apt repository to the allowed origins (a drop-in, so it also works beside a distribution's own `50unattended-upgrades`, as on an Ubuntu host) |

## Policy summary

- **Security patches only** — `origin=Debian,...-security,label=Debian-Security`. Regular Debian and Raspberry Pi Foundation packages (including kernel/firmware) are deliberately NOT auto-upgraded.
- **One extra origin: Claude Code** (`51brokkr-claude-code`; apt appends `Origins-Pattern` entries across files). `origin=Anthropic,label=Anthropic,codename=stable` matches the Release Origin and Label (`Anthropic`) and codename (`stable`) that the Claude Code apt repository publishes. It lets unattended-upgrades keep an apt-installed `claude-code` package current on hosts that have that repository configured; on a host without it the pattern matches nothing. Hosts where `claude` is installed another way (npm, the native installer) are updated by the agent CLI updater instead, which deliberately leaves apt-owned installs alone (see `../docs/agent-cli-update.md`).
- **No automatic reboot** — reboot-required is detected and surfaced to Munin + Telegram by the `brokkr-maintenance-os` timer (daily 07:00 on control-node). Reboots are done by hand.
- **Repair interrupted dpkg** on next run (`AutoFixInterruptedDpkg true`).
- **Minimal steps** — upgrade in small increments so a power loss leaves a consistent system.

## Applying changes

Re-run `make patching` after editing these files. Use `make patching ARGS="--dry-run"` to preview.
The script is idempotent — safe to re-run on any or all hosts at any time.

## Runtime coupling

`scripts/setup-host-patching.sh` derives the host list from `grimnir/services.json` at runtime
(via the `REGISTRY_PATH` env var, defaulting to `/opt/grimnir/services.json`).
Grimnir owns the canonical host inventory; Brokkr owns the OS/update operational care.
