# Debian maintenance executor seam (brokkr#35)

`scripts/debian-maintenance-executor.mjs` is a library-only, hermetic mutation
evidence mechanism. Controller composition is blocked until #34 retry attempts
have a shared attempt-ID to immutable-journal binding. It does
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
evidence to a private journal. Any existing journal fails closed—there is no
automatic replay or overwrite, so crashes require operator recovery rather
than guessing.

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
