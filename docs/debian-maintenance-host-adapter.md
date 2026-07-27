# Debian maintenance host adapter (brokkr#67)

`scripts/debian-maintenance-host-adapter.mjs` is the root-only, fixed-command
actuator for the disarmed Debian security/bugfix lane. It is a capability seam,
not an installer, timer, deployer, or arming mechanism. No unit, sudoers rule,
request, registration, target, or private locator is shipped by this repository.

The only CLI shapes are:

```
debian-maintenance-host-adapter --action apply --attempt <canonical-id>
debian-maintenance-host-adapter --action recover --attempt <canonical-id>
```

Both input paths are derived from that canonical attempt ID under the fixed
`/var/lib/brokkr/debian-maintenance` root. Inputs must be regular root-owned
files with mode 0600 or stricter. The root-owned registration must equal the
request's exact attempt, binding, plan, constitution, release, execution-request
and recovery-descriptor digests. The adapter does not accept a path, command,
repository, source, unit, package action, shell fragment, hook, or reboot policy
from its CLI. `release_digest` must also equal the raw SHA-256 digest of the
installed adapter module; it is not merely a request/registration self-claim.
The full W2a target/binding/attempt/mutation/epoch/token/activation/expiry
effect fence is request-and-registration-bound. The adapter takes an
OS-released `flock` for the entire activation/check/effect process, installs
that fence before preflight, re-reads the identical fence, and invokes apt
synchronously inside that critical section. A superseded, missing, corrupt,
or wedged fence fails closed. Recovery instead reads a separate root-owned,
fixed-path protected activation record bound to the immutable descriptor and
attempt; its epoch must strictly advance the original effect fence, so a
crashed recovery worker can be superseded without rewriting the original
request or recovery descriptor.

Apply rechecks NTP synchronization, mains power, the dpkg lock, free `/var`
space, and Debian DNS immediately before simulating and again before applying.
It permits only canonical, already-bound `security`/`bugfix` candidates from the
distribution repository. Kernel and firmware names are rejected. Apt receives a
fixed absolute executable and `--only-upgrade --no-remove --no-install-recommends`;
the simulation must show exactly the bound package/version set and no removals.
So a new package, dependency expansion, removal, unbound version, reboot, drain,
or unreachable/unknown precondition is a terminal, disarmed outcome before or
after no further automatic reapply.

The request also carries a closed, canonical apt-policy evidence object: for
each already-bound candidate it records the SHA-256 of the exact `apt-cache
policy <package>` output. The adapter re-reads that output immediately before
simulation and again immediately before apt effect, requiring the requested
version and a Debian archive URL. This is a verifiable local apt trust-property
and exact byte binding, not an invented signature scheme; changed source,
candidate, plan/policy digest, or evidence fails closed.

The adapter atomically persists a compact phase journal (`preflight`, inventory
before/after, apply, verify) using fsync-and-rename. It records only digests and
phase timestamps, never commands or package logs. A corrupt or replayed journal
terminalizes and disarms.

Recovery is a different action and a different systemd entry point. It can only
run the request's pre-registered descriptor: `dpkg --configure -a`, exact
allowlisted unit restarts, and holds for the already-bound package names. It
never runs apt, adopts a plan, re-arms a target, widens the package set, or
creates a replacement request. It must verify the original declared
postconditions inside the descriptor's at-most-300-second budget, then journals
quarantine and disarm. Any repair, restart, hold, journal, or verification
failure terminalizes and writes a disarm record.

The mandatory, private recovery bridge is co-located with the only exported
W2a runner. W2a's durable outbox supplies its authenticated, monotonic
successor fence; before publishing an activation the bridge structurally binds
the exact attempt, binding, target scope, mutation, descriptor, idempotency
key, and successor epoch/token. It then dispatches only `{action: "recover",
attempt_id}` to the fixed unit. A restart reads the same W2a outbox and repeats
the same idempotency key; it cannot synthesize a plan, re-arm, or widen scope.
The production installer is still intentionally absent, so this remains a
hermetic/disarmed contract until the separate owner ceremony installs the fixed
state root and unit.

`systemd/brokkr-debian-maintenance-recovery@.service` is a separate hardened
root capability because dpkg repair itself requires root. Its sole executable
is the exact fixed recovery wrapper, with no sudo transition and
`NoNewPrivileges=yes`; it cannot accept a plan or arbitrary command. It is
intentionally not installed here: the future owner ceremony must first create
the fixed root-owned state tree, the registration, and signed outer authority.
