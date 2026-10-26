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
`ethtool --set-eee <iface> eee off`. It is wanted by, bound to and ordered after
the interface's device unit, so EEE is switched off again whenever the device
appears: at boot and after a driver reload.

Interface names are limited to letters, digits, `_` and `.` (at most 15, not
starting with `.`), so the raw instance name equals the escaped device-unit name.

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
- the interface does not exist, `ethtool` is missing (the deploy never installs
  packages), or `ethtool --show-eee` reports that the interface does not support EEE;
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
- a concrete `brokkr-eee-off@<iface>.service` file would shadow the template, a
  drop-in directory overrides the managed template or instance, or the instance
  is in a state other than enabled, disabled or absent;
- an inherited drop-in directory applies to either unit: the top-level
  `service.d/` or a dash-prefix directory such as `brokkr-eee-.service.d/` or
  `<iface>-eee-.service.d/`. Any of them could reset `ExecStart` or add a
  condition;
- the ad-hoc unit has a link other than its device dependency, such as an alias
  or a `.requires/` link. Disabling it would remove that link and the rollback
  could not recreate it;
- the managed instance reports `enabled` but has no
  `sys-subsystem-net-devices-<iface>.device.wants/` link, which is what re-applies
  the setting when the interface comes back;
- the operator cannot read every file and directory in the unit directory. systemd
  reads them as root, so an unreadable file could still set EEE;
- a backup for this revision already exists.

Only `/etc/systemd/system` is scanned. Units under `/run` or `/usr/lib` and other
tools such as NetworkManager are out of scope.

The dry-run prints the current EEE status and exactly what `--apply` would back
up, install, and adopt.

### Adopting the ad-hoc unit

With `--apply` the deploy:

1. copies every file it will replace or remove (the ad-hoc unit, a previous
   managed template) to `<name>.previous-<revision>` in the unit directory. Until
   every backup exists, nothing is changed;
2. installs the rendered template, reloads systemd, enables and restarts
   `brokkr-eee-off@<iface>.service`;
3. verifies that the instance is active and `ethtool --show-eee` reports
   `disabled`;
4. only then disables and removes `<iface>-eee-off.service`, so exactly one unit
   owns the setting afterwards.

If step 2 or 3 fails, the ad-hoc unit stays enabled and in charge. Re-running the
same revision on a node that is already in place changes nothing.

### Rollback

Every `--apply` that changed something prints a rollback recipe listing only the
steps that run completed. It first stops the managed instance if it was inactive
before, and disables it if this run enabled it. It removes the template or
restores the previous version, restores and re-enables the ad-hoc unit, and
reloads systemd. Last, it restarts the instance on the previous template if the
instance was active before. Activity and enablement are restored independently. The tests run the
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

Tests: [`scripts/test/deploy-eee-off.test.sh`](../scripts/test/deploy-eee-off.test.sh)
(hermetic; ssh, sudo, systemctl, ethtool and id are fakes).
