# launchd — LaunchAgents that run on the Mac

Brokkr's substrate spans hosts. Most timers run on the Pis under **systemd** (`../systemd/`).
The bits that must run on the **laptop** — because that's where the data or a macOS-only tool
lives — run under **launchd** instead. This dir holds those, version-controlled.

| Agent | What it does | Schedule |
|-------|--------------|----------|
| `io.grimnir.brokkr.offsite-photos.plist` | Encrypted offsite backup of the Photos originals to the cloud crypt remote (`scripts/offsite-photos-backup.sh`). See `../docs/offsite-photos-backup.md`. | Daily 04:15 local |
| `io.grimnir.brokkr.agent-cli-update.plist` | Keeps the claude, codex, pi and opencode CLIs at their latest release, each through its own install method (`scripts/agent-cli-update.sh`). Installed with `install-agent-cli-update.sh`. See `../docs/agent-cli-update.md`. | 04:17, 10:17, 16:17, 22:17 local |

## Why LaunchAgent, not LaunchDaemon

A **LaunchAgent** (`~/Library/LaunchAgents`, per-user GUI session) — not a **LaunchDaemon**
(`/Library/LaunchDaemons`, system, root) — because the job reads the user's Photos library,
the user's rclone config/keychain, and needs the user's network session. It should run as
that workstation user, not as root.

## Apply

The plist ships with `__BROKKR_DIR__` / `__HOME__` placeholders (so the repo carries no
machine-specific absolute paths). `install.sh` renders them and manages the agent:

```bash
./launchd/install.sh            # render → ~/Library/LaunchAgents, bootstrap + enable
./launchd/install.sh run        # ...and kick a run right now
./launchd/install.sh status     # is it loaded? last exit code?
./launchd/install.sh uninstall  # bootout + remove
```

`install.sh` uses the modern `launchctl bootstrap`/`bootout gui/$(id -u)` API (not the
deprecated `load -w`), and `bootout`s before re-`bootstrap`ing so a re-run always picks up
plist edits.

The agent CLI updater has its own installer with the same commands
(`./launchd/install-agent-cli-update.sh [install|run|status|uninstall]`; or
`make agent-cli-update-install`). `run` starts an update without `-k`, so an update that is
already running is not killed halfway through an install.

## Notes

- **`RunAtLoad` is false** — installing/reloading the agent must not start a large upload on
  the spot. It waits for the next 04:15, or an explicit `install.sh run` /
  `launchctl kickstart -k gui/$(id -u)/io.grimnir.brokkr.offsite-photos`.
- **PATH** is set in the plist (`/opt/homebrew/bin:/usr/local/bin:…`) because launchd hands
  agents a minimal PATH and the script calls `rclone` by name.
- Logs: the script's own log is `~/Library/Logs/brokkr/offsite-photos-backup.log`; launchd's
  captured stdout/stderr is `~/Library/Logs/brokkr/offsite-photos.launchd.log`.
- Secrets (the Heimdall token) are **not** in the plist — the script sources them from
  `~/.config/brokkr/offsite-photos.env` if present. See the doc's setup step 5.
- The agent-cli-update agent has **no secrets** and `RunAtLoad` false. Its PATH puts the per-user
  install locations (`~/.local/bin`, `~/.opencode/bin`) before Homebrew, and its log is
  `~/Library/Logs/brokkr/agent-cli-update.launchd.log`; the machine-readable result is
  `~/.local/state/brokkr/agent-cli-update.json`.
- The offsite-photos agent runs from this repo checkout (`__BROKKR_DIR__`), so a moved checkout
  or one left on an unfinished branch changes what it runs; re-run the installer after moving it.
  The agent-cli-update agent instead runs a copy of the updater bound to the checkout's `HEAD`
  (`~/.local/lib/brokkr/agent-cli-update/releases/<full-sha>/`, plist placeholder
  `__RELEASE__`); its installer refuses an uncommitted updater.
