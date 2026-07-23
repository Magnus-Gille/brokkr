# Systemd failure monitor

`brokkr#6` makes failed **system** services fail loud on every host that
installs the Brokkr monitor. It covers timer-driven oneshots: a timer can remain
healthy while its service is `failed`, so timer liveness alone is not evidence
that the work ran.

## Design and ownership

Brokkr owns the substrate concern: detect and deliver the fact that a systemd
service is failed. The owning service still defines what its work means and how
to repair it. This monitor neither restarts a service nor changes its data; it
only reports the failure and recovery.

Two paths use one durable state directory:

1. `brokkr-systemd-failure@.service` is the reusable immediate handler. A
   system-service owner opts in with `OnFailure=brokkr-systemd-failure@%n.service`.
2. `brokkr-systemd-failure-sweep.timer` runs every two minutes and reconciles
   every failed system service on the host. It catches timer-driven oneshots and
   services that have not adopted `OnFailure=` yet.

The common state file is
`${BROKKR_STATE_DIR:-~/.local/state/brokkr}/systemd-failures/failed-units`.
It means an OnFailure handler followed by a sweep produces one alert, not two.
Each newly failed unit gets an authenticated Heimdall `systemd-failures` panel
update and a best-effort operator notification through `scripts/lib/notify.sh`.
When a unit leaves failed state, the monitor sends one recovery and updates the
same panel. The panel is refreshed on every sweep; notification delivery is
deduplicated. A failed Heimdall push leaves the previous state in place, so the
next run retries rather than claiming the incident was delivered.

The handler and sweep deliberately have no `OnFailure=` themselves: recursively
alerting a broken alert path would create a failure storm. Their non-zero status
is visible in journald and retried by the sweep. The off-box control-node
dead-man remains the independent answer for loss of the host or its local alert
path.

## Configuration

The monitor requires both values in the existing owner-only Brokkr environment
file, normally `/home/brokkr/.config/brokkr/env`:

```text
HEIMDALL_HUB_URL=https://heimdall.example/api/panels
HEIMDALL_FLEET_TOKEN=replace-with-local-secret
```

It fails non-zero when either is absent; a configured-looking monitor may not
silently skip delivery. `scripts/lib/notify.sh` then optionally adds the
established Ratatoskr/direct-Telegram fallback. It is secondary to the
authenticated Heimdall upsert and remains best effort by that helper's contract.
Never commit the environment file or any values from it.

## Install after merge

This pull request does not deploy or restart anything. After it is merged, use
the normal role deployment from a clean checkout:

```bash
# control node (installs the template, sweep, and Brokkr maintenance OnFailure hooks)
BROKKR_SSH_TARGET=brokkr@control-node ./scripts/deploy-control-node.sh

# NAS (installs the template, sweep, and Brokkr health OnFailure hook)
BROKKR_SSH_TARGET=brokkr@nas-host ./scripts/deploy-nas.sh
```

For another host, copy the three versioned files below to
`/etc/systemd/system/`, run `systemctl daemon-reload`, then enable only the
sweep timer. Do this through that host's approved deployment path, not from a
service repository:

```text
brokkr-systemd-failure@.service
brokkr-systemd-failure-sweep.service
brokkr-systemd-failure-sweep.timer
```

Any system service may add the template opt-in after the template is installed:

```ini
[Unit]
OnFailure=brokkr-systemd-failure@%n.service
```

No service needs to own or duplicate the sweep. `brokkr#6` is limited to
detection/delivery; relocation attribution, drain, mutation, and rollback remain
with the separately owned reconciliation lifecycle.

## Acceptance and rollback

After deployment, first verify configuration and timer scheduling without
inducing a failure:

```bash
systemctl list-timers brokkr-systemd-failure-sweep.timer
systemctl start brokkr-systemd-failure-sweep.service
journalctl -u brokkr-systemd-failure-sweep.service -n 30 --no-pager
```

The run should create or refresh the `systemd-failures` Heimdall panel. A safe
production drill uses a disposable system service that exits non-zero, confirms
one fail notification/panel state, repairs it, then confirms exactly one
recovery. Do not fail a production backup or maintenance unit to test this.

To roll back, disable and stop the sweep timer, remove the three monitor unit
files and any `OnFailure=` lines added to service units, then run
`systemctl daemon-reload`. The state directory is evidence, not a runtime
dependency; retain it for incident review or move it aside before a clean
re-install. This rollback does not restart application services or repair their
underlying failures.
