# Systemd supervision baseline

`systemd-supervision-baseline-v1.json` is the versioned substrate policy for
long-running services, `Type=oneshot` services, and timers. The accompanying
schemas describe the policy, the sanitized declaration projection, the
content-blind observation record, and the audit result.

## Authority and ownership

The Grimnir service registry remains the only topology authority. It supplies
component ownership, unit type, and system/user manager scope. The declaration
projection may contain only the directives needed by this audit; it must not
repeat scope, owner, workload shape, commands, paths, environment, or unit
content. A declaration for a unit absent from the registry is rejected.

The registry accepts its current bare `systemd_units[].name` plus `type` shape:
`name: "heimdall-collect", type: "timer"` becomes the effective
`heimdall-collect.timer` identity, and an omitted scope defaults to `system`.
Canonical effective names are the audit's declaration and observation
projection format and its output format. Registry names are normalized once at
the input boundary; a wrong suffix, repeated suffix, or duplicate effective
identity is rejected, so a registry cannot create two meanings for one unit.
Timer `Unit=` references may be canonical or a uniquely resolvable bare name
and are checked after this same normalization.

Brokkr owns the substrate semantics and audit. Component repositories own
heartbeat and readiness implementation. A missing capability is emitted as a
`component-owner` finding and is not repaired by this repository.

The system-scope failure path is the delivered `brokkr#6` monitor target,
`brokkr-systemd-failure@%n.service`. Its periodic sweep is a backstop, not a
second per-unit delivery path. User-manager units must name a non-empty,
sanitized component-owner failure unit or target in `OnFailure=` (a local
`.service` or `.target` name using only the safe unit characters); the audit
does not emit that value. The system-manager target, or a target containing its
reserved Brokkr identity, is rejected for user units. `failure_delivery:
component-owner` by itself is therefore insufficient evidence.

## Baseline rules

Long-running services require an allowed failure restart policy (`on-failure`
or `on-abnormal`), a bounded restart delay, start-limit interval and burst,
startup/shutdown/runtime timeout directives, explicit `OOMPolicy=stop` or
`kill`, and failure delivery. Their readiness and heartbeat capabilities are
component-owned findings. `WatchdogSec=` is accepted only for `Type=notify`
when the component heartbeat is present and a live-lock fixture is recorded as
passed.

Oneshot services require `Type=oneshot`, `Restart=no` without `RestartSec=`,
the same bounded start-limit and timeout protection, explicit OOM behavior,
and the #6 system failure path when they run under the system manager.

Timers require a service target in the same registry-owned component and
manager scope, an explicit schedule, bounded `AccuracySec=`, and
`Persistent=true`. When `Unit=` is omitted, the audit follows systemd's
default target rule (`<timer basename>.service`) and only passes it when that
effective service is present in the same registry owner and manager scope; an
unresolvable default is a target finding, not a blanket prohibition on omitted
`Unit=`. The observation must carry last run, next run, last result, missed-run
count, and persistence evidence. Missed runs are findings even when the timer
is otherwise active.

## Read-only audit

The audit consumes a sanitized declaration projection, the existing registry,
and content-blind observations. It never invokes `systemctl`, writes unit
files, enables timers, restarts services, or calls the notifier:

```bash
make systemd-supervision-audit ARGS="--baseline docs/systemd-supervision-baseline-v1.json --registry /path/to/services.json --declarations declarations.json --observations observations.json --now 2026-08-02T12:00:00Z"
```

The result reports registry-derived scope and workload shape, unit result,
restart count/window, watchdog and OOM result, timer last/next run, notifier
availability, freshness, and typed findings. It deliberately omits command
lines, environment values, journal text, endpoint values, credentials, and
private locators. A finding makes the command exit non-zero while still
emitting the public-safe audit record; malformed or content-bearing input is
rejected before an audit record is produced.

## Deferred live certification

This change is fixture- and projection-only. A later attended hardware window
must separately verify, for each declared system and user manager:

1. `systemd-analyze verify` accepts the rendered unit set without unsafe or
   contradictory directives.
2. A metadata-only `systemctl show`/`systemctl --user show` capture contains
   the result, restart count/window, watchdog result, OOM result, and timer
   last/next-run fields expected by the observation schema.
3. A disposable restart-storm fixture reaches the configured start limit and
   the #6 failure delivery path remains deduplicated.
4. A disposable OOM fixture records the expected OOM result without changing
   an owning component unit.
5. A disposable live-lock fixture proves the application heartbeat and
   `WatchdogSec=` negotiation before watchdog is enabled.
6. A missed timer run proves `Persistent=true` recovery semantics and the
   resulting evidence, while an absent notifier and stale observation remain
   visible as findings.

No live node, hardware, notifier, unit installation, or deployment is certified
by this repository change.
