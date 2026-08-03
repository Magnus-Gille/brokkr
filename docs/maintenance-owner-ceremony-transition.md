# Maintenance owner-ceremony transition

`scripts/maintenance-owner-ceremony-transition.mjs` is the separately
reviewable Brokkr #82 transition state machine for revision-bound maintenance
artifacts. Production arming is intentionally blocked: the current repository
has no closed producer for fresh per-window request, registration, recovery
authority, and evidence bindings. It does not select a target, mint authority,
derive a maintenance attempt, or approve a future window.
The ordinary canary and delivery installers remain disabled by default, never
call systemd, and cannot arm or schedule anything.

The owner may prepare one exact protected ceremony record before any live
installation. Installation lays down only disabled artifacts. The transition
can verify and fail-safe the following proposed sequence, but production
returns `scheduler_prerequisite_unimplemented` before publishing or enabling
ceremony units:

1. verify the signed owner decision, separately signed closed configuration,
   and exact release,
   authorization, constitution, target coverage, owner-attestation,
   recovery-worker, target-eligibility, kill-switch, delivery, unit, and
   scheduler/watchdog digests;
2. require a fresh eligible one-target Debian non-pillar record, five distinct
   lifecycle identities, `R-forward` recovery, and an existing durable disarm;
3. atomically publish the exact protected watchdog service and
   watchdog/scheduler timer bytes, reload systemd while disarmed, and verify
   their loaded fragment paths, timer targets, commands, environment, and
   disabled state;
4. copy the already-bound enabled delivery credential from the protected
   ceremony source, publish a closed non-promotable disarm result, and require
   the separately installed #81 adapter file to match its bound owner, mode,
   and digest before requiring a fresh `delivered: true` receipt;
5. once the missing scheduler contract exists, enable and positively read back
   the watchdog timer, then the scheduler timer, while the canary remains
   disarmed;
6. recheck delivery bytes and receipt, effective unit state, watchdog
   readiness, and credentials immediately before any future arm.

Each transition is fsynced to a metadata-only append log with its
revision-bound reversal recipe. A failure after the first mutation writes and
fsyncs disarm before it disables the scheduler/watchdog and stops the
apply/recovery/watchdog units. It then replaces the delivery credential with
the exact disabled #81 configuration. Newly published ceremony units are
removed and systemd is reloaded if the publication transition fails. This
path never contacts Heimdall and retains the release, source record, journals,
receipts, probe result, and audit evidence.

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
  to prove authenticated delivery readiness before arming and on every armed
  replay;
- `configuration.json` and `configurationAttestation.json` — the exact closed
  configuration and its separately signed owner attestation;
- `watchdog.service`, `watchdog.timer`, and `scheduler.timer` — exact private
  ceremony unit bytes, installed only by this transition.

The watchdog service invokes the release-bound
`maintenance-canary-watchdog.mjs`, not the apply/recover-only host adapter.
The ceremony executes its read-only readiness probe before timer enablement
and its pre-arm probe after the final delivery and unit readbacks.

The signed record contains only canonical IDs, full Git revisions, digests,
unit names derived from the canary ID, distinct role identities, the literal
owner decision, and the reversal recipe. It binds the whole immutable installed
release tree and exact unit bytes. Endpoint and credential values remain only
in the protected delivery input and never enter argv, stdout, audit evidence,
or git.

The scheduler and watchdog unit bytes are protected ceremony artifacts because
their target and schedule configuration can be sensitive. Their names are
fixed from the canary ID, their content digests are owner-signed, and both must
bind the exact release revision. The transition does not generate, repair, or
reinterpret either unit.

The ceremony deliberately does not bind a future attempt ID, plan, evidence,
baseline, postconditions, deadline, package set, or terminal receipt. No
current production component derives the mutually bound request,
registration, recovery descriptor/authority, and fresh evidence set for each
eligible window. Reusing the fixed canary attempt or inventing a template
would bypass existing host gates, so #82 remains inert until that prerequisite
contract is implemented and independently reviewed.

## Invocation and replay

An attempted production arm from the immutable release selected by the owner
record remains fail-closed:

```sh
sudo /usr/local/lib/brokkr/releases/FULL_SHA/scripts/maintenance-owner-ceremony-transition.mjs arm
```

The implementation retains defensive handling for an armed marker left by an
earlier build. It first requires the durable armed marker to match the supplied
record at the binding level so untrusted input cannot trigger mutation. A
trusted legacy active state is then terminally disarmed because the scheduler
prerequisite is absent. The same replay path verifies protected and published
delivery bytes, release/unit bytes, effective loaded systemd properties,
fresh authenticated delivery, and live timer readbacks in the future-state
test harness. Divergent records, revisions, digests, unit state,
authorization, identity, target, eligibility, kill-switch, delivery, or
scheduler/watchdog evidence fail closed.

The reversal is:

```sh
sudo /usr/local/lib/brokkr/releases/FULL_SHA/scripts/maintenance-owner-ceremony-transition.mjs disable
```

It persists disarm before every systemd stop/disable and has no Heimdall
dependency. Explicit owner/recovery disarm is monotonic: re-arming requires a
strictly newer ceremony sequence and a strictly newer owner authorization
whose previous digest is the terminal marker's authorization digest. Retryable
transition failures may replay the same ceremony.

Both `arm` and `disable` run under one root-owned, no-follow, absolute-path
exclusive `flock` held for the complete lifecycle transition. The locked child
uses a dedicated imported entrypoint rather than a spoofable environment
marker. A concurrent disable waits for an in-progress transition and then
wins. The older installer `disable` action remains an additional
revision-bound emergency path.

## Authority boundary

No input can currently widen the target to `armed-canary`; the missing
per-window scheduler prerequisite is a mechanical production gate. Recovery
remains separately bound and may only narrow state. Heimdall receives a
read-only result and has no arm, disarm, recovery, scheduling, policy, package,
or promotion capability. Fleet state, live ceremony execution, private target
selection, package mutation, and evidence-window claims remain outside this
software change.
