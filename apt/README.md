# apt — OS / package update policy

This directory contains the version-controlled apt configuration pushed to the hosts by
`scripts/setup-host-patching.sh` (`make patching`). The policy is owner policy recorded as
Grimnir ADR-009 (regular OS updates, guarded reboots). The script detects each host's OS over
SSH and pushes only the files that fit it.

## Files

| File | Target OS | Path on the host | Purpose |
|------|-----------|------------------|---------|
| `20auto-upgrades` | Debian / Raspberry Pi OS | `/etc/apt/apt.conf.d/20auto-upgrades` | Enables the stock `apt-daily` / `apt-daily-upgrade` timers to refresh package lists and run unattended-upgrades |
| `50unattended-upgrades` | Debian / Raspberry Pi OS | `/etc/apt/apt.conf.d/50unattended-upgrades` | Security baseline: Debian-Security archive only, `Automatic-Reboot "false"` |
| `51brokkr-claude-code` | all | `/etc/apt/apt.conf.d/51brokkr-claude-code` | Adds the Claude Code apt repository to the allowed origins (a drop-in, so it also works beside a distribution's own `50unattended-upgrades`, as on an Ubuntu host) |
| `52brokkr-debian-updates` | Debian / Raspberry Pi OS | `/etc/apt/apt.conf.d/52brokkr-debian-updates` | Regular updates: Debian stable and stable-updates, the Raspberry Pi archive (kernel, firmware, `rpi-eeprom`), Tailscale, `gh` |
| `52brokkr-ubuntu-updates` | Ubuntu | `/etc/apt/apt.conf.d/52brokkr-ubuntu-updates` | Regular updates: Ubuntu `-updates` plus Tailscale, added beside the distribution's own `50unattended-upgrades` (release, `-security`, ESM) |

On an Ubuntu host the distribution's `20auto-upgrades` and `50unattended-upgrades` are never
overwritten. The script only verifies that the host's `20auto-upgrades` enables
`APT::Periodic::Unattended-Upgrade "1"` and fails that host if it does not.

## Policy summary (ADR-009)

- **Security baseline plus regular updates, applied unattended.** `50unattended-upgrades` stays the
  security baseline (`origin=Debian,...-security,label=Debian-Security` on Debian-family hosts; the
  distribution default on Ubuntu). Regular updates are added by drop-ins, because apt appends the
  `Origins-Pattern` entries of every file in `apt.conf.d`:
  - Debian / Raspberry Pi OS (`52brokkr-debian-updates`): Debian `stable` (point releases) and
    `stable-updates`; the Raspberry Pi Foundation archive, which carries the Pi kernel, firmware
    and `rpi-eeprom` and is not part of Debian-Security; Tailscale (a network-exposed daemon);
    `gh` (the GitHub CLI).
  - Ubuntu (`52brokkr-ubuntu-updates`): `-updates` and Tailscale. Not `-backports`, not
    `-proposed`.
  - Claude Code (`51brokkr-claude-code`, all hosts): `origin=Anthropic,label=Anthropic,codename=stable`
    matches the Release Origin and Label (`Anthropic`) and codename (`stable`) that the Claude Code
    apt repository publishes. It lets unattended-upgrades keep an apt-installed `claude-code`
    package current on hosts that have that repository configured. Hosts where `claude` is
    installed another way (npm, the native installer) are updated by the agent CLI updater
    instead, which deliberately leaves apt-owned installs alone (see `../docs/agent-cli-update.md`).
  - A pattern that matches no configured repository is a no-op, so one drop-in serves every host
    of its OS family. Phased updates are honoured; nothing is downgraded.
- **No reboot by unattended-upgrades.** `Automatic-Reboot` stays `"false"` everywhere. A reboot is
  done only by Brokkr's guarded-reboot job (workload, load and session guards, post-boot check,
  audit trail). The daily `brokkr-maintenance-os` report (07:00 on control-node) still detects
  `reboot-required`, or a running kernel older than the newest installed kernel of the same
  flavour, and surfaces it to Munin and Telegram, together with the guarded-reboot audit summary.
- **Firmware.** The Raspberry Pi bootloader EEPROM is updated by apt (`rpi-eeprom`) and applied at
  boot by the stock `rpi-eeprom-update` service, so it takes effect at the next guarded reboot.
  UEFI / BIOS firmware (fwupd) stays report-only.
- **Repair interrupted dpkg** on next run (`AutoFixInterruptedDpkg true`).
- **Minimal steps** — upgrade in small increments so a power loss leaves a consistent system.

## Applying changes

Re-run `make patching` after editing these files. Use `make patching ARGS="--dry-run"` to preview:
it reports each host's detected OS and exactly which files it would push, and changes nothing.
The script is idempotent — safe to re-run on any or all hosts at any time. After each host it
prints the effective "Allowed origins" line from `unattended-upgrade --dry-run -d`; compare it
with the origins above.

A node that is not one of the registry's deploy hosts (for example an Ubuntu inference node) is
patched by naming it explicitly, with `DEPLOY_USER` set to a user that has NOPASSWD sudo there.

## Runtime coupling

`scripts/setup-host-patching.sh` derives the host list from `grimnir/services.json` at runtime
(via the `REGISTRY_PATH` env var, defaulting to `/opt/grimnir/services.json`).
Grimnir owns the canonical host inventory; Brokkr owns the OS/update operational care.
