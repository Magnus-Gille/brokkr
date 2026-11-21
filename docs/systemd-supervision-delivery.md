# Systemd supervision delivery to Heimdall (BROKKR-123)

`scripts/systemd-supervision-delivery.mjs` posts the exact `systemd-supervision-audit`
v1 document produced by `scripts/systemd-supervision-audit.mjs` to Heimdall's
`POST /api/systemd-supervision`. It is observation-only: it never runs `systemctl`,
changes a unit, or reads a journal, and it adds no field to the audit.

```
node scripts/systemd-supervision-audit.mjs … | node scripts/systemd-supervision-delivery.mjs
```

## Behaviour

- The audit is read from stdin (≤ 256 KiB, Heimdall's route limit) and validated against
  the closed `docs/systemd-supervision-audit-v1.schema.json`. Unknown fields (for example
  raw journal text) are rejected, so nothing outside the contract can be transmitted.
- A **stale, non-fresh, or future-dated observation is a visible failure**
  (`observation_stale`, exit 1) and is never delivered as current evidence. Heimdall
  recomputes freshness with its own clock as well.
- Transport errors and 5xx are retried (0 / 0.5 / 2 s) with the **identical bytes**, so a
  retry is idempotent against Heimdall's monotonic `observed_at` / replay handling. 4xx
  (auth, schema rejection, replay conflict) is final and fails the unit.
- A non-2xx response, timeout, or schema rejection therefore always yields a non-zero exit
  and a failed unit; success requires a 2xx.
- The service/timer/restart/watchdog/OOM/notifier/freshness distinctions are untouched: the
  document is delivered byte-for-byte.
- Output is one JSON line or a content-free error code on stderr. No endpoint, token, or
  payload is ever printed; arguments are refused.

## Known constraints (verify on a host before enabling)

- Heimdall keys the stored audit on `observed_at` and answers `409 observation_conflict` for a
  *different* document with the same `observed_at`. The audit takes `observed_at` from the
  observations file and `evaluated_at` from the clock, so a run that re-evaluates **unrefreshed**
  observations is rejected (the unit fails, visibly) and, once `max_age_seconds` passes, is
  `observation_stale` anyway. The observations producer must refresh before each run; the timer
  cadence must not exceed that refresh. Only a retry within one run is byte-identical.
- The credential check requires mode 0400/0600, as the maintenance-result delivery does. If systemd
  grants a `DynamicUser` read through an ACL (mode 0440) the unit fails closed with `config_unsafe`;
  confirm on the target host.

## Configuration (host-owned, never committed)

systemd `LoadCredential=brokkr-systemd-supervision-delivery-v1` supplies a root- or
service-owned, mode `0400`/`0600` JSON file; mode `0440` is accepted only for a `root:root` file
(assumed to be systemd's ACL mask under `LoadCredential=` with `DynamicUser=`; verify with
`stat` and `getfacl` on the host before install). Any other group/other bit is refused:

```json
{"kind":"brokkr-systemd-supervision-delivery-config","schema_version":"v1",
 "enabled":true,"endpoint":"https://<heimdall-origin>/api/systemd-supervision",
 "bearer_token":"<value of HEIMDALL_SUPERVISION_TOKEN, host-owned>"}
```

The endpoint must be `https`, with exactly that path and no userinfo/query/fragment. The
token is the dedicated Heimdall supervision credential; never copy it into git, argv, or a log.

## Install (owner ceremony; not performed by this change)

1. Render `systemd/brokkr-systemd-supervision-delivery.service.in` (`@RELEASE_DIR@` and the
   registry/declarations/observations paths) and install it with
   `systemd/brokkr-systemd-supervision-delivery.timer`. The service has no `[Install]`.
2. Provision the protected credential above.
3. Start the timer; verify `/supervision` in Heimdall shows a current audit with the
   service/timer, restart, watchdog, OOM, notifier, and freshness distinctions intact.

Notes: the unit uses `ProtectHome=read-only` so a release directory under `/home` stays
readable, but a home directory with mode 0700/0750 and unreadable registry, declarations or
observations paths still stops the dynamic user (a tighter alternative, `tmpfs` plus
`BindReadOnlyPaths=`, is a possible follow-up). No observations refresher ships yet (BROKKR-176); until one exists, 409
`observation_conflict` and `observation_stale` failures are expected on unrefreshed inputs.

## Rollback

Set `"enabled": false` in the credential (the program then delivers nothing and exits 0, provided the piped audit is fresh and valid:
audit parsing precedes the config read, so a stale or invalid audit still fails the unit),
or stop/disable the timer. Brokkr's local audit producer is unchanged. Heimdall will show
the projection as stale once the freshness window passes.
