# Supervised Debian maintenance fault injection

This runbook covers the hermetic W2c proof for the exact W2a controller/journal
and W2b Debian host-operation/recovery path. It does not install, enable, start,
arm, dispatch, or mutate a live canary. No private locator, target registration,
package log, credential, or signed owner authority belongs in this repository
or its generated dossier.

## Produce a revision-bound dossier

Start from a clean worktree at the exact revision to certify. Choose an
absolute output path outside the repository, then run:

```sh
revision="$(git rev-parse HEAD)"
scripts/supervised-debian-maintenance-fi.sh \
  --revision "$revision" \
  --output /absolute/redacted-output/dossier.json
```

The runner refuses a short or mismatched revision and refuses tracked,
untracked, or staged worktree drift before it emits evidence. It runs the
production controller and host-operation modules through hermetic seams,
collects strict fragments, recomputes the production-path digests itself, and
atomically writes a mode-0600 dossier.

The fixed scenario set is one clean execution plus ten induced failures:
controller kill -9, progress-loop wedge, interrupted package state, dpkg lock
contention, network loss, disk-headroom failure, postcondition failure,
recovery crash-loop, unknown reachability, and terminal exhaustion. Every
failure must end disarmed or terminally blocked with quarantine active. Every
scenario records measured or trusted-journal elapsed time, proves it is within
the declared budget, and proves that recovery created no new plan mutation.

The clean path has the contract's 3,900-second apply/watch/commit budget. Each
failure path has a 300-second recovery budget. A literal budget without the
corresponding observed elapsed value is not accepted.

## Inspect the dossier

Verify at least:

- `release_sha` equals the intended full revision.
- `clean_runs` is `1`, `induced_failures` is `10`, and all eleven canonical
  scenario IDs occur exactly once.
- every scenario has `passed: true`, `new_plan_mutations: 0`, and
  `observed_elapsed_seconds <= budget_seconds`;
- the clean run is committed without quarantine, while every induced failure
  is quarantined and ends only in its expected narrow outcome;
- `production_path` contains SHA-256 bindings for the controller, bounded
  recovery dispatcher, fixed host operation, and tracked recovery-unit
  template;
- timestamps are canonical whole-second UTC values;
- `redaction` excludes private locators and package logs.

The dossier is evidence about the named source revision and hermetic execution,
not evidence of a production install or a live canary.

## Revision-bound install and rollback ceremony

The installer has two explicit actions:

```sh
sudo scripts/install-debian-maintenance-canary.sh install \
  --source /absolute/clean/worktree \
  --revision FULL_40_CHARACTER_SHA \
  --canary canonical-attempt-id

sudo scripts/install-debian-maintenance-canary.sh disable \
  --source /absolute/clean/worktree \
  --revision FULL_40_CHARACTER_SHA \
  --canary canonical-attempt-id
```

These commands are documented for an owner-controlled future ceremony only;
this repository task does not run them. `install` creates disabled concrete
apply and recovery units bound to an immutable release directory. It validates
the exact clean Git source, archives and blob-verifies the named commit rather
than copying mutable worktree bytes, renders both units in private staging, and
publishes only after every render and existing-binding check succeeds. An
identical replay is byte-idempotent; a divergent existing release or canary
unit is never overwritten. Existing parents, units, release trees, and reserves
must be owned by the installer identity, must not be symlinks or writable by
group/other, and must have their expected type. Existing headroom is accepted
only when all 8 MiB are physically allocated. The installer also preallocates
separate journal and evidence reserves. It never calls systemd.

`disable` checks both installed unit bindings, atomically persists and fsyncs
the disarm marker first, then disables/stops only the exact canary units. A
systemd failure therefore returns nonzero but cannot erase the fail-closed
marker. The action deliberately preserves the immutable release, requests,
registrations, fences, journals, terminal receipts, evidence, and both
headroom reserves. Repeating the same disable is idempotent. Investigate and
retain that evidence before any later owner-directed cleanup.

Installation also persists the initial disarm marker and includes the
revision-bound, inert
[owner-ceremony transition](maintenance-owner-ceremony-transition.md) in the
immutable release. The installer never invokes it. No step in this runbook
authorizes creation of request/registration/authority records, unit
enablement, timer creation, canary activation, or fleet rollout.
