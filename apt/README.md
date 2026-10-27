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
| `52brokkr-debian-updates` | Debian / Raspberry Pi OS | `/etc/apt/apt.conf.d/52brokkr-debian-updates` | Regular updates: Debian stable and stable-updates, the Raspberry Pi archive (kernel, firmware, `rpi-eeprom`), `gh` (stable channel) |
| `52brokkr-ubuntu-updates` | Ubuntu | `/etc/apt/apt.conf.d/52brokkr-ubuntu-updates` | Regular updates: Ubuntu `-updates` plus Tailscale (its release-codename channel), added beside the distribution's own `50unattended-upgrades` (release, `-security`, ESM) |

On an Ubuntu host the distribution's `20auto-upgrades` and `50unattended-upgrades` are never
overwritten. The script only verifies that the host's `20auto-upgrades` enables
`APT::Periodic::Unattended-Upgrade "1"` and fails that host if it does not.

The two `52brokkr-*` regular-update drop-ins are **not** pushed by OS family alone. ADR-009
approves regular updates on named hosts only, so the script pushes a `52brokkr-*` drop-in only to
hosts listed in `BROKKR_REGULAR_UPDATE_HOSTS` (see "Applying changes"). Every other host gets its
security baseline only (Debian-family: `20`, `50`, `51`; Ubuntu: `51` beside the distribution's own
files), and a `52brokkr-*` drop-in already present there is removed and reported.

## Policy summary (ADR-009)

- **Security baseline plus regular updates, applied unattended.** `50unattended-upgrades` stays the
  security baseline (`origin=Debian,...-security,label=Debian-Security` on Debian-family hosts; the
  distribution default on Ubuntu). Regular updates are added by drop-ins, because apt appends the
  `Origins-Pattern` entries of every file in `apt.conf.d`:
  - Debian / Raspberry Pi OS (`52brokkr-debian-updates`): Debian `stable` (point releases) and
    `stable-updates`; the Raspberry Pi Foundation archive, which carries the Pi kernel, firmware
    and `rpi-eeprom` and is not part of Debian-Security; `gh` (the GitHub CLI, channel
    `stable`). Debian-family hosts have no Tailscale apt repository, so none is admitted there.
  - Ubuntu (`52brokkr-ubuntu-updates`): `-updates`, and Tailscale (a network-exposed daemon) from
    its release-codename channel (`codename=${distro_codename}`). Not `-backports`, not
    `-proposed`.
  - Claude Code (`51brokkr-claude-code`, all hosts): `origin=Anthropic,label=Anthropic,codename=stable`
    matches the Release Origin and Label (`Anthropic`) and codename (`stable`) that the Claude Code
    apt repository publishes. It lets unattended-upgrades keep an apt-installed `claude-code`
    package current on hosts that have that repository configured. Hosts where `claude` is
    installed another way (npm, the native installer) are updated by the agent CLI updater
    instead, which deliberately leaves apt-owned installs alone (see `../docs/agent-cli-update.md`).
  - Every vendor repository is matched by exact origin, label and codename / channel; an unlisted
    channel is never admitted. A pattern that matches no configured repository is a no-op, so one
    drop-in serves every approved host of its OS family. Phased updates are honoured; nothing is
    downgraded.
- **No reboot by unattended-upgrades.** `Automatic-Reboot` stays `"false"` everywhere. A reboot is
  done only by Brokkr's guarded-reboot job (workload, load and session guards, post-boot check,
  audit trail). The daily `brokkr-maintenance-os` report (07:00 on control-node) still detects
  `reboot-required`, or a running kernel older than the newest installed kernel of the same
  flavour (version part = longest prefix matching `^[0-9]+(\.[0-9]+)*(\+[a-z0-9]+)?(-[0-9]+)?`,
  flavour = what follows the next `-`, so `rt-amd64` never counts for `amd64` and `rpi-2712` never
  for `rpi-v8`), and surfaces it to Munin and Telegram, together with the guarded-reboot audit
  summary. A node that is only recorded in Munin when unreachable can be made to alert like a
  deploy-tier host by listing its ID in `BROKKR_ALERT_UNREACHABLE_NODES` in the report's runtime
  environment (see the header of `../scripts/maintenance-report.sh`); ADR-009 relies on this for
  the inference node, which the guarded-reboot job may have rebooted.
- **Previous kernel.** apt's kernel autoremove protection keeps the running kernel, the newest
  and the one before it, so after a guarded reboot the previous kernel stays installed for manual
  boot selection (the mitigation ADR-009 relies on). Checked on both host types with
  `apt-get -s autoremove`: no kernel would be removed with two kernels installed.
  `Remove-Unused-Kernel-Packages` is left as is.
- **Firmware.** apt installs the updated Raspberry Pi bootloader package (`rpi-eeprom`). The stock
  boot-time `rpi-eeprom-update` service is disabled by the guarded-reboot deploy; the guarded-reboot
  job stages the update (`rpi-eeprom-update -a`) only inside an admitted reboot, and the bootloader
  writes it during that reboot (see `../docs/guarded-reboot.md`). UEFI / BIOS firmware (fwupd)
  stays report-only.
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

**Approved hosts.** `BROKKR_REGULAR_UPDATE_HOSTS` is a whitespace-separated list of the hosts
approved for regular updates. It is empty by default and is read from the operator's runtime
environment; real host IDs are never committed to this repository. An ID matches the host as given
on the command line or in the registry, the same without `.local`, or its short name. IDs may use
letters, digits, dot, underscore and hyphen only; any other entry aborts the run with exit 2 before
a host is touched (a typo must not silently strip regular updates from an approved host). The run
reports the decision per host ("regular updates: enabled" or "not enabled"), `--dry-run` shows it
too (including a stale drop-in it would remove), and the per-host summary line repeats it.

## Runtime coupling

`scripts/setup-host-patching.sh` derives the host list from `grimnir/services.json` at runtime
(via the `REGISTRY_PATH` env var, defaulting to `/opt/grimnir/services.json`).
Grimnir owns the canonical host inventory; Brokkr owns the OS/update operational care.
