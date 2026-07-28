# W2c supervised Debian maintenance evidence — 2026-07-28

Status: hermetic exact-path proof passed; no live installation, deployment,
arming, canary action, private locator, or package mutation was performed.

The source-bound harness exercised one clean run and ten induced failures
through the production W2a controller/journal, bounded recovery dispatcher,
W2b fixed host operation, and the tracked concrete recovery-unit template.
The clean execution committed within its 3,900-second contract. Controller
kill -9, progress-loop wedge, interrupted package state, lock contention,
network loss, disk-headroom failure, postcondition failure, recovery
crash-loop, unknown reachability, and terminal exhaustion all reached their
expected disarmed or terminally blocked outcome with quarantine active.

For every scenario, the harness derived observed elapsed time from either wall
time or authenticated journal/terminal timestamps and asserted it did not
exceed the declared budget. Each recovery path also carried an explicit effect
counter and asserted zero new-plan mutations. The kill -9 case waited for a
bounded post-effect readiness marker, rejected early child exit, sent a real
SIGKILL to the controller, and recovered the same durable attempt without a
second apply.

The dossier aggregator independently recomputed the four production-path
digests, required the exact eleven-scenario set, rejected fractional UTC
timestamps, rejected over-budget values, and wrote only compact redacted
evidence. A dirty source worktree was rejected before evidence creation. The
installer test proved that the installed recovery unit is byte-for-byte the
tracked template after canonical canary/revision substitution, that both
headroom reserves are physically allocated, and that replayed disable preserves
release, state, evidence, and reserves.

Installer failure-path coverage also mutated the checked-out adapter after
source verification and proved the installed byte still came from the named
Git blob. It proved exact replay does not replace release or unit inodes,
divergent release bytes remain untouched, a same-canary different-revision unit
fails before release/state mutation, unresolved template content publishes no
unit or release, and a simulated systemd disable failure retains the fsynced
disarm marker and evidence while still attempting both exact stops.
World-writable unit metadata, a symlinked release, and a logically sized but
sparse reserve were each rejected without overwriting the unsafe object. A
same-content release with its adapter changed from 0755 to 0600 was likewise
rejected as operationally non-identical.

This checked-in note intentionally contains no generated dossier digest because
`generated_at` and the real SIGKILL wall duration vary per run. The durable
claim is reproducible from a clean named revision using
`docs/supervised-debian-maintenance.md`; any retained dossier should remain
outside the public repository.
