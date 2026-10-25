# Agent CLI updater

The coding-agent CLIs (`claude`, `codex`, `pi`, `opencode`) ship new releases
several times a week and are installed in several different ways. Left alone,
every workstation and fleet node drifts onto a different version, and a fix
that landed upstream last week is missing on the machine where the problem
shows up. [`scripts/agent-cli-update.sh`](../scripts/agent-cli-update.sh) keeps
them at the latest *settled* release without anyone remembering to do it, and
without guessing how a given copy was installed. A release is only installed
once it has been public for a [cooldown](#release-age-cooldown) (48 hours by
default), so a release that upstream pulls or fixes within a day or two never
reaches the fleet.

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
3. Decide from release metadata whether there is a release that has cleared the
   cooldown (see [Release-age cooldown](#release-age-cooldown)); if not, the
   tool is `current` or `held` and nothing is changed.
4. Otherwise run only that method's own updater (table below), then check that
   `TOOL --version` still exits 0 and prints the version that was approved.
5. Record the result and carry on with the next tool, whatever happened.

| Method | Recognised when the resolved path... | Update | If the smoke check fails |
|---|---|---|---|
| `pi-release` | is below `~/.local/lib/brokkr/agent-cli/pi/` (pi only) | verified download, then an atomic symlink swap ([below](#pi-release-and---adopt-pi)) | symlink put back: `rolled-back` |
| `native` | is below `~/.local/share/claude/versions/` (claude only) | `claude install <stable version>` | `failed`, manual rollback `claude install <previous>` named |
| `brew` | is below `*/Caskroom/<name>/` or `*/Cellar/<name>/` | `brew upgrade --cask <name>` or `brew upgrade <name>` (codex only) | `failed`, no automatic rollback |
| `npm` | contains `/lib/node_modules/` and the package is one allowed for the tool | `npm install -g --prefix <prefix> <package>@<version>` | reinstall the previous version: `rolled-back` |
| `codex-standalone` | is below `~/.codex/packages/standalone/` (codex only) | `codex update`, then verify the version | `failed`, no automatic rollback |
| `opencode-installer` | is below `~/.opencode/` (opencode only) | `opencode upgrade <version>` | `opencode upgrade <previous>`: `rolled-back` |
| `apt` | is owned by a dpkg package (`dpkg-query -S`) | nothing: `external`, left to unattended-upgrades | not applicable |
| anything else | | nothing: `failed`, `unknown install method` | not applicable |

The methods are tried in the order shown (`pi-release` and `native` are only
considered for their own tool), so a node-based Homebrew formula, which keeps
a private `lib/node_modules` inside the Cellar, is treated as Homebrew and npm
never installs into the Cellar.

**npm details.** The prefix is everything before `/lib/node_modules/`, and the
package is the next path component (two when it starts with `@`). The package
must be one of those allowed for the tool, otherwise the tool is `failed` and
nothing is installed:

| Tool | Allowed npm package |
|---|---|
| `claude` | `@anthropic-ai/claude-code` |
| `codex` | `@openai/codex` |
| `pi` | `@earendil-works/pi-coding-agent` (the former `@mariozechner/pi-coding-agent` is `failed`: *legacy package; migrate*) |
| `opencode` | `@opencode/cli` (v2) and `opencode-ai` (the legacy 1.x line, still released under its own name; it keeps updating in place with the detail *legacy 1.x line; v2 is @opencode/cli*, which is not a failure) |

`<prefix>/lib/node_modules` must be writable by the running user; a
root-managed prefix is reported `failed` (*npm prefix not writable*) and never
changed. The installed version comes from the package's `package.json`; the
candidate is the highest plain version in the registry metadata that has
cleared the cooldown. The install pins that exact version.

**Actions.** `absent`, `current`, `updated`, `held`, `external` (apt), `failed`,
and `rolled-back`. A `rolled-back` run counts as a failure: the CLI works
again, but it could not be updated. `held` is not a failure (see below). Under
`--dry-run` an update that would happen is reported as `would-update`.

**Output and exit code.** One line per tool, `tool method before -> after action
[detail]`, then a `summary:` line (with a `held=` count). Exit 0 means every
tool was ok, current, held, absent, external, or the run was deferred; exit 1
means a tool failed or was rolled back (the others are still attempted) or the
state file could not be written; exit 64 is a usage or configuration error.

## Release-age cooldown

A new version is installed only after it has been published for at least
`BROKKR_AGENT_CLI_MIN_AGE_HOURS` hours (an integer from 0 to 720, default
**48**; an invalid value is a usage error, exit 64; `0` disables the age check,
nothing else changes). The decision never rests on what a vendor updater would
fetch on its own: it comes from release metadata, read with
`curl -fsSL --proto =https --max-time 60` and a small JSON reader that uses
`python3 -I` when present and `node` otherwise (the metadata goes in on stdin,
never into code). A host with neither cannot judge a release's age, so its
tools are `held` rather than updated blind.

| Source | URL | Used for |
|---|---|---|
| npm registry | `$BROKKR_NPM_REGISTRY/<package>` (default `https://registry.npmjs.org`; scoped names as `@scope%2fname`) | npm installs, native `claude`, the opencode installer: the `time` map and `dist-tags` |
| GitHub releases | `$BROKKR_GITHUB_API/repos/<owner>/<repo>/releases?per_page=50` (default `https://api.github.com`) | `codex` (standalone and Homebrew), `pi`: `tag_name` and `published_at`; drafts and prereleases are ignored |
| GitHub downloads | `$BROKKR_GITHUB_DOWNLOAD/<owner>/<repo>/releases/download/<tag>/...` (default `https://github.com`) | the `pi` archive and its `SHA256SUMS` |

To change the cooldown on a node, give the service the variable in a drop-in
(`systemctl --user edit brokkr-agent-cli-update.service` with
`Environment=BROKKR_AGENT_CLI_MIN_AGE_HOURS=72`); on the Mac add it to the
LaunchAgent's `EnvironmentVariables`. By hand: `BROKKR_AGENT_CLI_MIN_AGE_HOURS=0
make agent-cli-update ARGS="--dry-run"`. The three base URLs must be `https://`
(they exist so tests never touch the network), and `BROKKR_NOW_EPOCH` (epoch
seconds) replaces the clock, also for tests. Only plain `MAJOR.MINOR.PATCH` versions are ever candidates: anything
with a `-` or `+` suffix is ignored, and versions compare numerically per
component (`1.10.0` is newer than `1.9.0`).

**`held`** means a newer version exists but the tool was left alone, and the
run still ends `ok`. The detail says why: either every newer version is
younger than the cooldown (*newer release 1.3.0 is only 5h old, below the 48h
release-age cooldown*; the highest newer version is named) or the age could not
be evaluated (*cannot evaluate release age (...)*: the metadata could not be
fetched or parsed, no stable version is published, or neither python3 nor node
exists). The next scheduled run tries again. If nothing newer exists at all the
tool is `current`, not `held`.

How each method is gated:

| Method | Target version | `current` when | Held when | Update and check |
|---|---|---|---|---|
| `npm` | highest stable version in the registry `time` map that has cleared the cooldown and is newer than the installed one | no newer version exists | every newer version is too young | `npm install -g --prefix <prefix> <pkg>@<version>` |
| `native` (claude) | `dist-tags.stable` of `@anthropic-ai/claude-code` | target is not newer than installed | target too young, or no `stable` tag / publish time | `claude install <target>`; `claude --version` must equal the target, else `failed` naming `claude install <before>` as the manual rollback |
| `brew` (codex) | the version Homebrew offers (`brew info --json=v2`), aged by the GitHub release `rust-v<target>` of `openai/codex` | target equals installed (no GitHub lookup) | target too young or has no GitHub release | the existing `brew upgrade [--cask] codex`; the version afterwards must equal the target, else `failed` |
| `brew` (anything else) | none | | always: *release age unknown for Homebrew package <name>* (fails closed; with the cooldown at 0 the plain `brew upgrade` runs) | |
| `codex-standalone` | the most recently published stable `rust-v<version>` release of `openai/codex` (what `codex update` installs) | target is not newer than installed | target too young | `codex update`, which cannot pin a version, so the gate comes first and the result is verified: `codex --version` must equal the target, else `failed` (*codex update installed X, expected Y*) |
| `opencode-installer` | highest stable version that has cleared the cooldown from `@opencode/cli` when the installed major is 2 or more, else from `opencode-ai` | no newer version exists | every newer version is too young | `opencode upgrade <version>`; the version afterwards must equal it, else `opencode upgrade <before>` and `rolled-back` |
| `pi-release` | highest stable `v<version>` release of `earendil-works/pi` that has cleared the cooldown | no newer version exists | every newer version is too young | verified download and symlink swap (below) |
| `apt` | not touched | | | `external` |

## pi-release and `--adopt pi`

`pi` has a second, preferred install method: the release tarball from GitHub,
unpacked under a version directory and reached through a symlink.

```
~/.local/lib/brokkr/agent-cli/pi/<version>/pi/pi    # the release's top-level pi/ directory, per version
~/.local/bin/pi                                     # symlink to the version in use
```

A copy whose resolved path is below `~/.local/lib/brokkr/agent-cli/pi/` is
`pi-release`; the installed version is the `<version>` path component (it must
be plain semver). An update does the following, and stops at the first problem
with nothing changed:

1. Pick the highest stable release `v<version>` that is newer than the installed
   one and has cleared the cooldown.
2. Map the platform (`uname -s`, `uname -m`): Darwin `arm64` to `darwin-arm64`,
   Darwin `x86_64` to `darwin-x64`, Linux `x86_64` to `linux-x64`, Linux
   `aarch64`/`arm64` to `linux-arm64`. Anything else is `failed`.
3. In a private stage directory (`~/.local/lib/brokkr/agent-cli/pi/.stage.XXXXXX`, mode 0700) download
   `pi-<platform>.tar.gz` and `SHA256SUMS`. `SHA256SUMS` must name exactly that
   asset once with a 64-digit SHA-256, and the archive must match it
   (`sha256sum`, else `shasum -a 256`, else `failed`).
4. List the archive before extracting it: every entry must start with `pi/`,
   none may be absolute or contain `..`, and every entry must be a regular
   file or directory (symlinks, hardlinks and devices are refused).
5. Extract into the stage, require an executable `pi/pi` that reports the
   release's version, and move the stage to `<version>/`. A `<version>/`
   directory that already exists is reused only if its `pi` reports that
   version.
6. Swap `~/.local/bin/pi` by creating a temporary symlink beside it and
   renaming it over `pi`, then run `pi --version`. If it does not report the
   new version the symlink is pointed back at the previous target:
   `rolled-back`.
7. Keep the three newest version directories (plus the current and previous
   targets); directories that are not plain versions are never touched.

The stage directory is removed however the run ends, including on a signal.
Going back by hand is `ln -sfn ~/.local/lib/brokkr/agent-cli/pi/<old>/pi/pi ~/.local/bin/pi`.

**Migrating a host from npm.** `--adopt pi` installs the cooldown-selected
release even when `pi` is absent or comes from elsewhere. It refuses
(`failed`, nothing changed) when `~/.local/bin/pi` exists and is not a symlink
into the pi-release tree, because two installs must not fight over the name.
So uninstall the npm copy first, then adopt:

```sh
npm uninstall -g --prefix <prefix> @earendil-works/pi-coding-agent   # the refusal prints this line for the prefix it found
scripts/agent-cli-update.sh --dry-run --adopt pi    # shows what would be installed; downloads no archive
scripts/agent-cli-update.sh --adopt pi              # installs it, creating ~/.local/bin if needed
```

`--adopt pi` on its own touches only `pi` (`--tool` can name it explicitly;
selecting tools without `pi` is a usage error). The busy guard applies to it
as to any run. If, once it succeeded, `command -v pi` still resolves to some
other binary, the detail carries a warning naming what shadows the new link
(not a failure): remove that copy or put `~/.local/bin` first on `PATH`. Once
a host is adopted, scheduled runs treat `pi` as `pi-release` with no flag.

## Built-in self-updaters

A CLI's own auto-updater bypasses this cooldown: it fetches and installs
whatever is newest, on its own schedule, with no regard for release age. A host
that relies on the cooldown must therefore pin or disable those updaters so
that this script is the only thing that moves a version. Set, per tool:

- claude: `TODO(conductor): exact key`
- codex: `TODO(conductor): exact key`
- pi: `TODO(conductor): exact key`
- opencode: `TODO(conductor): exact key`

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

The installer copies the updater as committed at the checkout's `HEAD` into
`~/.local/lib/brokkr/agent-cli-update/releases/<full-sha>/scripts/`, renders the
plist into `~/Library/LaunchAgents/` pointing at that copy, `bootout`s any loaded
copy and `bootstrap`s the new one. It refuses when the checkout's updater has
uncommitted changes, so the release is exactly the named revision; later branch
switches or a removed worktree do not change what the agent runs. The agent's PATH is
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
- **The cooldown is a delay, not a scan.** It trusts the publish time that the
  npm registry or GitHub reports and does nothing about a release that is bad
  from the start and stays up; it buys time for upstream to notice and pull one.
- **A host needs `python3` or `node` to judge release age** (macOS ships
  `python3` in `/usr/bin`). Without either, every tool that needs a lookup is
  `held`; the script never falls back to updating blind.
- **`codex update` and Homebrew are verified, not pinned.** Neither can be told
  which version to install, so the gate runs first and the result is checked
  afterwards. If a newer release appears in the minutes between the two, the
  tool stays on it and is reported `failed` (*installed X, expected Y*); there
  is no automatic rollback for these methods.
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
- **The Mac agent runs a revision-bound copy**, not the checkout. Re-run
  `make agent-cli-update-install` from an updated checkout to move it to a newer
  revision; old release directories are left in place for rollback.
