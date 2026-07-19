# Control-Node Dead-Man Check

`brokkr#38` adds an off-box dead-man check for a deployment's `control-node`. If that host dies, an
on-host dashboard or watchdog cannot notice it.

This check belongs in Brokkr because it is substrate liveness: it survives changes to the individual
services running on the box. It deliberately does not inspect or restart application services.
Their service-level health definitions stay with their owning repositories and Heimdall.

## Runtime Shape

- Runs off-box on an independently powered monitoring host as a user systemd timer.
- Probes `http://control-node:3033/api/health` once per minute by default.
- Sends an alert after 3 consecutive misses.
- Repeats alerts no more than every 30 minutes while the host remains unreachable.
- Sends a recovery notice when the probe starts passing again.
- Optionally sends a provider-agnostic HTTPS missed-ping heartbeat, but only after the
  control-node probe passes. If the monitoring host or the whole site disappears, the provider stops
  receiving pings and alerts through an independently hosted delivery path.

The alert path uses `scripts/lib/notify.sh`. On healthy days it can call a preferred notifier such
as Ratatoskr. Because an operator may place that notifier in the target's failure domain, the
off-box host must also have `~/.config/grimnir/notify.env` with a direct Telegram fallback token as
documented in `scripts/lib/notify.env.example`. Keep that file mode `0600`; it contains alert
credentials. `notify.sh` has no default network destination: set `RATATOSKR_URL` explicitly in that
file to enable the preferred request. If it is absent, only an explicitly configured direct
Telegram token can send; with neither destination, notification is a local no-op.

Direct Telegram from the monitoring host and the external missed-ping path complement each other.
Direct Telegram gives fast target-down/recovery messages while that host is alive. The external
provider covers the failure case a same-site monitor cannot report: loss of the monitor, power,
internet, or the whole site.
The URL is optional in code so deployment can be prepared before a provider is chosen, but once a
protected URL file exists the installer and runtime both fail visibly if it is malformed or cannot
be reached.

## Install on a monitoring host

First make the Brokkr revision available in `~/repos/brokkr` on the monitoring host. Then run the
idempotent installer **on that host, as its service user (not root)**. By default the installer
expects the generic hostname `inference-host`; override `BROKKR_DEADMAN_EXPECTED_HOST` if your
monitoring role is named differently:

```bash
cd ~/repos/brokkr
./scripts/deploy-control-node-deadman.sh
```

The installer makes no unit changes until all of these gates pass:

1. Hostname matches `BROKKR_DEADMAN_EXPECTED_HOST` and the installer is not running as root.
   It also requires the canonical `~/repos/brokkr` checkout because that is the path executed by
   the version-controlled service unit.
2. `~/.config/grimnir/notify.env` is owned by the invoking user, mode `0600` or `0400`, and
   contains exactly one non-empty `RATATOSKR_SEND_API_KEY` and `TELEGRAM_BOT_TOKEN` assignment plus numeric
   `TELEGRAM_ALLOWED_USERS`. Values are never printed. The direct bot token is mandatory because
   the preferred notifier may share the target's failure domain.
3. The production control-node probe passes.
4. If `~/.config/grimnir/deadman-external.env` exists, it is an owner-only regular file with
   exactly one valid HTTPS heartbeat URL.
5. The user systemd manager is reachable and lingering is enabled.
6. Only after gates 3 and 5 pass, the installer sends the external preflight ping. It disables
   `~/.curlrc`, accepts only a direct 2xx response (no redirects), never prints the URL, and refuses
   unit mutation if delivery fails.

It snapshots the prior units, timer enable/active state, and dead-man state; stops an active prior
timer; installs and reloads the units; and runs one production service probe. The timer is enabled
**last**, only after the service writes a fresh `pass` state and, when configured, a fresh
`last-external-success` timestamp. Any failure after mutation restores the snapshot. The Telegram
credential file remains mandatory at runtime, so removing it makes the unit fail instead of
silently running without its alert path. Rollback always disables candidate timer enablement before
removing its unit, then restores the prior enable/active state. If rollback itself is incomplete,
the installer preserves its mode-`0700` recovery snapshot and prints that local path for manual
recovery instead of destroying evidence. Re-running the installer is safe. Verify:

```bash
systemctl --user list-timers brokkr-control-node-deadman.timer
systemctl --user start brokkr-control-node-deadman.service
journalctl --user -u brokkr-control-node-deadman.service -n 50 --no-pager
```

## Configuration

| Variable | Default | Meaning |
|---|---:|---|
| `CONTROL_NODE_DEADMAN_URL` | `http://control-node:3033/api/health` | Probe URL. |
| `CONTROL_NODE_DEADMAN_TIMEOUT_SECS` | `8` | Curl timeout per probe. |
| `CONTROL_NODE_DEADMAN_FAIL_AFTER` | `3` | Consecutive misses before alerting. |
| `CONTROL_NODE_DEADMAN_ALERT_COOLDOWN_SECS` | `1800` | Minimum seconds between repeated failure alerts. |
| `CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL` | unset | Secret provider-issued HTTPS missed-ping URL. Loaded from the protected external env file by systemd. |
| `CONTROL_NODE_DEADMAN_EXTERNAL_TIMEOUT_SECS` | `8` | Curl timeout for the optional external ping. |
| `BROKKR_STATE_DIR` | `~/.local/state/brokkr` | State directory for miss count, last alert, and recovery state. |

## External missed-ping setup

The operator must supply one piece of external state that this repo cannot safely create: a
provider-generated **HTTPS ping URL** for a missed-ping monitor. The provider/check should:

- accept an unauthenticated HTTP GET to its secret URL;
- expect a ping approximately every minute, with at least a five-minute total late/grace window
  for timer jitter, reboot, and transient network loss;
- alert through infrastructure independent of the home site and tailnet (email, provider app push,
  SMS, or another independently hosted path);
- treat the full URL as a bearer secret and allow it to be rotated.

Do not paste the URL into a shell command, ticket, commit, or transcript. On the monitoring host,
create the file with an editor so the value does not enter shell history:

```bash
cd ~/repos/brokkr
install -m 0600 scripts/lib/deadman-external.env.example \
  ~/.config/grimnir/deadman-external.env
${EDITOR:-vi} ~/.config/grimnir/deadman-external.env
./scripts/deploy-control-node-deadman.sh
```

The populated file must contain exactly one assignment:

```text
CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL=https://provider.example/secret-ping-path
```

The example above is deliberately fake. The installer validates ownership, mode, uniqueness,
HTTPS, target health, user-manager readiness, and a direct provider 2xx before changing units.
Both external calls disable user curl configuration and pass the URL to curl over stdin rather
than argv; redirects are rejected and logs contain only redacted success/failure messages.

Verify without displaying the URL:

```bash
systemctl --user start brokkr-control-node-deadman.service
test -s ~/.local/state/brokkr/control-node-deadman/last-external-success
journalctl --user -u brokkr-control-node-deadman.service -n 20 --no-pager
```

Finally, confirm the provider UI shows a recent ping and use its built-in **test notification**
feature if available. If the provider has no such feature, create a separate disposable check and
let that check lapse; do not blackhole the production timer or expose its secret URL just to test
notification delivery.

## Acceptance Drill

Run the two drills separately. A target blackhole proves threshold/recovery behavior, but it does
**not** prove the direct fallback because Ratatoskr remains reachable during that drill.

### 1. Target-blackhole and recovery drill

Run the script directly with an isolated state root. This leaves the enabled timer and its
production state untouched:

```bash
cd ~/repos/brokkr
drill_root="$(mktemp -d)"

for attempt in 1 2 3; do
  BROKKR_STATE_DIR="$drill_root" \
  CONTROL_NODE_DEADMAN_URL=http://127.0.0.1:9/ \
  ./scripts/control-node-deadman.sh
done

BROKKR_STATE_DIR="$drill_root" ./scripts/control-node-deadman.sh
```

Expected: one Telegram alert after the third miss, followed by one recovery Telegram from the
normal-URL run. Do not use `systemctl --user set-environment` for this drill: the service unit's
explicit `Environment=CONTROL_NODE_DEADMAN_URL=...` takes precedence, so that command does not
blackhole this unit.

### 2. Ratatoskr-blackhole fallback drill

This forces only the preferred Ratatoskr path to fail. The helper must fall through to the direct
Telegram Bot API using `TELEGRAM_BOT_TOKEN` from the protected file:

```bash
cd ~/repos/brokkr
RATATOSKR_URL=http://127.0.0.1:9/ \
RATATOSKR_ENV="$HOME/.config/grimnir/not-present" \
NOTIFY_ENV="$HOME/.config/grimnir/notify.env" \
bash -c 'source scripts/lib/notify.sh; notify_telegram "Brokkr dead-man direct fallback drill from monitoring host"'
```

Expected: a Telegram message containing `direct fallback drill from monitoring host`. Receipt of
that message is the live credential/delivery gate; the script intentionally treats notification as
best-effort.

### Cleanup and recovery

The direct drill creates no systemd override or manager environment. Remove only its isolated
state, then re-run the production unit and confirm it records `pass`:

```bash
rm -rf "$drill_root"
unset drill_root
systemctl --user start brokkr-control-node-deadman.service
test "$(cat ~/.local/state/brokkr/control-node-deadman/state)" = pass
systemctl --user is-enabled --quiet brokkr-control-node-deadman.timer
systemctl --user is-active --quiet brokkr-control-node-deadman.timer
```

Do not delete `~/.local/state/brokkr/control-node-deadman`; that is the live timer's state. If a
future drill uses a runtime drop-in instead, remove it, run `systemctl --user daemon-reload`, and
start the production service before considering recovery complete.

## Migration from earlier site-specific names

This public interface replaces earlier site-specific script, unit, environment-variable, and state
names. Before enabling this timer, disable and remove the corresponding locally named dead-man
units, then run the installer above. Copy only non-secret counters that are still operationally
useful into `~/.local/state/brokkr/control-node-deadman`; do not copy credentials into the state
directory. No compatibility aliases are tracked because they would preserve private deployment
identity in the public repository.
