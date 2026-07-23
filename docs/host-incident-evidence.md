# Host incident evidence

`brokkr#3` investigated a roughly 50-minute userspace stall followed by an
unattended reboot on the control node. The retrospective inspection could not
identify a root cause: the host retained only its current boot in journald and
`/sys/fs/pstore` was empty. A TCP connection can remain healthy while command
execution and local services are wedged, so that observation does not rule out
storage, memory, or kernel causes.

This guide preserves enough evidence to investigate the *next* incident. It
does not claim to diagnose the historical one.

## Preserve journal history

Review the tracked policy first. It makes the system journal persistent and
caps it at 256 MiB while keeping at least 1 GiB free, a conservative policy for
small SD-card-backed hosts.

```bash
./scripts/setup-persistent-journal.sh --dry-run
sudo ./scripts/setup-persistent-journal.sh --apply
```

The second command writes only
`/etc/systemd/journald.conf.d/60-brokkr-persistent.conf` and creates
`/var/log/journal`; it deliberately does **not** restart a service. The default
mode is dry-run, so no host mutation occurs until `--apply` is supplied. The
policy takes effect on the next boot. If activating it now is appropriate for
the host's maintenance window, make that separate choice explicitly:

```bash
sudo ./scripts/setup-persistent-journal.sh --apply --restart
```

After a planned reboot, verify that more than one boot is available:

```bash
sudo journalctl --list-boots
sudo journalctl -b -1 -p err..alert --no-pager
sudo journalctl -k -b -1 --no-pager | tail -200
sudo find /sys/fs/pstore -maxdepth 1 -type f -ls
```

The last command may be empty; pstore is hardware/firmware dependent. Do not
treat an empty pstore as evidence that a kernel or power fault did not occur.

## Liveness is a separate control

Persistent logs explain a past reboot. They do not alert while a host is
wedged. An on-host systemd failure sweep also cannot execute during a total
userspace stall and begins only after boot recovery.

Use Brokkr's off-box control-node dead-man check for that independent liveness
path; its monitor must be on a separately powered host and use a notification
route outside the control node's failure domain. Follow
[`control-node-deadman.md`](control-node-deadman.md), then verify its timer,
state, and direct notification fallback during a planned drill. If its state
or notification history is absent after an incident, record that as an alerting
gap rather than claiming it fired.

## Incident collection order

Before rebooting a degraded host, collect read-only evidence where possible:

```bash
uptime
free -h
df -h /
sudo journalctl -b -p err..alert --no-pager | tail -200
sudo journalctl -k -b --no-pager | tail -200
sudo systemctl --failed
sudo find /sys/fs/pstore -maxdepth 1 -type f -ls
```

Then capture the prior boot after recovery using the commands above. Keep the
output in the private incident record, not this public repository: journals can
contain service names, paths, and user data.
