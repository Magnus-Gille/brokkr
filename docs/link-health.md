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
| More carrier losses than logged drops since a sample in the last 24 h | `/sys/class/net/<iface>/carrier_down_count` | `unknown: carrier went down …`; the excess counts toward the drop thresholds |
| Any of the above unavailable or unparsable | — | WARN (`unknown: …`), never OK |

The speed check is what catches the stable-but-slow state: once a port has
settled at a lower speed there are no further drops to count. The detail line
includes the link partner's highest advertised speed, which shows whether the
other end has stopped offering the expected rate.

The journal is only trusted after a system-journal record has been read,
so a reader without journal access cannot mistake an empty result for zero
drops. The 24 h query matches `_TRANSPORT=kernel` rather than using
`journalctl -k`, which implies `-b` and would hide drops from before a reboot
inside the window. Coverage is proven by any system-journal record from
before the window, not only a kernel one: a healthy kernel can stay silent for
days. That proof only stands while journald reads kernel messages: if the
effective `ReadKMsg=` is off, or `systemd-analyze cat-config` cannot show it,
the counts are `unknown` (only `[Journal]` assignments count, and a non-boolean
value is `unknown`). The configuration shows the current state only, which is why
the carrier cross-check below exists. When no such record exists (a volatile or
vacuumed journal after a reboot), the counts are lower bounds,
shown as `drops24h>=N`. Unless they already cross a threshold, the result is
`unknown: kernel journal covers only …`, never a clean zero. Records stamped
after the observation time (a clock correction) are ignored. A boot or resume
can log one `Link is Down`, which is why the 24 h warning starts at two.

The kernel counts every carrier loss in `carrier_down_count` itself, independent
of journald, so it cross-checks the journal. Each run records a carrier sample,
and the baseline keeps the samples from the last 24 h. More carrier losses since
any of those samples than `Link is Down` records since that sample prove the
journal incomplete: for example, kernel ingestion was off earlier in the window
and re-enabled without a journald restart, or the driver logs link loss in
wording the probe does not recognise. The result is then
`unknown: carrier went down Nx in Ts but the kernel journal shows M`, and the
drop counts become lower bounds that include the N − M missing drops. Those
can cross the thresholds on their own: with the default `DROPS_1H_FAIL=3`, three
unlogged losses between two runs 15 minutes apart fail the 1 h check. Only
samples at most an hour old count toward the 1 h window. Because every sample in
the window is compared, the missing drops stay counted, and the result stays at
least WARN, until the sample before them is 24 h old. A record that reaches the
journal late reconciles on the next run. When the journal is unreadable, the
carrier delta alone is the lower bound. A carrier loss that the driver does not
log also counts as a missing drop for 24 h: for example an administrative
`ip link set down` or a suspend. Kernels before Linux 4.16 have no
`carrier_down_count`; the detail line then shows `carrier-down=unavailable`, the
other checks are unchanged, and a past ingestion gap there is not detected.

Error-counter and carrier deltas use a per-interface baseline in
`$BROKKR_STATE_DIR/link-health/`; the detail line shows both deltas against the
previous run. The first run, an unreadable baseline, a counter reset (reboot or
driver reload), and a baseline older than 24 h or from a later clock all record
a new baseline (`errors=baseline`, `carrier-down=baseline`; a changed kernel
`boot_id` also resets the carrier samples) and report the affected check as
unknown (WARN) for that one run, because there is no comparison yet; the
flapping signal is then `unknown` too. A baseline written before the
carrier count was recorded (an upgrade), or a negative or non-integer value in
it, is unknown in the same way. Counters come from `ethtool -S`, falling back
to the generic `/sys/class/net/<iface>/statistics` counters for drivers that do
not name `tx_errors`/`rx_errors`. When neither source is readable, the error
baseline is left untouched, so the next run compares over the longer interval,
and the carrier samples are still recorded. The error check compares one run
with the next, so a slow steady error rate below `ERRORS_WARN` per interval
does not alert.

## Configuration

Copy [`network/link-health.example.conf`](../network/link-health.example.conf)
to the host, set one `LINK=<iface>,<expected-min-mbps>[,<phy-name>]` record per
wired interface, and `chmod 600` it. The file is parsed as data, must be a
regular non-symlink owned by the reading user with no group/other access, and
any unknown key or invalid value fails closed. Thresholds are optional keys in
the same file. The PHY name is needed to attribute downshift messages, because
phylib logs them under the PHY device rather than the interface.
`check-link-health.py --check-config` runs only the parser (no NIC or journal
access): exit 0 when valid, 2 when not; deployment preflight uses it. Live
interface names and PHY identifiers stay in the untracked host copy.

## Reporting paths

- **NAS platform report.** When `BROKKR_LINK_HEALTH_CONFIG` names the config,
  [`heimdall/report.sh`](../heimdall/report.sh) adds a `link-health` row to the
  `hw-health` panel. Without it, the report is unchanged. The tracked
  `brokkr-health.service` sets neither that variable nor journal access, so
  enabling the row needs a drop-in (`systemctl edit brokkr-health.service`)
  adding `Environment=BROKKR_LINK_HEALTH_CONFIG=<runtime-home>/.config/brokkr/link-health.conf`
  and `SupplementaryGroups=systemd-journal`; without the group the row stays at
  `WARN: unknown: kernel journal unreadable`.
- **Other fleet nodes.** [`scripts/link-health-snapshot.sh`](../scripts/link-health-snapshot.sh)
  publishes one Heimdall panel per node, `link-health-<node>` (the short hostname,
  lower-cased; override with `BROKKR_LINK_HEALTH_NODE`), so one node's report can
  never overwrite another's; node names must be unique in the fleet (at most 40
  characters after sanitising). It is driven every 15 minutes by
  the user timer in [`systemd/user/`](../systemd/user/). The units run as the
  operator's own login user (user lingering keeps them alive without a session),
  read the kernel journal through that user's `adm` membership, and require the
  Heimdall delivery env file. A warning or failure is delivered and exits 0,
  while a missing configuration or failed push exits non-zero. Install with
  [`scripts/deploy-link-health.sh`](../scripts/deploy-link-health.sh), below.
- **Platform faults.** `check-link-health.py --signals` prints
  `network_link_flapping` and `network_link_degraded` signals for a
  `brokkr-platform-observation`. [`platform-fault-detector.mjs`](../scripts/platform-fault-detector.mjs)
  maps them to `network-link-flapping` (critical) and `network-link-degraded`
  (warning) faults owned by the operator. Missing evidence is signalled as
  `unknown`, never `ok`; the detector, like its other signals, emits faults
  only for `fault`, so a consumer must treat an `unknown` signal as an alert
  in its own right rather than read an empty fault batch as healthy.

Run only one of these per host: they share the counter baseline, so two
consumers would each see part of the delta.

## Install and rollback

Nothing is installed by this repository's tests or CI. Fleet nodes install the
probe as a revision-bound user-unit release, pushed from the control node over
ssh by [`scripts/deploy-link-health.sh`](../scripts/deploy-link-health.sh). The
node needs a non-root login user with lingering enabled
(`loginctl enable-linger`), membership of group `adm`, `python3`, and two
protected files owned by that user with mode `600`: the Heimdall delivery env
(`HEIMDALL_HUB_URL`, `HEIMDALL_FLEET_TOKEN`; its path differs per host, so it is
an explicit parameter) and the link config
([`network/link-health.example.conf`](../network/link-health.example.conf),
default `${XDG_CONFIG_HOME:-~/.config}/brokkr/link-health.conf`).

```sh
# Dry-run (default): remote preflight only, nothing is changed.
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT="<full-40-char-sha>" \
BROKKR_LINK_HEALTH_DELIVERY_ENV=/home/operator/.config/brokkr/env \
  scripts/deploy-link-health.sh operator@node-a.example

# Install: same environment plus --apply (optionally BROKKR_LINK_HEALTH_CONFIG=<remote path>).
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT="<full-40-char-sha>" \
BROKKR_LINK_HEALTH_DELIVERY_ENV=/home/operator/.config/brokkr/env \
  scripts/deploy-link-health.sh --apply operator@node-a.example
```

`BROKKR_EXPECTED_COMMIT` must be the full SHA of the clean checkout at
`BROKKR_EXPECTED_SOURCE`; the payload is the committed archive of that revision,
never the working tree, and only the probe, the snapshot runner, the Heimdall
push helper and the two unit templates are shipped. The remote preflight (also
run by the dry-run) refuses unless the user is not root, lingering is enabled,
both protected files are regular non-symlink files owned by the user with mode
`600`, the delivery env has non-empty `HEIMDALL_HUB_URL` and
`HEIMDALL_FLEET_TOKEN` exactly once each and sets none of the variables that
steer the probe (`PATH`, `HOME`, `BROKKR_LINK_HEALTH_CONFIG`, `BROKKR_STATE_DIR`,
`BROKKR_ETHTOOL`, ...; systemd applies the env file after the unit's own
`Environment=`; unrelated keys of a shared file are fine), the link config passes the shipped probe's own parser
(`check-link-health.py --check-config`), and the release for that SHA does not
yet exist. Secret values are never printed.

`ethtool` is required. If it is missing, the dry-run reports it and `--apply`
installs it with `sudo -n apt-get install -y --no-install-recommends ethtool`,
failing closed when `sudo -n`, `apt-get` or the install is unavailable. The
install happens only after the payload has been received and validated, and the
verified absolute path is rendered into the unit as `BROKKR_ETHTOOL` (a user
manager's `PATH` may lack `/usr/sbin`); the rollback output mentions the package
side effect.

`--apply` stages the payload, moves it to
`~/.local/lib/brokkr/link-health/releases/<SHA>`, saves any existing units as
`<unit>.previous-<SHA>` (both backups exist before either unit is replaced), renders the units into
`${XDG_CONFIG_HOME:-~/.config}/systemd/user/`, runs
`systemctl --user daemon-reload` and `enable --now brokkr-link-health.timer`,
then runs the service once and prints its result, the probe's detail line and
the last log line. A first run that does not leave a freshly written
`~/.local/state/brokkr/link-health.json` counts as a failure. The user units drop `OnFailure=` (the failure-notification
unit is system-scoped) and `SupplementaryGroups=` (invalid in user scope); the
sandboxing options (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem`,
`ProtectHome`) are kept, so a host that forbids user-namespace sandboxing fails
the first run visibly instead of silently.

The script prints the exact rollback recipe for the host. In outline, as the
runtime user: `systemctl --user disable --now brokkr-link-health.timer`, stop
the service, move each `<unit>.previous-<SHA>` back (or delete the unit if there
was none), `systemctl --user daemon-reload`, and optionally remove the release
directory. The probe never changes link settings, so there is nothing else to
undo.

When the probe warns or fails, swap the cable before suspecting the NIC or
driver: a failing pair commonly shows up as repeated short drops, a PHY
downshift (2.5G to 1G), and then a stable lower speed that the other end
advertises as its ceiling.
