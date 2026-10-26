# Guarded reboot

Grimnir ADR-009 ("Host OS updates and guarded reboots") lets the hosts take regular
operating-system updates and Raspberry Pi bootloader firmware automatically, with one
deterministic job that reboots only when it is safe. Updates alone leave a gap between
"installed" and "running": a host can run a kernel weeks older than the patched one on its disk.
[`scripts/guarded-reboot.sh`](../scripts/guarded-reboot.sh) closes that gap. It runs on the host
as the operator user, from systemd **user** timers installed by
[`scripts/deploy-guarded-reboot.sh`](../scripts/deploy-guarded-reboot.sh) as a revision-bound
release (the same way as the [agent CLI updater](agent-cli-update.md) and the
[link-health probe](link-health.md)).

No model or agent decides anything in this path, no controller is armed, and no ADR-008 row
changes: the job is owner host policy implemented as reviewed code. It may not widen the policy
(new origins, firmware mechanisms, hosts or reboot conditions need the owner). The package
origins and the unattended-upgrades drop-ins are a separate part of the same ADR, see
[`../apt/README.md`](../apt/README.md).

| Unit | When | Command |
|---|---|---|
| `brokkr-guarded-reboot.timer` | nightly, at the per-host window plus a random spread | `guarded-reboot.sh check` |
| `brokkr-post-boot-check.timer` | once, ten minutes after the machine boots | `guarded-reboot.sh post-boot` |
| `brokkr-post-update-health.timer` | daily at 08:00, after the stock apt-daily-upgrade window | `guarded-reboot.sh health` |

Besides those, `guarded-reboot.sh status` prints the state and `guarded-reboot.sh clear-latch` is
the owner's action to re-allow automatic reboots after a [latch](#latch-and-the-post-boot-check).
The job is Linux-only and refuses to run anywhere else.

## Triggers

The nightly check looks for three triggers. Each has an **id** (used in state, audit and
messages) and an **identity** that says which pending thing it is, so "the same trigger survived
the reboot" is told apart from "a new one arrived":

| Id | Fires when | Identity |
|---|---|---|
| `reboot-required` | the reboot-required flag file exists (the `.pkgs` names are in the audit detail, bounded) | sha256 of the sorted `.pkgs` content, or `mtime-<epoch>` of the flag file when there is no `.pkgs` |
| `kernel` | the newest installed kernel of the running flavour is newer than the running one | that newest kernel's version |
| `eeprom` | `rpi-eeprom-update` reports a bootloader newer than the running one | the available bootloader version (a timestamp) |

No trigger means action `none`: the state is written, and the audit file only gets a line when the
last recorded action was something else.

**Kernel flavour.** The version part of a kernel release is the longest prefix matching
`^[0-9]+(\.[0-9]+)*(\+[a-z0-9]+)?(-[0-9]+)?`; the flavour is everything after the `-` that follows
that prefix. `7.0.0-38-generic` is `generic`, `6.12.48+deb13-amd64` is `amd64`,
`6.12.48+deb13-rt-amd64` is `rt-amd64`, `6.18.50+rpt-rpi-2712` is `rpi-2712` (the `rpi-v8` kernel
beside it is another flavour). Candidates are the installed `vmlinuz-*` files in the boot
directory whose own flavour (same rule) equals the running flavour exactly; the highest by
`sort -V` is compared with the running kernel. A running kernel that is *newer* than every
installed one is a note, never a trigger (the job does not "upgrade" into an older kernel).
needrestart's kernel status is deliberately not used: on a Raspberry Pi 5 it compares the 2712 and
v8 flavours and is permanently wrong. The maintenance report applies the same rule.

**EEPROM status** comes from `sudo -n rpi-eeprom-update -j -m /run/brokkr-guarded-reboot-eeprom.json`
(a constant argument: only root can write below `/run`), which writes
`{"EXITCODE", "BOOTLOADER_CURRENT", "BOOTLOADER_LATEST", ...}` as JSON. The job reads that file
unprivileged afterwards with `python3 -I` (or `node`) from stdin; nothing is scraped from the text
output and stdin is closed so the tool's "install now?" prompt can never be offered. Because the
path is fixed, a file left by an earlier run must not pass for this run's answer: it has to be
fresh (written within the last minute by the real clock) and agree with the command's own exit
status (0 is `EXIT_SUCCESS`, 1 is `EXIT_UPDATE_REQUIRED`). A latest version newer than the current
one is the trigger; an unreadable, stale or contradictory answer, `EXIT_FAILED`, or an unknown
running version is recorded as "eeprom status unknown" in the detail and is not a trigger. A host
without `rpi-eeprom-update` skips every EEPROM step.

## Guards

Any one guard defers the reboot to the next night; every guard that applies is recorded by id, in
this order. A guard that cannot be evaluated counts as applying (fail closed).

| Id | Applies when |
|---|---|
| `kill-switch` | the kill-switch file exists (intentional: ends the evaluation, never counts as a deferral, never escalates) |
| `latched` | automatic reboots are [latched](#latch-and-the-post-boot-check) off |
| `attempt-pending` | the last reboot attempt is under two hours old and has no post-boot result yet |
| `eeprom-stray` | a staged bootloader update was found with no attempt behind it and could not be cancelled (or this is a `--report-only` run, which may not cancel): the next boot would flash it. Persists until a later run cancels it |
| `apt-busy` | a process named exactly `dpkg`, `apt`, `apt-get` or `unattended-upgr` runs (`pgrep -x`: PIDs only, argv is never read), or `apt-daily.service` / `apt-daily-upgrade.service` is active, activating, reloading, deactivating or refreshing |
| `busy:<unit>` | a configured busy unit (`BROKKR_GUARDED_REBOOT_BUSY_UNITS`) is active with spawned work: more than one PID across its cgroup, with the transitional states inspected like active and an empty or unreadable state deferring |
| `load` | the 5-minute load average is above the maximum (default 0.75 x CPUs) |
| `tty` | an interactive login was used within the last 60 minutes (`who -u`: idle `.` is active now, `HH:MM` is the idle time, `old` and `?` are ignored; a row that cannot be parsed defers) |
| `peer:<name>` | a configured peer (`BROKKR_GUARDED_REBOOT_PEERS`) does not accept a TCP connection on port 22 within 5 seconds (bash `/dev/tcp` under `timeout`) |
| `unlock` | a crypttab entry needed at boot (not `noauto`) does not unlock unattended: defers **and alerts** (an unattended reboot would hang at a prompt). An entry counts as unattended **only** if its key field is a key-file path, or its options contain `tpm2-device=` without `tpm2-pin=yes`. `fido2-device=`, `pkcs11-uri=`, `keyscript=`, any `*-pin=yes`, any `fido2-with-*`, `headless=false`, and an empty, `none` or `-` key without tpm2 are interactive (and outweigh a key-file path). Every such entry counts, not only the root volume |
| `notify` | reboot mode only: the pre-reboot notice could not be delivered (see [the sequence](#the-reboot-sequence)) |
| `eeprom-stage` | reboot mode only: the EEPROM update could not be staged |

Guards are evaluated only when a trigger exists. The peer guard keeps a host from rebooting while
the host that monitors it, or its alert path, is down; stagger the windows as well (see
[rollout](#rollout-report-then-reboot)).

## Escalation and report mode

An **episode** starts the first night with a trigger and ends when no trigger remains or after a
reboot. Deferred nights are counted as consecutive nights, once per night (a manual run within 12
hours of the last counted night does not count again), and a night with every guard clear resets
the count. When the count reaches `BROKKR_GUARDED_REBOOT_ALERT_AFTER` (default 3) the job alerts
once per episode; the kill switch is excluded. The `unlock` guard alerts at once, once per episode.
An alert never overrides a guard.

In **report mode** (the default) the job does everything except act: action `would-reboot` when it
would have rebooted, and one notice per episode ("report mode: would reboot node-a for kernel").
It never reboots and never stages firmware. `--report-only` forces report mode for one invocation;
the deploy uses it for its first run.

## The reboot sequence

In **reboot mode**, when a trigger exists and every guard is clear, the job runs these steps in
this order and stops at the first failure:

1. Write the **attempt record** to the state file (boot id, time, triggers, identities, status
   `unresolved`). The running-service baseline was captured at the start of the check; if it could
   not be captured, or the state cannot be written, nothing reboots (exit 1).
2. Evaluate every guard a **second time**. Any guard defers and nothing is staged.
3. Append the **attempt/intent audit record** (action `reboot`): the triggers, the identities, the
   planned EEPROM staging (`eeprom-staging planned (version N)`) and the reversal recipe
   (`irreversible`, with its mitigations). **If the audit write fails, nothing is staged,
   notified or rebooted** (exit 1).
4. If the `eeprom` trigger is present, **stage** the update with `sudo -n rpi-eeprom-update -a`
   and verify that it is staged. A failure appends the abort (action `deferred`, detail starting
   `reboot aborted`), cancels with `-r`, defers with the guard `eeprom-stage` and stops. **If the
   cancellation fails too, the host latches** (an `alert` whose detail starts `latched`), because
   the staged update would be flashed by the next boot.
5. Send "Rebooting node-a for kernel" through the confirmed notify path. **If the notice cannot be
   delivered, the host does not reboot**: it appends the abort, defers with the guard `notify`
   (alerts route through the control node, and a host must not reboot while its alert path, or the
   peer behind it, is down) and cancels a staged update, latching if that fails.
6. Evaluate every guard a **third and final time**, immediately before the reboot (a person may
   have logged in, or the kill switch appeared, while the notice was in flight). Any guard
   appends the abort and defers, and a staged update is cancelled.
7. `sudo -n systemctl reboot`, exactly once. **If the command exits non-zero the host latches at
   once**: the attempt record is kept (never silently restored), a staged update is cancelled, and
   the job audits an `alert` whose detail is `latched: reboot command failed (exit N)` and exits 1.

An abort after step 3 leaves the trail `reboot` followed by `deferred` ("reboot aborted before it
was executed") in the audit file: a `reboot` line is the intent record, and a reboot happened only
if a `post-boot-ok` or `post-boot-issues` line follows it. The maintenance report reads it that
way.

## Latch and the post-boot check

The attempt record is `unresolved` until the **post-boot check** records a result for it. The check
runs ten minutes after boot and does nothing unless an unresolved attempt exists whose boot id
differs from the current one. It **positively verifies the recorded targets**, one per trigger of
the attempt, and an observation that cannot be made is an issue (it never passes by default):

| Attempt for | Verified |
|---|---|
| `kernel` | the running kernel equals the recorded expected version (anything else, even a newer kernel, is an issue) |
| `eeprom` | a successful status read whose current bootloader version is at least the recorded target (an unknown status, or a missing `rpi-eeprom-update`, is an issue) |
| `reboot-required` | the flag is gone, or its identity changed |

A *new* trigger with a different identity is only a note. It also checks that `systemctl --failed`
and `systemctl --user --failed` are empty and that every service in the baseline is running again,
ignoring only units that **start on demand**: `Type=dbus`, a non-empty `BusName=`, a non-empty
`TriggeredBy=` (socket or timer) or a transient unit. Being a `static` or `indirect` unit file proves
nothing, so a static long-running service that vanished is an issue.

**The outcome is made durable in a fixed order.** The check appends `post-boot-ok` or
`post-boot-issues` to the audit file *before* it persists the attempt status `ok` or `issues`
(and the latch). If the append fails the attempt stays `unresolved` (exit 1) and the notices still
go out; the next nightly check then latches it as "post-boot verification missing" instead of the
host looking verified while no record says so. The check sends "back up: node-a kernel
7.0.0-39-generic; health OK" or the issue list.

**Issues latch automatic reboots off.** So do a reboot command that exits non-zero, an EEPROM
update that could not be cancelled after an abort, and an unresolved attempt that is more than two
hours old at the next nightly check ("post-boot verification missing" when the host rebooted but no
result was recorded, "reboot did not happen" when the boot id is unchanged). The job alerts once when it
latches (an `alert` audit line whose detail starts `latched`) and every later night defers with
the guard `latched`. New triggers never clear the latch; only the owner does, after
investigating:

```sh
~/.local/lib/brokkr/guarded-reboot/releases/<SHA>/scripts/guarded-reboot.sh clear-latch
```

`clear-latch` is audited first (if the audit append fails the latch stays) as action `none` with a
detail starting `latch-cleared`, so a reader can tell the latch is active from a `latched` alert
until a later `latch-cleared` record. Only a successful post-boot result matched to the attempt and
its boot makes the host eligible again without the owner.

## Daily health check

Every night the check records a **pre-update baseline** of the running system services and the
operator's user services, before the stock apt timers install anything. At 08:00 the `health`
subcommand compares the running services with that baseline and checks the failed units
(`systemctl --failed`, `systemctl --user --failed`), ignoring on-demand units as the post-boot check
does. A regression is audited as `health-issues` and alerted; the same issues on the next day are
not repeated, a changed set is, and a recovery is audited once as `health-ok` (a healthy day with
nothing before it audits nothing). A baseline older than two days means the nightly check stopped
and is itself reported. The job's own units and transient `run-*` units are left out of the baseline.

## Bootloader EEPROM (Raspberry Pi)

`rpi-eeprom-update -a` stages a bootloader update, and the bootloader's `recovery.bin` flashes it
at the **next boot of any kind**; `rpi-eeprom-update -r` removes the staged files and cancels a
pending update. The stock `rpi-eeprom-update.service` runs `rpi-eeprom-update -s -a` at every boot,
so left alone it stages updates outside every guard. Therefore:

- **The deploy disables the stock service** (`sudo -n systemctl disable rpi-eeprom-update.service`,
  only when `rpi-eeprom-update` exists and the service was enabled) and prints the exact
  re-enable command in its rollback. The preflight reports the service's state.
- **Staging happens only inside an admitted guarded reboot**, in reboot mode, after every guard
  (the second pass included) is clear and the intent audit record is written; the staged update is
  then flashed by that very reboot. Report mode never stages. The kill switch and the latch prevent
  staging because they defer the reboot before the staging step.
- **A staged update found with no attempt in progress is cancelled** (`-r`), audited as an `alert`
  whose detail starts `eeprom-cancelled`, and announced. This runs at the start of every nightly
  check and after the post-boot check (not under `--report-only`). **A cancel that fails blocks
  admission**: an `eeprom-cancel-failed` alert is audited and delivered, the run exits 1, and the
  guard `eeprom-stray` stops every reboot until a later run cancels the update successfully.
- **A staged update applies at the next boot, whatever its cause, and the kill switch does not
  cancel it.** `status` (and so the deploy summary) says so whenever one is staged. To suspend
  firmware writes (ADR-009 §7): create the kill switch, which stops this job from staging, keep
  `rpi-eeprom-update.service` disabled, and make sure nothing is staged — cancel with
  `sudo rpi-eeprom-update -r` and confirm with `status`. Firmware writes count as suspended only
  when nothing is staged. Holding the package (`apt-mark hold rpi-eeprom`) additionally stops new
  bootloader versions from being installed.

The owner has accepted the risk that comes with this: a power interruption while the bootloader
is being written can leave the EEPROM unusable, and a failed write needs physical access to
recover (the bootloader recovery image written with Raspberry Pi Imager, booted from an SD card
or over USB).

## Kill switch

Creating the kill-switch file (default `/etc/brokkr/guarded-reboot.disabled`, any file type, even a
dangling symlink) stops automatic reboots at the next evaluation, including the final check
immediately before a reboot. It is intentional: it never escalates and it counts no deferrals.
It does not cancel an EEPROM update that is already staged (see above). Remove the file to resume.

## Audit file and the daily report

Every decision that matters is appended, one JSON object per line, to
`/var/lib/brokkr/guarded-reboot/audit.jsonl` through the fixed command
`sudo -n tee -a /var/lib/brokkr/guarded-reboot/audit.jsonl` (the path is a constant, not
configurable), under umask 022 so the root-owned file is world-readable (0644) and the unprivileged daily
maintenance report can read it. The directories are created by the deploy as
`sudo -n install -d -m 0755 /var/lib/brokkr /var/lib/brokkr/guarded-reboot`; an existing
`/var/lib/brokkr` is never chmod-ed, only verified to be world-searchable (the deploy refuses
otherwise). Keys and their order are fixed because another component parses the file with sed and awk:

```json
{"ts":"2026-09-21T03:41:07Z","epoch":1790000467,"host":"node-a","mode":"reboot","action":"reboot","triggers":"kernel,eeprom","guards":"","boot_id":"aaaaaaaa-0000-4000-8000-000000000001","detail":"identities kernel=7.0.0-39-generic,eeprom=1790000001; eeprom-staging planned (version 1790000001); reversal irreversible (mitigations: post-boot check, latch, kill switch, previous kernel kept); running kernel 7.0.0-38-generic is older than installed 7.0.0-39-generic"}
```

`action` is one of `none`, `deferred`, `would-reboot`, `reboot`, `alert`, `post-boot-ok`,
`post-boot-issues`, `health-issues`, `health-ok`. Detail conventions the report relies on: a
latching `alert` starts `latched`; `clear-latch` writes action `none` with a detail starting
`latch-cleared`; an EEPROM cancellation is an `alert` starting `eeprom-cancelled`; a `reboot`
line is the intent record (identities, planned staging, reversal recipe) and an abort after it is
a `deferred` starting `reboot aborted`. The audit is **fail-closed**: a failed append stops a
reboot before the staging, the notice and the reboot (and fails the other subcommands with exit 1).

Under the failure-recovery contract each executed reboot is an autonomous mutation. While Verdandi
is stopped its audit event is this local record, the Telegram notice before the reboot and after
the post-boot check, and the daily `brokkr-maintenance-os` report, which projects the audit file
into Munin `maintenance/os/<host>`. The **reversal recipe is `irreversible`**: a reboot cannot be
taken back. The mitigations are the post-boot check and its alert, the latch, the kill switch, and
the previous kernel left installed for manual boot selection. Package upgrades by
unattended-upgrades are recorded in `/var/log/apt/history.log` and are `irreversible` too; the
only undo is a manual, owner-run downgrade.

The operator's own state is `~/.local/state/brokkr/guarded-reboot.json` (mode 0600, written
atomically, validated on read: a damaged file is refused with exit 1, never guessed at). It holds
the last decision, the episode, the latch, the attempt record, the service baseline and the health
state.

## Privileged commands

The job runs as the operator user and uses `sudo -n` with these **constant** argument lists only. No
environment variable changes any argument of a sudo call (the audit path and the EEPROM status file
are constants; the tests put a stub `sudo` on `PATH` that maps them into their fixture tree). It
never runs `sudo sh -c` and never interpolates fetched or file data into a command:

| Command | Used by |
|---|---|
| `sudo -n rpi-eeprom-update -j -m /run/brokkr-guarded-reboot-eeprom.json` | the EEPROM status (check only; root writes the file, the job reads it unprivileged) |
| `sudo -n rpi-eeprom-update -a` | staging, inside an admitted reboot |
| `sudo -n rpi-eeprom-update -r` | cancelling a staged update |
| `sudo -n tee -a /var/lib/brokkr/guarded-reboot/audit.jsonl` | the audit append |
| `sudo -n systemctl reboot` | the reboot |
| `sudo -n install -d -m 0755 /var/lib/brokkr /var/lib/brokkr/guarded-reboot` (or only the second directory when the first exists) | the deploy only |
| `sudo -n systemctl disable rpi-eeprom-update.service` | the deploy only |
| `sudo -n true` | the deploy preflight |

The units deliberately carry **no `NoNewPrivileges=` and no other sandboxing directive**
(`PrivateTmp=`, `Protect*=`, `Restrict*=`): in a user unit they put the service in a user
namespace or set no_new_privs, where sudo's setuid cannot work.

## Configuration

Rendered into the nightly unit by the deploy (the other two units carry only the mode):

| Variable | Default | Meaning |
|---|---|---|
| `BROKKR_GUARDED_REBOOT_MODE` | `report` | `report` or `reboot` |
| `BROKKR_GUARDED_REBOOT_BUSY_UNITS` | empty | space-separated systemd user `.service` units; the `busy:<unit>` guard |
| `BROKKR_GUARDED_REBOOT_PEERS` | empty; **required in reboot mode** | space-separated host names that must accept TCP port 22 (normally the host that monitors this one) |
| `BROKKR_GUARDED_REBOOT_MAX_LOAD` | 0.75 x `nproc` | highest 5-minute load average |
| `BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN` | 60 | minutes; 0 disables the terminal guard |
| `BROKKR_GUARDED_REBOOT_ALERT_AFTER` | 3 | consecutive deferred nights before the alert (1 to 365) |

Every value is validated; an invalid one is a usage error (exit 64). Exit 0 means normal (including
deferred, report and no trigger); exit 1 is an internal failure (a state or audit write failure, an
unreadable required input such as the boot id or boot directory, a failed cancel). In reboot mode
the nightly check refuses to run without a peer (exit 64). Test seams, used by the hermetic tests
and all of them read-only or local (none reaches a sudo argument): `BROKKR_NOW_EPOCH`,
`BROKKR_BOOT_DIR`, `BROKKR_REBOOT_REQUIRED_FILE`, `BROKKR_CRYPTTAB`, `BROKKR_KILL_SWITCH`,
`BROKKR_BOOT_ID_FILE`, `BROKKR_LOADAVG_FILE`, `BROKKR_CGROUP_ROOT`, `BROKKR_EEPROM_PENDING_FLAG`,
`BROKKR_EEPROM_STATUS_FILE` (where the root-written status file is read from, unprivileged),
`BROKKR_STATE_DIR` and `BROKKR_NOTIFY_HELPER` (the notify helper, default
`scripts/lib/notify.sh`, which must provide `notify_telegram_confirmed`: only a confirmed
delivery counts as sent). The helper is sourced, so it is treated as code: it must be a regular,
non-symlink file owned by the operator that no one else can write, otherwise it is not trusted.

## Rollout: report, then reboot

1. Deploy in report mode (the default). For the first week the job logs and alerts what it would
   do and never reboots.
2. Review the week: `status`, the audit file (`would-reboot` and `deferred` lines with their
   guards), the journal (`journalctl --user -u brokkr-guarded-reboot -n 50`), and check that the
   guards behave (a busy unit really defers, the peers answer, no `unlock` alert on a host that
   should reboot unattended).
3. Redeploy with `BROKKR_GUARDED_REBOOT_MODE=reboot`. Reboot mode is the owner's explicit switch
   and states what report mode defaults: the deploy refuses it without an explicit
   `BROKKR_GUARDED_REBOOT_WINDOW` (there is no default window in reboot mode), without at least one
   `BROKKR_GUARDED_REBOOT_PEERS` entry, and on a host with no notify configuration (the notify guard
   would refuse every reboot). The nightly check itself also refuses reboot mode without a peer.

Stagger the windows so that a host and the host that monitors it never reboot together, and name
the monitoring host as a peer. Keep each host's window plus its spread at least two hours clear of
the other's: for example `node-a` at 02:00 with a 45 minute spread (it may start up to 02:45) and
`node-b`, which monitors it, at 05:00, each naming the other as a peer.

## Deploy

```sh
# Dry-run (default): remote preflight only, nothing is changed.
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT="<full-40-char-sha>" \
BROKKR_GUARDED_REBOOT_WINDOW=03:30 BROKKR_GUARDED_REBOOT_BUSY_UNITS=hugin.service \
BROKKR_GUARDED_REBOOT_PEERS=node-b.example \
  scripts/deploy-guarded-reboot.sh operator@node-a.example

# Install in report mode: the same environment plus --apply.
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT="<full-40-char-sha>" \
BROKKR_GUARDED_REBOOT_WINDOW=03:30 BROKKR_GUARDED_REBOOT_BUSY_UNITS=hugin.service \
BROKKR_GUARDED_REBOOT_PEERS=node-b.example \
  scripts/deploy-guarded-reboot.sh --apply operator@node-a.example

# After the report-only week: switch the same node to reboot mode with a new revision.
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT="<full-40-char-sha>" \
BROKKR_GUARDED_REBOOT_MODE=reboot BROKKR_GUARDED_REBOOT_WINDOW=02:00 \
BROKKR_GUARDED_REBOOT_SPREAD=45 \
BROKKR_GUARDED_REBOOT_BUSY_UNITS=hugin.service BROKKR_GUARDED_REBOOT_PEERS=node-b.example \
  scripts/deploy-guarded-reboot.sh --apply operator@node-a.example
```

`BROKKR_EXPECTED_COMMIT` must be the full SHA of the clean checkout at `BROKKR_EXPECTED_SOURCE`;
the payload is the committed archive of that revision, never the working tree. Optional inputs,
validated locally before anything reaches ssh: `BROKKR_GUARDED_REBOOT_MODE`,
`BROKKR_GUARDED_REBOOT_WINDOW` (`HH:MM`, default 03:30 in report mode only), `BROKKR_GUARDED_REBOOT_SPREAD`
(minutes, 0 to 240, default 45), `BROKKR_GUARDED_REBOOT_BUSY_UNITS`, `BROKKR_GUARDED_REBOOT_PEERS`,
`BROKKR_GUARDED_REBOOT_MAX_LOAD`, `BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN` and
`BROKKR_GUARDED_REBOOT_ALERT_AFTER`.

The remote preflight (also run by the dry-run) refuses unless the user is not root, the host is
Linux, lingering is enabled, `sudo -n true` works, the release for that SHA does not yet exist, no
unit backup for it exists, and an existing `/var/lib/brokkr` is a real, world-searchable directory.
It checks the notify configuration the way `scripts/lib/notify.sh` finds it (a warning in report
mode, a refusal in reboot mode), reports the crypttab unlock assessment (the same rule as the
`unlock` guard: volumes that would stop an unattended boot at a prompt) and, on a Pi, the state of
the stock EEPROM service.

`--apply` stages the payload, checks its file count and types and that the job and the notify helper
parse under the node's `bash`, creates the audit directories, saves any existing units as
`<unit>.previous-<SHA>` (all backups exist before any unit is replaced), moves the payload to
`~/.local/lib/brokkr/guarded-reboot/releases/<SHA>`, renders the six units into
`${XDG_CONFIG_HOME:-~/.config}/systemd/user/`, reloads systemd, enables the three timers, disables
the stock EEPROM service when present, and runs the released job once with `check --report-only`
and `status`, printing both. It **never starts the reboot service and never reboots**. A first run
that fails, or an audit file that is not world-readable, exits the deploy non-zero with the
rollback recipe while the release stays installed.

## Verify

```sh
systemctl --user list-timers 'brokkr-*'
journalctl --user -u brokkr-guarded-reboot -n 50 --no-pager
~/.local/lib/brokkr/guarded-reboot/releases/<SHA>/scripts/guarded-reboot.sh status
tail -n 5 /var/lib/brokkr/guarded-reboot/audit.jsonl
```

## Roll back

The deploy prints the exact rollback for the node. In outline, as the runtime user:
`systemctl --user disable --now` the three timers, move each `<unit>.previous-<SHA>` back (or delete
the unit if there was none), `systemctl --user daemon-reload`, then give each timer that had a
previous unit back **exactly the enabled and active state the deploy captured before it replaced
anything** (`enable --now` only for a timer that was both enabled and active; `enable` alone for one
that was enabled but stopped; `start` alone for one that was active but not enabled; nothing for one
that was off), and optionally remove the release directory. If the deploy disabled the stock EEPROM
service, the rollback also prints
`sudo systemctl enable rpi-eeprom-update.service`. The audit directory, the audit file and the state
file are evidence and stay in place. Rolling back does not undo a reboot that already happened
(`irreversible`).

## Limitations

- **No workload hooks beyond busy units.** The job knows only the units it is told about
  (`busy:<unit>`), not what runs inside them; a task started by hand outside those units is seen
  only through the terminal guard.
- **A busy unit that is `active` but has no control group** (for example a `RemainAfterExit`
  oneshot) defers every night. Name only long-running services.
- **The EEPROM path depends on rpi-eeprom behaviour**: the JSON status from `-j -m`, staging by
  `-a`, a pending-update flag file or `pieeprom.upd` on the boot partition as the evidence of
  staging, and flashing by the bootloader at the next boot. A bootloader newer than the offered
  one, or an unknown running version, is never updated. VL805 (USB controller) firmware on a
  Raspberry Pi 4 is not considered.
- **The EEPROM status file is a fixed path.** A file written less than a minute earlier whose
  `EXITCODE` matches the new run's exit status would be taken for the new answer if the privileged
  command died before writing; `/run` is cleared by every boot, so the post-boot check never sees
  an older file, and nightly runs are hours apart.
- **Full-disk-encrypted hosts.** The `unlock` guard refuses to reboot a host whose volumes need a
  passphrase at boot, and alerts once per episode. A boot-chain change can break TPM-bound unlock;
  UEFI/BIOS and Secure Boot firmware stay detect-and-report only. Revisit this policy before the
  inference node's root volume is encrypted without unattended unlock.
- **Kernel flavours that share a suffix.** Matching uses the shared flavour rule above; a kernel
  whose release does not fit the version pattern has no flavour and is reported as "kernel status
  unknown" instead of being compared.
- **The post-boot check compares only services that were running** at the nightly capture, and
  ignores on-demand units; a failed unit that was already failed before the reboot keeps the check
  at issues until it is fixed.
- **Overlapping runs are not serialised.** A manual run during a timer firing can collide; the
  services are oneshot, so the timer itself never overlaps.
- **Alerts are only as good as the notify path.** In reboot mode an undeliverable notice stops the
  reboot (the `notify` guard); in report mode it is only logged.
- **Linux only**, bash 3.2 or newer, and python3 or node on a host with `rpi-eeprom-update`.
