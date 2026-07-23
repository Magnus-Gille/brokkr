# NAS deployment

`scripts/deploy-nas.sh` installs a release copy, not a development checkout. It
requires explicit values for the runtime user, home, release target, and Grimnir
registry path. This prevents an NAS deployment from silently inheriting the old
`brokkr` account or `/opt/brokkr` layout.

## Deploy after merge

Run from a clean Brokkr checkout with a passwordless-sudo SSH account. These are
examples only; use the NAS's real non-secret layout values.

```bash
BROKKR_SSH_TARGET=operator@nas-host \
BROKKR_DEPLOY_TARGET=/srv/brokkr-release \
BROKKR_RUNTIME_USER=operator \
BROKKR_RUNTIME_HOME=/home/operator \
BROKKR_REGISTRY_PATH=/srv/grimnir/services.json \
BROKKR_HEIMDALL_SOURCE_ENV=/etc/brokkr/heimdall-source.env \
  ./scripts/deploy-nas.sh
```

The optional Heimdall source is a server-side, root-owned regular file with mode
`0400` or `0600`. It must contain exactly one non-empty
`HEIMDALL_HUB_URL=` and `HEIMDALL_FLEET_TOKEN=` assignment. The deployer copies
only those assignments into the runtime user's `~/.config/brokkr/env` with mode
`0600`; it never prints their values or the source path. Omitting the source is
supported for an intentionally unconfigured push path.

Before synchronizing a first release, the deployer creates the nested target as
the runtime user. An existing target must be a non-symlink, runtime-user-owned,
writable directory. It also verifies the runtime home and registry before
rendering, and renders health plus systemd-failure services for the supplied
identity and paths. `systemd-analyze verify` and executable-mode checks finish
before any `/etc/systemd/system` mutation or timer enablement.

## Post-deploy verification

The deployer starts one health snapshot and shows both timers. Independently
verify the installed, rendered configuration and delivery path:

```bash
sudo systemctl cat brokkr-health.service
sudo systemctl cat 'brokkr-systemd-failure@.service'
sudo systemctl list-timers brokkr-health.timer brokkr-systemd-failure-sweep.timer
sudo systemctl start brokkr-systemd-failure-sweep.service
sudo journalctl -u brokkr-health.service -u brokkr-systemd-failure-sweep.service -n 30 --no-pager
```

Confirm that the rendered `User=`, `WorkingDirectory=`, `EnvironmentFile=`, and
`ExecStart=` lines match the selected runtime layout. Do not induce a real backup
or production-service failure merely to exercise the failure monitor.

## Rollback

To remove this deployment's timer activation without restarting unrelated
services, first retain a copy of the rendered units for incident evidence, then:

```bash
sudo systemctl disable --now brokkr-health.timer brokkr-systemd-failure-sweep.timer
sudo rm -f /etc/systemd/system/brokkr-health.service \
  /etc/systemd/system/brokkr-health.timer \
  '/etc/systemd/system/brokkr-systemd-failure@.service' \
  /etc/systemd/system/brokkr-systemd-failure-sweep.service \
  /etc/systemd/system/brokkr-systemd-failure-sweep.timer
sudo systemctl daemon-reload
```

If replacing an earlier installation, restore its saved unit files instead of
removing them, then run `daemon-reload` and re-enable only the timers that were
previously active. The release target and health state are evidence; retain them
until the rollback outcome is verified.
