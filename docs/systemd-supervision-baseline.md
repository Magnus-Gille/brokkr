# Systemd supervision baseline

`systemd-supervision-baseline-v1.json` is Brokkr's versioned substrate policy
for long-running services, `Type=oneshot` services, and timers. Its schemas
bound the policy, the consumed Grimnir registry fields, sanitized declarations,
content-blind observations, and audit output. This extends the failure monitor
delivered by #6; it does not install units or create another topology source.

## Authority, identity, and normalization

Grimnir `services.json` remains the sole authority for component ownership,
stable `target_node_id`, system/user manager scope, and service-versus-timer
identity. Brokkr ignores host locators and unrelated registry fields. The
registry's current bare form is accepted: `{name: "heimdall-collect",
type: "timer"}` normalizes once to `heimdall-collect.timer`; an omitted scope
normalizes to `system`. Already canonical names are accepted when their suffix
agrees with `type`. Wrong, repeated, or ambiguous suffixes are malformed.

Declarations, observations, and output use canonical effective systemd names.
The stable join key is:

```
target_node_id + manager scope + effective unit name
```

That permits the same effective unit name on different nodes or manager scopes
without exposing a hostname. Duplicate component identities and duplicate
join keys are malformed. Unknown declaration or observation keys are also
hard-rejected, content-blindly, because the registry is authoritative.

Grimnir does not own workload shape. For registry services, sanitized `Type=`
selects `oneshot` versus long-running policy; registry `type` only distinguishes
services from timers. The declaration's finite `failure_handler_role` is an
audit role, not topology: `none` is ordinary, while `terminal` is allowed only
for the component-owned user-manager failure handler described below.

## Service policy and failure delivery

Long-running services require `Type=simple|exec|notify|forking`, an allowed
failure restart policy (`on-failure` or `on-abnormal`), a 1–60 second restart
delay, bounded start limits, startup/shutdown/runtime timeouts, and explicit
`OOMPolicy=stop|kill`. Oneshots require `Type=oneshot`, `Restart=no`, no
`RestartSec=`, and their own bounded start limits and timeouts. Readiness and
application heartbeat gaps are routed to the component owner; Brokkr never
edits component-owned units.

Every system-manager service must contain exactly one canonical #6 target:
`OnFailure=brokkr-systemd-failure@%n.service`. Repetition or any other value is
a finding. The #6 sweep remains a backstop, not another topology authority.

An ordinary user-manager service must contain exactly one sanitized `.service`
target. The target must resolve through the registry and declarations to the
same `target_node_id`, user manager, and owning component, and it must be
declared with `failure_handler_role: "terminal"`. The terminal handler is the
finite end of the delivery graph: it must be a registered user service with
`Type=oneshot`, `Restart=no`, and no `OnFailure`. It remains subject to normal
start limits, timeouts, OOM policy, and observed result evidence; only recursive
failure delivery is exempt. Self-targets, cycles, normal/nonterminal targets,
undeclared targets, invalid terminal handlers, multiple targets, and terminal
handlers that point onward are findings. System services and timers cannot use
the terminal role. Target values and declaration roles are never projected to
audit output.

## Timer policy

Timers reject service-only directives. They require exactly one schedule class
and bounded `AccuracySec`:

- Calendar/catch-up timers use a nonblank string `OnCalendar` value,
  `Persistent=true`, integer missed-run evidence, and observed persistence.
- Monotonic/current-state timers use at least one valid normalized
  `OnBootSec`, `OnStartupSec`, `OnUnitActiveSec`, or `OnUnitInactiveSec` value.
  `Persistent` must be absent or false, while observed persistence and
  missed-run evidence are `null` (not applicable).

`OnCalendar=false`, blank calendar strings, invalid/false monotonic values,
mixed calendar/monotonic schedules, and `Persistent` strings are rejected or
flagged according to schema-versus-semantic validity. Duration projection is
canonical integer-unit syntax (`250ms`, `5s`, `10min`, `2h`, or `1d`), plus
`infinity` only where the policy permits it. Collectors must normalize
fractional or compound systemd durations first—for example, `1.5s` to `1500ms`
and `1min 30s` to `90s`—rather than pass them through.

A timer target must be a declared ordinary service in the same registry owner,
node identity, and manager scope. Explicit `Unit=` accepts a canonical name or
a uniquely resolvable bare name. When it is omitted, the audit follows
systemd's legitimate default (`<timer basename>.service`) and applies the same
checks; explicit `Unit=` is not required merely for audit convenience.

## Evidence binding and findings

The observation record is metadata-only. It includes unit result, restart
count/window, watchdog result, OOM result, timer last/next run and catch-up
state, notifier availability, and `observed_at`; it contains no journal text,
commands, paths, environment, endpoint, credential, or host-locator values.

For services, restart evidence is usable only when `window_end` equals
`observed_at` and `window_start` equals `observed_at -
StartLimitIntervalSec`, each within the versioned one-second tolerance. Future,
reversed, old, or mismatched windows are findings. A restart storm is evaluated
only after both the interval and burst parse and the window binds correctly;
an invalid burst never coerces to zero.

Top-level evidence is fresh for 900 seconds. If `observed_at` is stale or ahead
of evaluation time, every registry unit receives a typed stale/future finding,
no such unit is counted compliant, and the top-level status fails. Timer last
runs ahead of observation time or older than the one-year evidence horizon are
findings. A next run beyond the one-year planning horizon, older than the
evidence horizon, before its last run, or overdue at evaluation time after
adding `AccuracySec` is also a finding. Calendar missed runs are warning
findings; warnings still make the affected unit and command nonzero. Monotonic
missed-run/persistence values must remain not-applicable.

Without `WatchdogSec`, the only consistent observation is `not-requested`.
With `WatchdogSec`, only `ok` passes; `not-requested`, `unknown`, and `timeout`
fail. Enabling the directive itself additionally requires `Type=notify`, a
present application heartbeat, and a passed live-lock fixture. Watchdog is
therefore a negotiated capability, never a substrate assertion.

Exit behavior is explicit:

- Exit 0: schema-valid record with no findings.
- Exit 1: schema-valid, content-blind audit record containing at least one
  deduplicated error or warning finding.
- Exit 2: malformed, over-limit, unknown-registry, or output-contract input;
  no audit record and no rejected value echo.

Well-formed but unsafe systemd semantics produce typed exit-1 findings. Only
unsupported/malformed projection content is rejected at exit 2.

## Bounds and read-only operation

Inputs are capped at 64 KiB (baseline), 1 MiB (registry), 1 MiB
(declarations), and 2 MiB (observations). Schemas cap registry components at
128, units per component at 32, audited units at 512, directive/failure-target
arrays and strings conservatively, unit findings at 64, fleet findings at
4,096, and extensions at zero. Runtime also caps total registry units,
directives, findings, and serialized output (2 MiB). Rejected content is never
echoed.

The validator imports only file/path/URL helpers, reads bounded JSON, and writes
only the audit to stdout. It has no child-process, network, notifier, systemctl,
or file-write path; the hermetic test checks that structure.

Production uses the real clock by default:

```bash
make systemd-supervision-audit ARGS="--baseline docs/systemd-supervision-baseline-v1.json --registry /path/to/services.json --declarations declarations.json --observations observations.json"
```

Fixtures and offline replay may override evaluation time deterministically;
the output stamps `evaluated_at_source: fixture-override`:

```bash
make systemd-supervision-audit ARGS="--baseline docs/systemd-supervision-baseline-v1.json --registry tests/fixtures/systemd-supervision/registry.json --declarations tests/fixtures/systemd-supervision/declarations-positive.json --observations tests/fixtures/systemd-supervision/observations-positive.json --now 2026-08-02T12:00:00Z"
```

## Deferred live certification

This P1 change is fixture- and read-only audit software only. Grimnir #183 and
Brokkr #6 are delivered dependencies, but M5, Orin, the control node, and NAS are
offline for the stated week. A later attended hardware window must separately
verify `systemd-analyze verify`, metadata projections from both manager scopes,
restart storm and OOM results, #6 delivery, calendar catch-up, timer overdue
behavior, and an actual heartbeat/live-lock watchdog negotiation. Nothing here
claims live-node, notifier, installation, deployment, or hardware
certification.
