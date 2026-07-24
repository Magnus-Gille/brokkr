# Read-only maintenance observation and plan (brokkr#33)

`make maintenance-plan ARGS="..."` produces a deterministic, read-only, Debian-first
observation of what maintenance *would* be eligible on one host right now, and why. It
never installs, removes, configures, reboots, or restarts anything. A non-zero result
means the plan is blocked; even a blocked run still emits a schema-valid, machine-readable
JSON envelope with `--json`.

```sh
make maintenance-plan ARGS="--json \
  --policy /safe/policy.json --inventory /safe/node-capability.json \
  --workload /safe/workload.json \
  --now 2026-07-23T10:30:00Z --window-occurrence-date 2026-07-22 \
  --missed-occurrences 0 --deferral-elapsed PT0S"
```

`--workload` is optional. `--missed-occurrences`/`--deferral-elapsed` are explicit,
Brokkr-evidence-bound inputs, never invented here (see "What this does not do" below).

## What it consumes, and how, without duplicating it

- **`--policy`** is an unchanged Grimnir `maintenance-policy` v1 record
  ([`maintenance-policy-v1.schema.json`](maintenance-policy-v1.schema.json), vendored
  byte-identical from `Magnus-Gille/grimnir@a201afdab7accc5f32111dbc593a15063985cff2`; see
  [`docs/maintenance-policy-provenance.md`](maintenance-policy-provenance.md) for the pins).
  `scripts/lib/maintenance-policy-contract.mjs` is a dependency-free re-implementation of
  that contract's normative semantics: structural schema validation (including the
  `maximum` keyword grimnir's schema uses that the node-substrate schema doesn't),
  `maintenance-policy-digest-jcs-v1` digest recomputation, IANA timezone/DST
  classification, and the exact decision-effect precedence table (disabled → held; hold
  active → held; nothing missed → on_schedule; deferral past `maximum_deferral` →
  escalate, checked **before** the overdue count; missed ≥ `overdue.after_missed_windows`
  → `overdue.behavior`; else `missed_window.behavior`). The runtime SHA-256 pins the
  vendored schema and this provenance note before ever parsing them
  (`assertPinnedContractFiles`), mirroring `scripts/lib/node-substrate-contract.mjs`.
- **`--inventory`** is an unchanged brokkr#7 `node-capability` v1 record (the pinned
  node-substrate contract, freshness-checked the same way `relocation-planner.mjs`
  checks it). This ticket does not re-derive or re-collect inventory.
- **`--workload`** is an unchanged node-substrate `workload-requirement` v1 record, used
  only to check that `preflight`/`drain`/`verify` hooks are *declared* (never invoked).
  Hook ownership stays with the component repo per the epic's boundary (brokkr#26).
- **`--missed-occurrences`/`--deferral-elapsed`** are Brokkr's own opaque
  missed-occurrence count and elapsed-deferral duration. The Grimnir contract explicitly
  places "occurrence-calendar enumeration" and execution/attempt history out of scope for
  v1 (`docs/maintenance-policy-contract.md`, "Out of scope for v1"); a future
  execution-result/mutation-journal contract (brokkr#10) is the eventual mechanical
  source for these two numbers. Until that exists, this planner requires them as
  explicit, fail-closed CLI inputs rather than assuming "nothing was ever missed".
- **`--window-occurrence-date`** is likewise an explicit input (which scheduled
  occurrence is being evaluated) — this planner only makes the DST resolution of that one
  named date mechanical and schema-checkable; it does not itself compute "which dates
  are due" from a recurring schedule.

Brokkr#2 (typed node-agent ownership/versioning) and the future mutation journal are not
touched or duplicated by this ticket at all.

## Output shape: `brokkr-maintenance-plan` v1

A Brokkr-owned envelope (not part of the Grimnir schema) wrapping a schema-valid, pinned
Grimnir `maintenance-decision` record:

```json
{
  "kind": "brokkr-maintenance-plan", "schema_version": "v1",
  "plan_id": "...", "plan_digest": "sha256:...",
  "outcome": "planned" | "blocked",
  "node_id": "...", "policy_id": "...", "policy_digest": "sha256:...",
  "inventory_evidence_id": "...",
  "decision": { "...maintenance-decision v1, or null if blocked before it could be built..." },
  "running_kernel": "...",
  "gates": {
    "package_manager_lock": "locked|unlocked|unknown",
    "disk": "sufficient|insufficient|unknown",
    "power": "mains|battery|unknown|not_applicable",
    "clock": "synchronized|unsynchronized|unsupported",
    "workload_hooks": "ready|incomplete|not_applicable",
    "kernel_recovery": "eligible|not_eligible|unknown"
  },
  "hook_gaps": [{"code": "hook-drain-missing"}],
  "candidates": [
    {"id": "curl@7.88.1-10+deb12u5", "name": "curl", "class": "security", "source": "distro_repository",
     "current_version": "7.88.1-10", "candidate_version": "7.88.1-10+deb12u5", "eligible": true, "reasons": []}
  ],
  "unsupported_classes": [{"class": "firmware", "reason": "no-adapter-detected"}],
  "blockers": [{"code": "...", "owner": "brokkr|grimnir", "message": "..."}],
  "created_at": "2026-07-23T10:30:00Z"
}
```

`outcome: "blocked"` (exit 3) means a Brokkr-owned safety gate refused to produce a
trustworthy plan at all (see the fail-closed matrix below). `outcome: "planned"` (exit 0)
means the plan was produced; `decision.effect` inside it can still be `held`,
`escalate_operator_gate`, `deferred_to_next_window`, `skip_occurrence`, or `run_deferred`
— that is normal, informational timing output, never itself a mutation or an
authorization (matching the Grimnir contract's own "neither record proves eligibility nor
authorizes mutation").

## Candidate enumeration (Debian-first, read-only)

Candidates come from parsing `apt-get -s dist-upgrade` (the one allowed read-only
simulate form — see "Provably non-mutating" below). Each `Inst` line's package name,
old/new version, and origin annotations are parsed into an exact candidate identity;
class (`security`/`bugfix`/`kernel`) is derived from the package name
(`linux-image-*`/`linux-headers-*`/`linux-modules-*` → `kernel`) and whether any origin
token matches `Debian-Security:`/`-security` (case-insensitive); source
(`distro_repository`/`package_manager_lts_channel`) is derived from whether any origin
token names a `-backports` suite. A candidate is `eligible` only if its class is in
`policy.updates.allowed_classes`, its source is in `policy.updates.allowed_sources`, and
(for kernel candidates) a previous kernel image package is still installed
(`kernel_recovery: eligible`). Firmware is detected via `rpi-eeprom-update` (Pi) or
`fwupdmgr get-upgrades --json` (UEFI/LVFS), whichever is present in `PATH`.

**Design decision — firmware is never silently dropped, but does not by itself block
other candidates.** A detected firmware update is always enumerated as a candidate with
`eligible: false` and `reasons` including `firmware-recovery-unsupported` (Brokkr has no
automatic, power-safe firmware apply/recovery adapter yet — see the epic's non-goal "never
claim rollback capability it does not have"). If the policy allows the `firmware` class
but no adapter is present at all, that is separately named in `unsupported_classes`. This
planner deliberately does **not** treat "a pending firmware update exists" as a reason to
block eligible package/kernel candidates on the same host — a host can have an
actionable security patch and an out-of-band firmware update at the same time, and
hiding the former behind the latter would be a worse outcome than reporting both
honestly. Reviewers who read "fail closed on ... unsupported firmware" in the ticket as
requiring a whole-plan block should flag this in review; the per-candidate fail-closed
(never eligible, always reported) reading is the one implemented here.

## Fail-closed matrix (whole-plan blockers, `outcome: "blocked"`, exit 3)

| Condition | Blocker code |
|---|---|
| Inventory file missing/unreadable/malformed | `inventory-unavailable` / `inventory-invalid` |
| Inventory violates the pinned schema | `inventory-invalid` |
| Inventory stale (`observed_at`/`valid_until` vs `--now`) | `stale-inventory-evidence` |
| Inventory `capability_status` not `known` | `inventory-not-decision-ready` |
| Policy selector does not reference this node/workload | `policy-does-not-select-target` |
| Policy/decision fails pinned-schema or digest checks | `policy-invalid` / `policy-digest-invalid` / `decision-output-invalid` |
| Occurrence date is nonexistent/ambiguous under a `fail_closed`/`skip_occurrence` `dst_policy` | `dst-fail-closed` |
| `missed_occurrences == 0` with nonzero `deferral_elapsed` | `decision-input-invalid` |
| `apt-get -s dist-upgrade` did not run cleanly, or its output could not be parsed safely | `apt-simulation-unavailable` / `apt-output-unparseable` |
| apt reports an unauthenticated/unsigned source | `unsigned-source-detected` |
| Package-manager lock held, or lock state unprovable (`fuser` missing/failed) | `package-manager-lock` |
| Disk headroom unmeasurable or below `BROKKR_MAINTENANCE_MIN_FREE_MIB` (default 1024) | `disk-evidence-unavailable` / `low-disk` |
| Power source is on battery or unprovable (mains-only/no battery present is fine) | `unsafe-power` |
| Clock not synchronized, or synchronization status unsupported (no `timedatectl`) | `bad-clock` |
| Vendored Grimnir contract files fail their SHA-256 pins | `pinned-contract-invalid` |

Workload-hook gaps and per-candidate ineligibility (including unsupported firmware) are
reported in `hook_gaps`/`candidates[].reasons` but do **not** by themselves block the
whole plan — see the design decision above.

## Provably non-mutating

Every external command this program can ever run is named, with its exact permitted
argv, in the `buildAllowlist()` table in `scripts/maintenance-plan.mjs`:

- `apt-get -s dist-upgrade` (simulate only; never bare `upgrade`/`dist-upgrade`, `-y`, or
  `--force-yes`)
- `fuser <dpkg-lock-path>` (no `-k`; this is a read query, not a kill)
- `df -Pm <root-mount>`
- `dpkg-query -W -f='${Package}\n' 'linux-image-*'` (no `-i`/`--configure`)
- `timedatectl show` (no `set-ntp`/`set-time`)
- `uname -r`
- `rpi-eeprom-update` with no arguments (status only; never `-a`, which applies)
- `fwupdmgr get-upgrades --json` (never `update`/`install`)

`readOnly()` is the single call site in the file that invokes `execFileSync`, and it
checks the allowlist before every invocation — `scripts/test/maintenance-plan.test.sh`
asserts both structural facts (`grep -c 'execFileSync('` equals exactly 1, and the
allowlist-gate check precedes it in source). The allowlist's truth table is unit-tested
directly (importing the module never runs `main()`/`process.exit`, thanks to a
`__main__`-style guard), asserting mutating variants of every command (`apt-get install`,
`apt-get -y dist-upgrade`, `fuser -k`, `dpkg-query -i`, `timedatectl set-ntp`,
`rpi-eeprom-update -a`, `fwupdmgr update`/`install`) are rejected, and that commands never
named at all (`dpkg`, `reboot`, `systemctl`) aren't in the table. Finally, every mocked
invocation across the entire hermetic scenario matrix (golden path, every fail-closed
case, every decision-effect branch, both firmware adapters) is logged and, at the end of
the suite, checked twice against the same allowlist — once by exact string match and once
by per-token verb blacklist (`install`, `remove`, `purge`, `-y`, `--force`, `reboot`,
`shutdown`, `restart`, `-k`, `-i`, `configure`, `update`, `upgrade`, `-a`) — so real
runtime behavior, not just the static table, is what gets proven read-only.

The power gate needs no command execution at all: it reads
`${BROKKR_MAINTENANCE_SYSFS_ROOT:-/sys}/class/power_supply/*/{type,status,online}`
directly off the filesystem, the same configurable-root pattern Heimdall's collector uses
for hermetic testing.

## Determinism

Identical inputs (policy, inventory, optional workload, `--now`,
`--window-occurrence-date`, `--missed-occurrences`, `--deferral-elapsed`, and identical
mocked command output in tests) produce byte-identical `--json` output:

- `--json` output is `canonicalJson` (recursively key-sorted, no insignificant
  whitespace) — the same canonicalization the Grimnir digest algorithm itself uses.
- Every collection with meaningful order (`candidates`, `blockers`, `hook_gaps`,
  `unsupported_classes`) is explicitly sorted before being emitted; nothing relies on
  `Set`/`Map`/object key iteration order.
- `plan_id`/`plan_digest`/`decision_id`/the decision's bound evidence id are all
  content-derived hashes of the plan material — never a random UUID, and never
  `Date.now()` (only the caller-supplied `--now` is ever used as "now").
- `scripts/test/maintenance-plan.test.sh` proves this empirically: it runs the golden
  scenario twice with identical mocks and diffs the two `--json` outputs byte-for-byte.

## Redaction

Never emitted: raw command output text, shell commands, file paths beyond the fixed,
generic labels in `gates` (the actual configured lock/mount/sysfs-root path values are
never echoed back — only their pass/fail classification), hostnames/IPs/Wi-Fi
identifiers, or credentials. Package names and versions **are** emitted — they are
public, non-private facts about installed software, exactly like brokkr#7's inventory and
brokkr#9's relocation planner already emit unit names, workload ids, and architecture.
`node_id`/`policy_id`/`workload_id` are the same public-safe `id` identity space the
Grimnir contracts already define. The hermetic test suite includes a `no-private` check
that scans every emitted JSON fixture for RFC 1918 addresses, `/Users/` paths, `.ssh/`
references, `password=`/`token=` patterns, and `sudo`/`rm -rf` fragments.

## What this does not do

- It does not duplicate brokkr#7 (node inventory), brokkr#2 (node-agent ownership), or a
  future execution/mutation-journal contract (brokkr#10) — it consumes their unchanged
  outputs or explicit inputs only.
- It never applies an update, drains a workload, reboots, or writes any journal/evidence
  record beyond its own stdout.
- It does not compute "which occurrence is due" from a recurring schedule (occurrence
  enumeration), nor "how many occurrences were missed" from real attempt history — both
  are out of scope for the Grimnir v1 contract itself and remain explicit inputs here.
