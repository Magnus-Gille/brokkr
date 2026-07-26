# Debian maintenance executor seam (brokkr#35)

`scripts/debian-maintenance-executor.mjs` is a library-only, hermetic mutation
evidence mechanism. `runDebianMaintenance()` composes it with the #66 immutable
attempt journal: a caller supplies only content-blind IDs/digests for policy,
plan, inventory, adapter revision, constitution, postconditions, deadline and
the required `R-forward` recovery class. It does
not import a package manager, reboot utility, shell runner, or deployment
client, and Brokkr ships no live adapter.

Before inventory or drain, then again before apply and reboot, it reads one
current policy record and one synchronized clock proof. It verifies the exact
plan digest, matching policy digest/id, five-minute freshness, selected node,
open maintenance window, enabled/non-held policy plus external hold evidence,
and the complete planner gate shape: unlocked package manager, sufficient disk,
mains/not-applicable power, synchronized clock, legitimate workload state, and
kernel recovery eligibility for kernel candidates. Every selected package
class/source must still be allowed by that current policy. A `planned` envelope
is not sufficient: it must have no blockers and an executable decision effect
(`on_schedule` or `run_deferred`). Declared `unmet_policy_classes` are retained
durably in the journal for downstream policy consumers.

It writes fsynced, bounded and canonicalized before/after inventory and phase
evidence to a private journal. The preceding attempt journal is fsynced before
adapter handoff and hash-links lifecycle receipts. An exact retry must
reconcile the same attempt; only an explicit `not-applied` result may resume.
`applied` or indeterminate state becomes `unknown`/`terminally-blocked` and
disarms. Conflicting replay cannot create a second attempt. Neither journal
records commands, package logs, private locators, credentials, or recovery
material.

`workload_hooks: ready` requires drain, drain verification, and a bounded
restore/undrain hook. Drain failures are compensated and journaled; an absent
or failed restore becomes operator recovery. `not_applicable` invokes no drain
effect. A reboot-capable policy requires reboot and post-reboot-health adapters
before drain/apply. Previous-kernel recovery is used only for reboot/health
failures with the exact typed `{kind:"previous-kernel",boot_entry:"saved"}`
contract; apply/dpkg/network failures receive bounded forward-recovery/reprovision
evidence. There is no retry loop here while controller composition is blocked.
Success is only recorded
after substrate health, restore/undrain, workload health, and after-inventory
evidence all succeed; no-workload runs skip workload hooks.
