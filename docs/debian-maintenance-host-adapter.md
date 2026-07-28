# Debian maintenance host adapter (brokkr#67)

`scripts/debian-maintenance-host-adapter.mjs` is the root-only fixed CLI for the
disarmed Debian security/bugfix lane. The entire actuator, recovery publisher,
fixed dependencies, and state machinery live behind the single exported
`runFixedDebianMaintenanceHostOperation()` in
`scripts/lib/fixed-debian-maintenance-host-operation.mjs`. That operation accepts
only a closed action/request/registration tuple. Commands, paths, units, raw
writes, and callbacks are lexical-private. This is a capability seam, not an
installer, timer, deployer, or arming mechanism. No unit, sudoers rule, request,
registration, target, or private locator is installed by this repository.

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
from its CLI. The high-level operation independently re-reads both fixed files
and requires exact canonical equality with its untrusted arguments.
`release_digest` must also equal the raw SHA-256 digest of that installed
operation module. There is no separately importable command runner, state
writer, fence writer, or adapter core to bind.
The full W2a target/binding/attempt/mutation/epoch/token/activation/expiry
effect fence is request-and-registration-bound. The adapter takes an
OS-enforced `flock` for the entire activation/check/effect process. The
effecting process verifies through `/proc/self/fdinfo` that its current PID owns
an advisory write FLOCK on a descriptor with the exact root-owned lock
device/inode, and that an independent contender cannot acquire it. Merely
opening the same inode while a different process owns the lock is insufficient.
The CLI's fixed `flock --no-fork` invocation preserves that lock-holder PID and
descriptor; there is no caller-selectable locked mode. It then installs the
fence before preflight, re-reads the identical fence, and invokes apt
synchronously inside that critical section. A superseded, missing, corrupt, or
wedged fence fails closed. Recovery instead reads a separate root-owned,
fixed-path protected activation and `recovery-authorizations/<attempt>.json`
record bound to the immutable request, descriptor, successor fence, and
attempt. Its epoch must strictly advance the original effect fence, so a
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

The mandatory recovery bridge reaches only the same high-level host operation.
W2a's durable outbox supplies its authenticated, monotonic successor fence;
before publishing an activation the bridge structurally binds the exact
attempt, binding, target scope, mutation, descriptor, idempotency key, and
successor epoch/token. The operation then revalidates the exact root-owned
recovery authorization, atomically publishes that fixed activation, and starts
only `brokkr-debian-maintenance-recovery@<canonical-attempt>.service`. A matching
terminal receipt makes the operation idempotent without another unit start. A
strictly advancing, exactly authorized successor activation may replace a
crashed worker's activation. Recovery resumes from each durable recovery phase,
revalidates safe state before disarm, and repairs a terminal sidecar lost after
its journal commit. A restart reads the same W2a outbox and repeats the same
idempotency key; it cannot synthesize a plan, re-arm, or widen scope.
The production installer is still intentionally absent, so this remains a
hermetic/disarmed contract until the separate owner ceremony installs the fixed
state root and unit.

`systemd/brokkr-debian-maintenance-recovery@.service` is a separate hardened
root capability because dpkg repair itself requires root. Its sole executable
is the exact fixed recovery wrapper, with no sudo transition and
`NoNewPrivileges=yes`; it cannot accept a plan or arbitrary command. It is
intentionally not installed here: the future owner ceremony must first create
the fixed root-owned state tree, request, registration, exact recovery
authorization, and signed outer authority.
