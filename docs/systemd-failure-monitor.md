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

On the control node, `deploy-control-node.sh` requires two explicit deployment
inputs before it enables the sweep:

- `BROKKR_HEIMDALL_URL` — the non-secret `http(s)` panel endpoint.
- `BROKKR_HEIMDALL_TOKEN_SOURCE` — an absolute, server-side file containing
  exactly one non-empty `HEIMDALL_FLEET_TOKEN=` assignment.

The token source is parsed, never sourced. It must be a regular, non-symlink,
root-owned file with mode `0400` or `0600`; its path and value are never printed.
Its value must use the standard Bearer-token (`b64token`) alphabet so it can be
passed safely to the probe's stdin-only curl configuration.
The installer derives the runtime user's mode-`0600` environment file from the
explicit URL and token source. A missing, malformed, or unsafe source aborts
before any timer is enabled.

Before it writes runtime state or enables a timer, the installer also proves
that the explicit runtime user exists, its non-symlink home is writable, and
that user can read the selected registry. Finally it performs an authenticated
`GET /api/panels?service=brokkr` readback from the control node. Only a 2xx
result passes; unreachable, redirected, or unauthorized endpoints abort without
enabling timers. The server-side probe sends the token to curl through stdin
configuration, never command arguments or output, and does not mutate panels.

## Install after merge

This pull request does not deploy or restart anything. After it is merged, use
the normal role deployment from a clean checkout:

```bash
# control node: choose an independent release target and explicit runtime identity.
# The token source is created server-side by the operator and is never committed.
BROKKR_SSH_TARGET=operator@control-node \
BROKKR_DEPLOY_TARGET=/srv/brokkr-release \
BROKKR_RUNTIME_USER=operator \
BROKKR_RUNTIME_HOME=/home/operator \
BROKKR_REGISTRY_PATH=/srv/grimnir/services.json \
BROKKR_HEIMDALL_URL=https://heimdall.example/api/panels \
BROKKR_HEIMDALL_TOKEN_SOURCE=/etc/brokkr/heimdall-fleet-token.env \
  ./scripts/deploy-control-node.sh

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

The control-node installer renders its four service units from the tracked
clean-install defaults into `/etc/systemd/system/` using the explicit runtime
values. It therefore does not execute monitor code from a canonical checkout.
The deploy target is the release copy synchronized by the installer; choose a
separate path rather than a development worktree or checkout.
`BROKKR_REGISTRY_PATH` is rendered into the maintenance units and defaults to
`/opt/grimnir/services.json` for a clean install; set it explicitly when the
host keeps its checked-out registry elsewhere.

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
