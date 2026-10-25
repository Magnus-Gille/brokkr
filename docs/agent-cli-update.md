# Agent CLI updater

The coding-agent CLIs (`claude`, `codex`, `pi`, `opencode`) ship new releases
several times a week and are installed in several different ways. Left alone,
every workstation and fleet node drifts onto a different version, and a fix
that landed upstream last week is missing on the machine where the problem
shows up. [`scripts/agent-cli-update.sh`](../scripts/agent-cli-update.sh) keeps
them at the latest release without anyone remembering to do it, and without
guessing how a given copy was installed.

It runs on the host itself, unattended:

- **macOS workstation:** a launchd LaunchAgent
  ([`launchd/io.grimnir.brokkr.agent-cli-update.plist`](../launchd/io.grimnir.brokkr.agent-cli-update.plist)).
- **Linux fleet nodes:** a systemd **user** timer installed as a revision-bound
  release by [`scripts/deploy-agent-cli-update.sh`](../scripts/deploy-agent-cli-update.sh),
  the same way as the [link-health probe](link-health.md).

## What one run does

For each tool in `claude codex pi opencode` (override with
`BROKKR_AGENT_CLI_TOOLS` or a repeatable `--tool NAME`; an unknown name is a
usage error):

1. Find the tool on `PATH`. If it is absent the action is `absent`: the updater
   never installs a tool that is not already there.
2. Resolve the binary to its real path and classify the install method from it.
3. Run only that method's own updater (table below), then check that
   `TOOL --version` still exits 0 and prints a `MAJOR.MINOR.PATCH` version.
4. Record the result and carry on with the next tool, whatever happened.

| Method | Recognised when the resolved path... | Update | If the smoke check fails |
|---|---|---|---|
| `native` | is below `~/.local/share/claude/versions/` (claude only) | `claude update` | `failed`, no automatic rollback |
| `npm` | contains `/lib/node_modules/` and the package is the one allowed for the tool | `npm install -g --prefix <prefix> <package>@<latest>` | reinstall the previous version: `rolled-back` |
| `brew` | is below `*/Caskroom/<name>/` or `*/Cellar/<name>/` | `brew upgrade --cask <name>` or `brew upgrade <name>` | `failed`, no automatic rollback |
| `codex-standalone` | is below `~/.codex/packages/standalone/` (codex only) | `codex update` | `failed`, no automatic rollback |
| `opencode-installer` | is below `~/.opencode/` (opencode only) | `opencode upgrade` | `opencode upgrade <previous>`: `rolled-back` |
| `apt` | is owned by a dpkg package (`dpkg-query -S`) | nothing: `external`, left to unattended-upgrades | not applicable |
| anything else | | nothing: `failed`, `unknown install method` | not applicable |

The methods are tried in the order shown, so a copy installed by npm into a
Homebrew prefix is treated as npm.

**npm details.** The prefix is everything before `/lib/node_modules/`, and the
package is the next path component (two when it starts with `@`). The package
must be exactly the one allowed for the tool, otherwise the tool is `failed`
and nothing is installed:

| Tool | Allowed npm package |
|---|---|
| `claude` | `@anthropic-ai/claude-code` |
| `codex` | `@openai/codex` |
| `pi` | `@earendil-works/pi-coding-agent` (the former `@mariozechner/pi-coding-agent` is `failed`: *legacy package; migrate*) |
| `opencode` | `opencode-ai` |

`<prefix>/lib/node_modules` must be writable by the running user; a
root-managed prefix is reported `failed` (*npm prefix not writable*) and never
changed. The installed version comes from the package's `package.json`, the
latest from `npm view <package> version`; equal means `current`. The install
pins the exact version that was just looked up.

**Actions.** `absent`, `current`, `updated`, `external` (apt), `failed`, and
`rolled-back`. A `rolled-back` run counts as a failure: the CLI works again,
but it could not be updated. Under `--dry-run` an update that would happen is
reported as `would-update`.

**Output and exit code.** One line per tool, `tool method before -> after action
[detail]`, then a `summary:` line. Exit 0 means every tool was ok, current,
absent, external, or the run was deferred; exit 1 means a tool failed or was
rolled back (the others are still attempted) or the state file could not be
written; exit 64 is a usage or configuration error.

## Busy guard

Replacing a CLI underneath a running agent task is the one thing this updater
must not do. On a node where a service launches agent tasks, name that service
in `BROKKR_AGENT_CLI_BUSY_UNITS` (space-separated systemd user units, for
example `hugin.service`; empty by default). Before any tool work, for each
listed unit that is `active`, the updater counts the PIDs in the unit's control
group (every `cgroup.procs` below it). The service's own main process is one
PID; more than one means it has spawned work, and the **whole run is deferred**:
nothing is touched, the reason is logged, and the exit code is 0. The next
timer firing tries again.

The guard fails closed. If `systemctl --user` cannot answer, the control group
is empty or outside the cgroup root, or the cgroup cannot be read, the run is
deferred and says why. Unit names must match `^[A-Za-z0-9@_.][A-Za-z0-9@._-]*\.service$`
(an invalid name is a usage error, exit 64). `BROKKR_CGROUP_ROOT` (default
`/sys/fs/cgroup`) exists for tests. The guard needs systemd, so it is for the
Linux nodes; the Mac agent leaves the list empty.

## Schedule

Four times a day: 04:17, 10:17, 16:17 and 22:17 local time.

- **systemd:** `OnCalendar=*-*-* 04,10,16,22:17:00`, `RandomizedDelaySec=20min`
  (so a fleet does not hit the registry in the same minute) and
  `Persistent=true` (a firing missed while the node was off runs at the next
  boot). The service runs at `Nice=10`, idle I/O class, with `NoNewPrivileges`
  and `PrivateTmp`. It sets no `ProtectHome`/`ProtectSystem`, because it has to
  write `~/.local`, `~/.npm`, `~/.codex` and `~/.opencode`.
- **launchd:** four `StartCalendarInterval` entries, `RunAtLoad` false, low
  priority. launchd runs one missed firing when the Mac wakes.

## Install on the Mac

```sh
make agent-cli-update-install            # or ./launchd/install-agent-cli-update.sh
./launchd/install-agent-cli-update.sh status
./launchd/install-agent-cli-update.sh run        # start an update now
./launchd/install-agent-cli-update.sh uninstall
```

The installer renders the plist into `~/Library/LaunchAgents/`, `bootout`s any
loaded copy and `bootstrap`s the new one. The agent's PATH is
`~/.local/bin:~/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
launchd's own output goes to `~/Library/Logs/brokkr/agent-cli-update.launchd.log`.
To try the updater by hand without changing anything:
`make agent-cli-update ARGS="--dry-run"`.

## Deploy to a Linux node

The node needs a non-root login user with lingering enabled
(`loginctl enable-linger`). `npm` and `node` should resolve from
`/usr/local/bin:/usr/bin:/bin` or `~/.local/bin`; if they do not, the preflight
warns (it does not refuse) and any npm-managed CLI will be reported `failed`.

```sh
# Dry-run (default): remote preflight only, nothing is changed.
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT="<full-40-char-sha>" \
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service \
  scripts/deploy-agent-cli-update.sh operator@node-a.example

# Install: same environment plus --apply.
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT="<full-40-char-sha>" \
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service \
  scripts/deploy-agent-cli-update.sh --apply operator@node-a.example
```

`BROKKR_EXPECTED_COMMIT` must be the full SHA of the clean checkout at
`BROKKR_EXPECTED_SOURCE`; the payload is the committed archive of that revision,
never the working tree, and only the updater and the two unit templates are
shipped. `BROKKR_AGENT_CLI_BUSY_UNITS` is optional and validated locally before
anything reaches ssh.

The remote preflight (also run by the dry-run) refuses unless the user is not
root, lingering is enabled, the release for that SHA does not yet exist, and no
unit backup for it exists. `--apply` stages the payload, checks its file count
and types and that the updater parses under the node's `bash`, moves it to
`~/.local/lib/brokkr/agent-cli-update/releases/<SHA>`, saves any existing units
as `<unit>.previous-<SHA>` (both backups exist before either unit is replaced),
renders the units into `${XDG_CONFIG_HOME:-~/.config}/systemd/user/`, runs
`systemctl --user daemon-reload` and `enable --now brokkr-agent-cli-update.timer`,
then starts the service once and prints its result, the updater's own result
and the last log line. A first run that exits non-zero (a tool failed or was
rolled back) or that leaves no freshly written state file exits the deploy
non-zero with the rollback recipe, but the release, units and timer stay
installed; the usual cause is one tool on the node that needs attention, not a
broken install.

## Verify

```sh
systemctl --user list-timers brokkr-agent-cli-update.timer
journalctl --user -u brokkr-agent-cli-update -n 50 --no-pager
cat ~/.local/state/brokkr/agent-cli-update.json
```

The state file (`${BROKKR_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/brokkr}/agent-cli-update.json`,
mode 0600) is written atomically after every real run, including a deferred
one, and never by `--dry-run`:

```json
{
  "timestamp": "2026-01-01T04:20:11Z",
  "hostname": "node-a",
  "result": "ok",
  "detail": "",
  "tools": [
    {"name": "claude", "method": "npm", "path": "/home/operator/.local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "before": "2.0.0", "after": "2.0.1", "action": "updated", "detail": ""},
    {"name": "pi", "method": "", "path": "", "before": "", "after": "", "action": "absent", "detail": ""}
  ]
}
```

`result` is `ok`, `deferred` (with the reason in `detail`) or `failed`. To
exercise a node without changing it, run the installed release with
`--dry-run`:
`~/.local/lib/brokkr/agent-cli-update/releases/<SHA>/scripts/agent-cli-update.sh --dry-run`.

## Roll back

The deploy prints the exact rollback for the node. In outline, as the runtime
user: `systemctl --user disable --now brokkr-agent-cli-update.timer`, stop the
service, move each `<unit>.previous-<SHA>` back (or delete the unit if there was
none), `systemctl --user daemon-reload`, and optionally remove the release
directory. Rolling back the install does **not** downgrade CLIs the updater
already upgraded; reinstall a specific version by hand if you need one, for
example `npm install -g --prefix <prefix> <package>@<version>`. On the Mac,
`./launchd/install-agent-cli-update.sh uninstall` removes the agent.

## Limitations

- **No Heimdall panel yet.** Results live in the state file, the journal and
  the launchd log; nothing reports a stale or failed updater to the dashboard.
- **apt-managed `claude` is not updated here.** It is reported `external`. The
  Claude Code apt repository is allowed in
  [`apt/50unattended-upgrades`](../apt/50unattended-upgrades), so
  unattended-upgrades keeps an apt-installed `claude-code` current on hosts
  that have that repository configured.
- **Upgrades happen in place.** A process that is already running keeps the old
  binary until it is restarted; the updater never restarts anything. The busy
  guard only protects the units it is told about, so an agent started by hand
  on a node is not seen.
- **Only tools on the unit's PATH are seen.** The systemd unit uses
  `~/.local/bin:~/.opencode/bin:/usr/local/bin:/usr/bin:/bin`, so a CLI that is
  only reachable through a shell profile (for example an nvm-managed Node) is
  reported `absent`.
- **Root-managed and unrecognised installs are reported, not fixed.** They make
  the run exit 1 until someone migrates them (for example from a system-wide
  npm prefix to a per-user one).
- **A unit that is `active` but has no control group** (for example a
  `RemainAfterExit` oneshot) defers every run. Name only long-running services.
- **Overlapping runs are not serialised.** A manual run during a timer firing
  can collide; the services are oneshot, so the timer itself never overlaps.
- **The Mac agent runs from the repo checkout**, like the offsite-photos agent.
  Moving the checkout or leaving it on an unfinished branch changes what runs;
  re-run `make agent-cli-update-install` after moving it.
