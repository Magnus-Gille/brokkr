# launchd — LaunchAgents that run on the Mac

Brokkr's substrate spans hosts. Most timers run on the Pis under **systemd** (`../systemd/`).
The bits that must run on the **laptop** — because that's where the data or a macOS-only tool
lives — run under **launchd** instead. This dir holds those, version-controlled.

| Agent | What it does | Schedule |
|-------|--------------|----------|
| `io.grimnir.brokkr.offsite-photos.plist` | Encrypted offsite backup of the Photos originals to the cloud crypt remote (`scripts/offsite-photos-backup.sh`). See `../docs/offsite-photos-backup.md`. | Daily 04:15 local |

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
