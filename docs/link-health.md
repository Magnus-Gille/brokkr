# Wired-link health

A wired link can flap or negotiate down while every service on the host stays
up, because a fallback route (for example wifi) quietly carries the traffic.
No systemd unit fails, so neither the failed-unit monitor nor service health
checks notice. In one fleet incident a faulty Ethernet cable caused hundreds of
two-second link drops per week for four weeks, after which the router held
the port at 100 Mb/s on a 2.5 Gb/s NIC: stable, 25 times slower, and unalerted
until someone copied a large archive. The fault followed the cable when it was
swapped.

[`network/check-link-health.py`](../network/check-link-health.py) looks at the
link itself. For each configured wired interface it reports:

| Evidence | Source | Default result |
|---|---|---|
| Link not detected now | `ethtool <iface>` | FAIL |
| Negotiated speed below the configured minimum | `ethtool <iface>` | WARN |
| Kernel `Link is Down` events, last hour | `journalctl -k` | FAIL at ≥ 3 |
| Kernel `Link is Down` events, last 24 h | `journalctl -k` | WARN at ≥ 2, FAIL at ≥ 24 |
| PHY `Downshift occurred` events, last 24 h | `journalctl -k` | WARN at ≥ 1 |
| Growth of `tx_errors + rx_errors` since the previous run | `ethtool -S <iface>` | WARN at ≥ 10 |
| Any of the above unavailable or unparsable | — | WARN (`unknown: …`), never OK |

The speed check is what catches the stable-but-slow state: once a port has
settled at a lower speed there are no further drops to count. The detail line
includes the link partner's highest advertised speed, which shows whether the
other end has stopped offering the expected rate.

The journal is only trusted after a current-boot kernel record has been read,
so a reader without journal access cannot mistake an empty result for zero
drops. Error-counter deltas use a per-interface baseline in
`$BROKKR_STATE_DIR/link-health/`; the first run, a counter reset (reboot or
driver reload), or a baseline older than 24 h records a new baseline
(`errors=baseline`) without alerting.

## Configuration

Copy [`network/link-health.example.conf`](../network/link-health.example.conf)
to the host, set one `LINK=<iface>,<expected-min-mbps>[,<phy-name>]` record per
wired interface, and `chmod 600` it. The file is parsed as data, must be a
regular non-symlink owned by the reading user with no group/other access, and
any unknown key or invalid value fails closed. Thresholds are optional keys in
the same file. The PHY name is needed to attribute downshift messages, because
phylib logs them under the PHY device rather than the interface. Live
interface names and PHY identifiers stay in the untracked host copy.

## Reporting paths

- **NAS platform report.** When `BROKKR_LINK_HEALTH_CONFIG` names the config,
  [`heimdall/report.sh`](../heimdall/report.sh) adds a `link-health` row to the
  `hw-health` panel. Without it, the report is unchanged.
- **Other fleet nodes.** [`scripts/link-health-snapshot.sh`](../scripts/link-health-snapshot.sh)
  publishes a dedicated `link-health` Heimdall panel, driven every 15 minutes by
  [`systemd/brokkr-link-health.timer`](../systemd/brokkr-link-health.timer). The
  service runs as the Brokkr user with `systemd-journal` as a supplementary group
  and requires the existing Heimdall environment file; a warning or failure is
  delivered and exits 0, while a missing configuration or failed push exits
  non-zero.
- **Platform faults.** `check-link-health.py --signals` prints
  `network_link_flapping` and `network_link_degraded` signals for a
  `brokkr-platform-observation`. [`platform-fault-detector.mjs`](../scripts/platform-fault-detector.mjs)
  maps them to `network-link-flapping` (critical) and `network-link-degraded`
  (warning) faults owned by the operator. Missing evidence is signalled as
  `unknown`, never `ok`.

Run only one of these per host: they share the error-counter baseline, so two
consumers would each see part of the delta.

## Install and rollback

Nothing is installed by this repository's tests or CI. On a node, through its
approved deployment path: place the protected config, copy
`brokkr-link-health.service` and `.timer` to `/etc/systemd/system/`, run
`systemctl daemon-reload`, then `systemctl enable --now brokkr-link-health.timer`.
Verify with `systemctl start brokkr-link-health.service` and
`journalctl -u brokkr-link-health.service -n 20`, and confirm the panel in
Heimdall. To roll back, disable the timer and remove the two units; the probe
never changes link settings, so there is nothing else to undo.

When the probe warns or fails, swap the cable before suspecting the NIC or
driver: a failing pair commonly shows up as repeated short drops, a PHY
downshift (2.5G to 1G), and then a stable lower speed that the other end
advertises as its ceiling.
