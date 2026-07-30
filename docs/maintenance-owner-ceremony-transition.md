# Maintenance owner-ceremony transition

`scripts/maintenance-owner-ceremony-transition.mjs` is the separately
reviewable Brokkr #82 transition from inert, revision-bound maintenance
artifacts to one armed canary. It does not select a target, mint authority,
install an artifact, derive a maintenance attempt, or approve a future window.
The ordinary canary and delivery installers remain disabled by default, never
call systemd, and cannot arm or schedule anything.

The owner approves one exact protected ceremony record before any live
installation. Installation then lays down only disabled artifacts. The
transition consumes that record later and performs the fixed sequence:

1. verify the signed owner decision and exact release, configuration,
   authorization, constitution, target coverage, owner-attestation,
   recovery-worker, target-eligibility, kill-switch, delivery, unit, and
   scheduler/watchdog digests;
2. require a fresh eligible one-target Debian non-pillar record, five distinct
   lifecycle identities, `R-forward` recovery, and an existing durable disarm;
3. copy the already-bound enabled delivery credential from the protected
   ceremony source, publish a closed non-promotable disarm result, and require
   the exact #81 adapter to finish with a positive authenticated readback;
4. enable and positively read back the watchdog timer, then the scheduler
   timer, while the canary remains disarmed;
5. recheck all delivery, watchdog, and scheduler readiness and arm the one
   exact target last by durably publishing the signed ceremony binding and
   lifting its disarm marker.

Each transition is fsynced to a metadata-only append log with its
revision-bound reversal recipe. A failure after the first mutation writes and
fsyncs disarm before it disables the scheduler/watchdog and stops the
apply/recovery units. It then replaces the delivery credential with the exact
disabled #81 configuration. This path never contacts Heimdall and retains the
release, source record, journals, receipts, probe result, and audit evidence.

## Protected input

The fixed root-owned directory
`/etc/brokkr/maintenance-owner-ceremony` must be mode `0700`. Every input is a
regular, non-symlink, root-owned `0400` or `0600` file:

- `record.json` — the closed, owner-signed `v1` ceremony decision;
- `pinned-owner-public-key.pem` — the separately pinned Ed25519 owner key;
- `authorization.json`, `constitution.json`, `coverage.json`,
  `ownerAttestations.json`, and `recoveryRegistry.json` — the exact
  owner-bound authority set;
- `eligibility.json` and `killSwitch.json` — fresh target-specific readbacks;
- `deliveryCredential.json` — the exact protected #81 enabled configuration;
- `deliveryProbe.json` — a closed, valid, non-promotable `disarm` result used
  only to prove authenticated delivery readiness before arming.

The signed record contains only canonical IDs, full Git revisions, digests,
unit names derived from the canary ID, distinct role identities, the literal
owner decision, and the reversal recipe. It binds the whole immutable installed
release tree and exact unit bytes. Endpoint and credential values remain only
in the protected delivery input and never enter argv, stdout, audit evidence,
or git.

The scheduler and watchdog unit bytes are private ceremony artifacts because
their target and schedule configuration can be sensitive. Their names are
fixed from the canary ID, their content digests are owner-signed, and both must
bind the exact release revision. The transition does not generate, repair, or
reinterpret either unit.

The ceremony deliberately does not bind a future attempt ID, plan, evidence,
baseline, postconditions, deadline, package set, or terminal receipt. Once
armed, the reviewed scheduler/control-plane path derives and journals those
facts for every eligible window without another human approval. A mismatch is
a stop-and-disarm condition, never implicit re-authorization.

## Invocation and replay

Run only from the immutable release selected by the owner record:

```sh
sudo /usr/local/lib/brokkr/releases/FULL_SHA/scripts/maintenance-owner-ceremony-transition.mjs arm
```

Exact replay verifies the signed record, release/unit bytes, live readbacks,
and durable armed marker, then returns an idempotent result without redelivery
or another enablement. Divergent records, revisions, digests, unit state,
authorization, identity, target, eligibility, kill-switch, delivery, or
scheduler/watchdog evidence fail closed.

The reversal is:

```sh
sudo /usr/local/lib/brokkr/releases/FULL_SHA/scripts/maintenance-owner-ceremony-transition.mjs disable
```

It persists disarm before every systemd stop/disable and has no Heimdall
dependency. The older installer `disable` action remains an additional
revision-bound emergency path.

## Authority boundary

Only the signed owner record can widen the one target to `armed-canary`.
Recovery remains separately bound and may only narrow it. Heimdall receives a
read-only result and has no arm, disarm, recovery, scheduling, policy, package,
or promotion capability. Fleet state, live ceremony execution, private target
selection, package mutation, and evidence-window claims remain outside this
software change.
