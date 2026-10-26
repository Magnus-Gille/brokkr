# Energy Efficient Ethernet stays off

Energy Efficient Ethernet (EEE, IEEE 802.3az) lets both ends of a wired link drop
into a low-power idle state between bursts of traffic. On the fleet's wired
interfaces it is kept **off**. This page records why, what it was not, and how
the setting is deployed.

## Decision

EEE stays off on the control node's wired interface (brokkr#150). The saving is
well under a watt per port, which is negligible for an always-on fleet node. In exchange EEE adds a wake-up latency to every idle-to-active transition
and is a well-known source of driver- and PHY-specific link trouble. With EEE
off there is one fewer variable the next time a link misbehaves.

## EEE was not the cause of the 2026 link flapping

In October 2026 the control node's wired link dropped about 879 times over four
weeks, after which the router held the port at 100 Mb/s on a
2.5 Gb/s NIC (see [wired-link health](link-health.md)). EEE was switched off
during the diagnosis as a precaution, with an ad-hoc oneshot unit
`<iface>-eee-off.service` installed outside this repository.

**That did not fix it.** The link kept flapping with EEE off. The root cause was
a faulty Ethernet cable: swapping cables between two nodes moved the fault with
the cable. EEE is kept off by choice, not as a fix, and its being off says nothing
about the health of a link. Watch the [link-health probe](link-health.md) for
that.

## What is deployed

[`network/brokkr-eee-off@.service.example`](../network/brokkr-eee-off@.service.example)
is a systemd template whose instance name is the interface, so the tracked file
holds no host data. The deploy fills in the node's verified absolute `ethtool`
path and the source revision and installs it as
`/etc/systemd/system/brokkr-eee-off@.service`. The enabled instance
`brokkr-eee-off@<iface>.service` is a `RemainAfterExit` oneshot that runs
`ethtool --set-eee <iface> eee off`. It is bound to and ordered after the
interface's device unit, and it is the only unit that sets EEE. Three triggers
start it:

| Trigger | Mechanism |
| --- | --- |
| Every boot | `WantedBy=multi-user.target`. The boot transaction starts it and, through `BindsTo=`/`After=`, waits for the device. |
| Device appears (hotplug, driver reload) | `WantedBy=sys-subsystem-net-devices-<iface>.device` |
| Link change turned EEE back on | `brokkr-eee-off-watch@<iface>.service` restarts it |

[`network/brokkr-eee-off-watch@.service.example`](../network/brokkr-eee-off-watch@.service.example)
is installed as `/etc/systemd/system/brokkr-eee-off-watch@.service` with the
verified `ethtool` and `ip` paths. Its instance runs `ip -o monitor link`. It
reads the EEE status (read-only) when it starts and on every event that shows
`<iface>` with `LOWER_UP`. When the status is anything but `disabled` or
`not supported`, it restarts `brokkr-eee-off@<iface>.service` and logs why. A
re-apply that renegotiates the link is a no-op the second time, because EEE then
reads `disabled`. If a driver never keeps EEE off, the managed unit's start limit
(`StartLimitBurst=5` per `StartLimitIntervalSec=10min`) fails it. The watcher does
not restart a failed unit, so the link is not renegotiated in a loop, and the
failed unit shows in `systemctl --failed` and, where it runs, the
[systemd failure monitor](systemd-failure-monitor.md).
It has the same two `WantedBy=` entries, `Restart=always`, and is ordered after the
managed unit so that both do not set EEE at the same boot.

Interface names are limited to letters, digits, `_` and `.` (at most 15, not
starting with `.`), so the raw instance name equals the escaped device-unit name.

### Why the device trigger alone was not enough

The first managed release (PR #158) and the ad-hoc unit before it were started
only by a link in `sys-subsystem-net-devices-<iface>.device.wants/`. On
2026-10-26 the control node rebooted, the ad-hoc unit did not run (no journal
entry at all) and EEE was found enabled. The managed release used the same trigger,
so it would have failed the same way. The exact path on that boot is not proven
(the device unit's journal of that boot was not captured), but primary sources
show why the trigger is fragile:

- A `.wants/` link on a device unit is acted on only when the device unit *changes*
  to plugged. [systemd.device(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.device.html):
  systemd "will only act on Wants= dependencies when a device first becomes
  active". PID 1 then queues a retroactive start (`retroactively_start_dependencies()`
  in `src/core/unit.c`). It skips that step while it reloads or deserializes,
  and a device that already has a start job pulls its wants into that job instead.
- `sys-subsystem-net-devices-<iface>.device` is a separate alias unit, created
  from `ENV{SYSTEMD_ALIAS}` in `99-systemd.rules` with the interface's name at that
  moment. A predictable name such as `eno1` is a udev rename of the kernel's
  `eth0`, which arrives as a `move` uevent and creates the new alias unit. A
  stale `eth0` alias unit after such a rename is a known systemd bug
  ([systemd#43767](https://github.com/systemd/systemd/issues/43767)).
- Debian's initramfs-tools initrd runs udev without `99-systemd.rules`, so net
  devices have no `systemd` tag there. Their device units appear only when the
  real root's `systemd-udev-trigger.service` replays `add` uevents. That is during
  the boot transaction, whose isolate of the default target can cancel unrelated
  pending jobs (compare [systemd#6505](https://github.com/systemd/systemd/issues/6505)).
  This last point is a hypothesis, not a reproduction.

Each of these depends on one edge at the right moment. `WantedBy=multi-user.target`
does not: the unit is part of the boot transaction itself, and `BindsTo=` plus
`After=` make that transaction wait for the device, whatever its alias history.
The device `.wants/` link stays for hotplug and driver reloads.

### Why a netlink watcher and not a udev rule or dispatcher hook

On some drivers (r8169 among them, depending on the kernel) EEE can be turned back
on when the link renegotiates.

- A carrier change is an rtnetlink event (`linkwatch_do_dev()` →
  `netif_state_change()` in `net/core/link_watch.c`). It is not a uevent, so a
  udev rule such as `ACTION=="add|move", SUBSYSTEM=="net", NAME=="<iface>"` fires
  on a rename or a new device but never on a carrier change. The multi-user and
  device triggers already cover those cases.
- [NetworkManager-dispatcher](https://networkmanager.dev/docs/api/latest/NetworkManager-dispatcher.html)
  has no carrier action, and with the default `carrier-wait-timeout` of 6 s a
  short drop dispatches nothing.
- [networkd-dispatcher](https://gitlab.com/craftyguy/networkd-dispatcher) has a
  `carrier.d`, but it is a separate package and only follows systemd-networkd.
- ifupdown hooks run only on `ifup`.

`ip monitor link` sees every carrier change whatever manages the interface, so the
deploy does not need to detect the network stack and cannot pick the wrong one.
It needs only `iproute2`, which the preflight requires.

## Deploy

[`scripts/deploy-eee-off.sh`](../scripts/deploy-eee-off.sh) follows the
[deployment source binding](deployment-source-binding.md): it refuses unless it
runs from the clean worktree at exactly `BROKKR_EXPECTED_COMMIT`, and it ships the
template from that commit rather than from the working tree.

```bash
BROKKR_EXPECTED_SOURCE=$PWD BROKKR_EXPECTED_COMMIT=<full-sha> \
  scripts/deploy-eee-off.sh operator@node-a.example eth0          # dry-run
BROKKR_EXPECTED_SOURCE=$PWD BROKKR_EXPECTED_COMMIT=<full-sha> \
  scripts/deploy-eee-off.sh --apply operator@node-a.example eth0  # install
```

It runs as a non-root operator. Privileged steps use `sudo -n` and fail rather
than prompt. Before changing anything it refuses when:

- the local user, the SSH target user or the remote runtime user is root;
- passwordless `sudo -n` is unavailable;
- the interface does not exist, `ethtool` or `ip` is missing (the deploy never
  installs packages), or `ethtool --show-eee` reports that the interface does not
  support EEE;
- `<iface>-eee-off.service` exists but is not exactly the supported shape. It
  must be a regular file with no drop-in directory and exactly one `Exec*` line,
  `ExecStart=/<path>/ethtool --set-eee <iface> eee off`. Its only `WantedBy=` must
  be the interface's device unit, and it may use only unit-local directives
  (`Description`, `Documentation`, `After`, `Before`, `BindsTo`, `Requires`,
  `Wants`, `PartOf`, `Type`, `RemainAfterExit`, `ExecStart`, `WantedBy`).
  `Also=` or `Alias=` would make disabling it act on other units. It must be
  `enabled` or `disabled`. Anything else is adopted by hand, because the deploy
  deletes the unit it adopts;
- any other unit or drop-in in the unit directory sets EEE on that interface, to
  any value, or an enabled instance of another template does through its
  template, its template's drop-ins or its own drop-ins, which would leave two
  owners of one setting. A file counts as an owner when it runs `--set-eee`
  anywhere and names the interface as a whole token anywhere (`%i`/`%I` for a
  template). This is deliberately broad: quoting and line continuations are not
  parsed, so an ambiguous file refuses. Commands hidden in scripts that a unit
  runs are out of scope;
- a concrete `brokkr-eee-off@<iface>.service` or
  `brokkr-eee-off-watch@<iface>.service` file would shadow its template, a
  drop-in directory overrides a managed template or instance, or an instance is
  in a state other than enabled, disabled or absent;
- an inherited drop-in directory applies to any of the units: the top-level
  `service.d/` or a dash-prefix directory such as `brokkr-eee-.service.d/`,
  `brokkr-eee-off-.service.d/` or `<iface>-eee-.service.d/`. Any of them could
  reset `ExecStart` or add a condition;
- a device or `multi-user.target.wants/` link of a managed instance exists but is
  not a live link to that instance's template in the unit directory;
- the ad-hoc unit has a link other than its device dependency, such as an alias
  or a `.requires/` link. Disabling it would remove that link and the rollback
  could not recreate it;
- the managed instance reports `enabled` but has no
  `sys-subsystem-net-devices-<iface>.device.wants/` link, which is what re-applies
  the setting when the interface comes back;
- a file, directory listing or link in the unit directory cannot be read through
  `sudo -n`. systemd reads unit files as root and some are root-only (mode 600),
  so the unit directory is enumerated once as root (`sudo -n find -L`, two levels
  deep, which also follows symlinked `.d` and `.wants` directories) and every file
  is read with `sudo -n cat`. Existence, link and dangling-link checks use that
  enumeration, not the operator's view. A read or listing that `sudo -n` refuses,
  a symlink loop, or a file name containing a newline or tab stops the deploy
  instead of counting as "no match". Only a link whose target root cannot find is
  skipped, because it runs nothing;
- a backup for this revision already exists.

Only `/etc/systemd/system` is scanned. Units under `/run` or `/usr/lib` and other
tools such as NetworkManager are out of scope.

The dry-run prints the current EEE status and exactly what `--apply` would back
up, install, and adopt.

### Adopting the ad-hoc unit

With `--apply` the deploy:

1. copies every file it will replace or remove (the ad-hoc unit, previous
   managed templates) to `<name>.previous-<revision>` in the unit directory. Until
   every backup exists, nothing is changed;
2. installs both rendered templates and reloads systemd;
3. enables `brokkr-eee-off@<iface>.service`, checks that both its device and its
   `multi-user.target.wants/` link exist, clears a previous start-limit failure
   (`reset-failed`), restarts it and verifies that it is active and
   `ethtool --show-eee` reports `disabled`;
4. enables, checks the links of, and restarts
   `brokkr-eee-off-watch@<iface>.service`, and verifies that it is active;
5. only then disables and removes `<iface>-eee-off.service`, so exactly one unit
   owns the setting afterwards.

If steps 2 to 4 fail, the ad-hoc unit stays enabled and in charge. Re-running the
same revision on a node that is already in place changes nothing. "In place" means
both templates are current, both instances are enabled and active with all four
links, and EEE reads `disabled`.

### Migrating an earlier release

A node that runs the first managed release has the instance enabled only through
the device link, and no watcher. Redeploying a newer revision is the migration;
there is no separate step. Step 3 always runs `systemctl enable`, which adds the
missing `multi-user.target.wants/` link from the new `[Install]` section, and step
4 installs the watcher. The earlier template is backed up as
`brokkr-eee-off@.service.previous-<revision>`. A dry-run first shows what will
change.

### Rollback

Every `--apply` that changed something prints a rollback recipe listing only the
steps that run completed. It handles the watcher first, so that the watcher cannot
restart the managed unit during the rollback. For each instance it stops it if it
was inactive before. It disables it if it was disabled before, or, if it was
already enabled, removes only the links this run added (on a migration, the new
`multi-user.target.wants/` link). It removes each template or restores its
previous version, restores and re-enables the ad-hoc unit, and reloads systemd.
Last, it restarts each instance on its previous template if it was active before.
Activity and enablement are restored independently. The tests run the
printed recipe against stateful fakes and check that unit files, enablement and
activity match the state before the deploy. Disabling or removing a unit does not change the
live setting. EEE stays off until the next boot or driver reload unless it is
turned on explicitly with `ethtool --set-eee <iface> eee on`, which goes against
the tracked decision.

## After a deploy

The issue's acceptance is that host state matches this decision and the
[link-health probe](link-health.md) stays OK on the node for 24 hours. Check the
probe's snapshot or panel a day after the change rather than relying on the
deploy's own verification.

On some drivers, setting EEE makes the link renegotiate, even when EEE was
already off. A deploy that changes something restarts the unit, so it may cause
one short link drop. The link-health probe counts that drop like any other, and
an SSH session over the wired link may stall while it happens. Deploy when a
short drop is acceptable. Re-running a revision that is already in place does not
touch the link.

## Verification plan (needs owner approval)

A deploy proves only that EEE is off now. That the setting survives a reboot and
a link change is proven only on the host. Each step below that changes the host
(the deploy, the reboot, the cable test) needs the owner's separate approval
naming the exact revision, a time when one short link drop and a reboot are
acceptable, and console or out-of-band access in case the wired link does not
come back. Run the read-only checks as the operator on the node.

1. **Before**: record the baseline, and check that the link-health probe is OK.

   ```bash
   ethtool --show-eee <iface>
   systemctl is-enabled brokkr-eee-off@<iface>.service brokkr-eee-off-watch@<iface>.service
   systemctl is-active brokkr-eee-off@<iface>.service brokkr-eee-off-watch@<iface>.service
   ls -l /etc/systemd/system/multi-user.target.wants/ /etc/systemd/system/sys-subsystem-net-devices-<iface>.device.wants/
   ```

2. **Deploy** (approved revision): dry-run, then `--apply`. Expect
   `OK: EEE is off on <iface>` and `OK: re-applied at every boot`.
3. **Planned reboot** (approved window). After it, without touching anything:

   ```bash
   ethtool --show-eee <iface>                          # EEE status: disabled
   systemctl is-active brokkr-eee-off@<iface>.service brokkr-eee-off-watch@<iface>.service
   journalctl -b -u brokkr-eee-off@<iface>.service -u brokkr-eee-off-watch@<iface>.service
   journalctl -b -u sys-subsystem-net-devices-<iface>.device
   systemctl show -p ActiveEnterTimestamp sys-subsystem-net-devices-<iface>.device brokkr-eee-off@<iface>.service
   ```

   Pass: EEE is `disabled`, both units are active, and this boot's journal shows
   the managed unit finishing. The device-unit lines show which trigger fired first,
   which settles the diagnosis above.
4. **Link change** (optional, approved): unplug and replug the cable, or make the
   switch port renegotiate. Then `ethtool --show-eee <iface>` must read `disabled`.
   The watcher's journal shows a re-apply only if the driver had turned EEE on.
5. **24 hours**: the [link-health probe](link-health.md) stays OK and
   `systemctl --failed` lists neither unit. A failed `brokkr-eee-off@<iface>.service`
   with result `start-limit-hit` means the driver does not keep EEE off. Leave it
   failed and report it. Do not `reset-failed` it in a loop.

Rollback after a successful verification is the recipe the deploy printed. Neither
the deploy nor this plan reboots a node by itself.

Tests: [`scripts/test/deploy-eee-off.test.sh`](../scripts/test/deploy-eee-off.test.sh)
(hermetic; ssh, sudo, systemctl, ethtool, ip and id are fakes, and the rendered
watcher script is run against scripted `ip monitor` lines).
