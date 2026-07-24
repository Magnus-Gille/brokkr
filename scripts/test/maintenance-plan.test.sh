#!/usr/bin/env bash
# Hermetic tests for the read-only, Debian-first maintenance observation and
# plan (brokkr#33). Mocks every external probe (apt-get, fuser, df,
# dpkg-query, timedatectl, uname, rpi-eeprom-update, fwupdmgr) and the power
# gate's sysfs root -- no real apt/hardware access, ever.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PLANNER="$ROOT/scripts/maintenance-plan.mjs"
LIB_MAINT="$ROOT/scripts/lib/maintenance-policy-contract.mjs"
MAINT_SCHEMA="$ROOT/docs/maintenance-policy-v1.schema.json"
MAINT_PROVENANCE="$ROOT/docs/maintenance-policy-provenance.md"
FIXTURES="$ROOT/tests/fixtures/maintenance-policy"
NODE_INVENTORY_FIXTURES="$ROOT/tests/fixtures/node-inventory"
NODE_SUBSTRATE_FIXTURES="$ROOT/tests/fixtures/node-substrate-contract"
NODE_BIN="$(command -v node)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/invocations.log"; : >"$LOG"

fail() { echo "maintenance-plan.test.sh: FAIL: $1" >&2; exit 1; }

# ─── 1. Provenance: vendored schema + fixtures are byte-identical to the pins ───
for file in "$MAINT_SCHEMA" \
  "$FIXTURES/normal-window.json" "$FIXTURES/hold.json" "$FIXTURES/missed-window-decision.json" \
  "$FIXTURES/negative.json" "$FIXTURES/dst-transition.json"; do
  hash="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  grep -q "$hash" "$MAINT_PROVENANCE" || fail "vendored $(basename "$file") drifted from pinned SHA-256 $hash"
done

# ─── 2. Structural non-mutation proof, part A: the allowlist truth table ───
# (imported directly and unit-tested -- module import never triggers
# main()/process.exit thanks to the __main__-style guard in maintenance-plan.mjs).
cat >"$TMP/allowlist-check.mjs" <<NODE
const m = await import("${PLANNER}");
const allow = m.buildAllowlist({ dpkgLockPath: "/var/lib/dpkg/lock-frontend", rootMount: "/" });
const assert = (cond, msg) => { if (!cond) { console.error("FAIL: " + msg); process.exit(1); } };
assert(allow["apt-get"](["-s", "dist-upgrade"]) === true, "apt-get -s dist-upgrade must be allowed");
assert(allow["apt-get"](["install", "curl"]) === false, "apt-get install must be rejected");
assert(allow["apt-get"](["-y", "dist-upgrade"]) === false, "apt-get -y dist-upgrade must be rejected");
assert(allow["apt-get"](["-s", "upgrade"]) === false, "apt-get -s upgrade (not dist-upgrade) must be rejected");
assert(allow["apt-get"](["-s", "dist-upgrade", "--force-yes"]) === false, "extra trailing args must be rejected");
assert(allow["fuser"](["/var/lib/dpkg/lock-frontend"]) === true, "fuser <lock> must be allowed");
assert(allow["fuser"](["-k", "/var/lib/dpkg/lock-frontend"]) === false, "fuser -k (kill) must be rejected");
assert(allow["dpkg-query"](["-W", "-f=\${Package}\\\\n", "linux-image-*"]) === true, "dpkg-query -W query must be allowed");
assert(allow["dpkg-query"](["-i", "x.deb"]) === false, "dpkg-query -i must be rejected");
assert(allow["timedatectl"](["show"]) === true, "timedatectl show must be allowed");
assert(allow["timedatectl"](["set-ntp", "true"]) === false, "timedatectl set-ntp must be rejected");
assert(allow["rpi-eeprom-update"]([]) === true, "rpi-eeprom-update (status only) must be allowed");
assert(allow["rpi-eeprom-update"](["-a"]) === false, "rpi-eeprom-update -a (apply) must be rejected");
assert(allow["fwupdmgr"](["get-upgrades", "--json"]) === true, "fwupdmgr get-upgrades must be allowed");
assert(allow["fwupdmgr"](["update"]) === false, "fwupdmgr update (apply) must be rejected");
assert(allow["fwupdmgr"](["install", "x"]) === false, "fwupdmgr install must be rejected");
assert(allow["dpkg"] === undefined, "dpkg itself is not in the allowlist at all");
assert(allow["reboot"] === undefined, "reboot is not in the allowlist at all");
assert(allow["systemctl"] === undefined, "systemctl is not in the allowlist at all");
console.log("allowlist truth table OK");
NODE
"$NODE_BIN" "$TMP/allowlist-check.mjs"

# ─── 2b. Structural non-mutation proof, part B: exactly one call site ───
call_sites="$(grep -c 'execFileSync(' "$PLANNER")"
[ "$call_sites" -eq 1 ] || fail "expected exactly one execFileSync call site in maintenance-plan.mjs, found $call_sites"
grep -q 'if (!gate || !gate(args)) fail(' "$PLANNER" || fail "readOnly() must gate on the allowlist before executing"

# ─── 3. Apt-simulate parser unit tests ───
cat >"$TMP/parse-check.mjs" <<NODE
const m = await import("${PLANNER}");
const assert = (cond, msg) => { if (!cond) { console.error("FAIL: " + msg); process.exit(1); } };
const { candidates, unsignedDetected } = m.parseAptSimulate([
  "Reading package lists...",
  "Inst curl [7.88.1-10] (7.88.1-10+deb12u5 Debian-Security:12/stable-security [amd64])",
  "Inst bash [5.2.15-2] (5.2.15-2+deb12u1 Debian:12.7/stable [amd64])",
  "Inst linux-image-amd64 [6.1.90-1] (6.1.99-1 Debian:12.7/stable [amd64])",
  "Conf curl (7.88.1-10+deb12u5 Debian-Security:12/stable-security [amd64])",
].join("\\n"));
assert(candidates.length === 3, "expected 3 Inst candidates, got " + candidates.length);
assert(unsignedDetected === false, "clean output must not be flagged unsigned");
const curl = candidates.find((c) => c.name === "curl");
assert(m.isSecurityOrigin(curl.originTokens) === true, "curl must classify as a security origin");
assert(m.classifySource(curl.originTokens) === "distro_repository", "curl source must be distro_repository");
assert(m.classifyClass("linux-image-amd64", false) === "kernel", "linux-image-* must classify as kernel");
assert(m.classifyClass("bash", false) === "bugfix", "non-security bash must classify as bugfix");
const { unsignedDetected: bad } = m.parseAptSimulate("WARNING: The following packages cannot be authenticated!\\n");
assert(bad === true, "unauthenticated warning must be detected");
console.log("apt-simulate parser OK");
NODE
"$NODE_BIN" "$TMP/parse-check.mjs"

# ─── 4. Build single-record fixtures from the vendored Grimnir bundles ───
node - "$FIXTURES" "$NODE_SUBSTRATE_FIXTURES" "$NODE_INVENTORY_FIXTURES" "$TMP" "$LIB_MAINT" <<'NODE'
const fs = await import("node:fs");
const [fixturesDir, substrateDir, inventoryDir, tmp, libFile] = process.argv.slice(2);
const { policyDigest } = await import(libFile);
const read = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const write = (name, value) => fs.writeFileSync(`${tmp}/${name}.json`, JSON.stringify(value));

const normal = read(`${fixturesDir}/normal-window.json`).records.find((r) => r.kind === "maintenance-policy");
write("policy-normal", normal);

const hold = read(`${fixturesDir}/hold.json`).records.find((r) => r.kind === "maintenance-policy");
write("policy-hold", hold);

const missed = read(`${fixturesDir}/missed-window-decision.json`).records.find((r) => r.kind === "maintenance-policy");
write("policy-missed", missed);

const negative = read(`${fixturesDir}/negative.json`);
write("policy-ambiguous-fail-closed", negative.fail_closed_ambiguous_policy);

const disabled = structuredClone(normal);
disabled.state = { enabled: false, hold: { active: false, reason: "not_applicable" } };
delete disabled.policy_digest;
disabled.policy_digest = policyDigest(disabled);
write("policy-disabled", disabled);

const firmwareAllowed = structuredClone(normal);
firmwareAllowed.updates = { allowed_classes: ["security", "bugfix", "firmware"], allowed_sources: ["distro_repository", "vendor_signed_firmware_channel"] };
delete firmwareAllowed.policy_digest;
firmwareAllowed.policy_digest = policyDigest(firmwareAllowed);
write("policy-firmware-allowed", firmwareAllowed);

const kernelAllowed = structuredClone(normal);
kernelAllowed.updates = { allowed_classes: ["security", "bugfix", "kernel"], allowed_sources: ["distro_repository"] };
delete kernelAllowed.policy_digest;
kernelAllowed.policy_digest = policyDigest(kernelAllowed);
write("policy-kernel-allowed", kernelAllowed);

const inventory = read(`${inventoryDir}/fixture-m5.json`);
write("inventory-m5", inventory);

const workload = read(`${substrateDir}/positive.json`).records.find((r) => r.kind === "workload-requirement");
write("workload-hugin", workload);
const workloadIncomplete = structuredClone(workload);
workloadIncomplete.hooks = workloadIncomplete.hooks.filter((h) => h.name !== "drain");
write("workload-hugin-incomplete", workloadIncomplete);

console.log("fixtures built");
NODE

# ─── 5. Mock command set (env-var-driven so one script covers every scenario) ───
BASE_MOCK="$TMP/mock-base"; mkdir -p "$BASE_MOCK"
write_mock() { cat >"$BASE_MOCK/$1"; chmod +x "$BASE_MOCK/$1"; }

write_mock apt-get <<'EOF'
#!/bin/sh
printf '%s\n' "apt-get $*" >> "$MAINT_TEST_LOG"
case "${MAINT_APT_MODE:-happy}" in
  unsigned) printf 'WARNING: The following packages cannot be authenticated!\n' ;;
  empty) : ;;
  *)
    printf 'Reading package lists...\n'
    printf 'Inst curl [7.88.1-10] (7.88.1-10+deb12u5 Debian-Security:12/stable-security [amd64])\n'
    printf 'Inst bash [5.2.15-2] (5.2.15-2+deb12u1 Debian:12.7/stable [amd64])\n'
    printf 'Inst linux-image-amd64 [6.1.90-1] (6.1.99-1 Debian:12.7/stable [amd64])\n'
    ;;
esac
exit 0
EOF

write_mock fuser <<'EOF'
#!/bin/sh
printf '%s\n' "fuser $*" >> "$MAINT_TEST_LOG"
if [ "${MAINT_LOCK_HELD:-0}" = "1" ]; then printf '12345\n'; exit 0; fi
exit 1
EOF

write_mock df <<'EOF'
#!/bin/sh
printf '%s\n' "df $*" >> "$MAINT_TEST_LOG"
printf 'Filesystem 1M-blocks Used Available Capacity Mounted on\n'
printf '/dev/root 100000 10000 %s 12%% /\n' "${MAINT_DISK_AVAILABLE_MIB:-80000}"
EOF

write_mock dpkg-query <<'EOF'
#!/bin/sh
printf '%s\n' "dpkg-query $*" >> "$MAINT_TEST_LOG"
case "${MAINT_KERNEL_COUNT:-2}" in
  0) : ;;
  1) printf 'linux-image-amd64\n' ;;
  *) printf 'linux-image-amd64\n'; printf 'linux-image-6.1.0-1-amd64\n' ;;
esac
EOF

write_mock timedatectl <<'EOF'
#!/bin/sh
printf '%s\n' "timedatectl $*" >> "$MAINT_TEST_LOG"
if [ "${MAINT_CLOCK_SYNCED:-1}" = "0" ]; then printf 'NTPSynchronized=no\n'; else printf 'NTPSynchronized=yes\n'; fi
EOF

write_mock uname <<'EOF'
#!/bin/sh
printf '%s\n' "uname $*" >> "$MAINT_TEST_LOG"
printf '%s\n' "${MAINT_KERNEL_RELEASE:-6.1.0-1-amd64}"
EOF

# Variants: which firmware adapter (if any) is present in PATH, and a
# no-timedatectl variant for the "unsupported clock check" case.
mkdir -p "$TMP/mock-none" "$TMP/mock-eeprom" "$TMP/mock-fwupd" "$TMP/mock-no-clock"
for f in apt-get fuser df dpkg-query timedatectl uname; do
  for variant in none eeprom fwupd; do cp "$BASE_MOCK/$f" "$TMP/mock-$variant/$f"; done
  [ "$f" = timedatectl ] || cp "$BASE_MOCK/$f" "$TMP/mock-no-clock/$f"
done

cat >"$TMP/mock-eeprom/rpi-eeprom-update" <<'EOF'
#!/bin/sh
printf '%s\n' "rpi-eeprom-update" >> "$MAINT_TEST_LOG"
if [ "${MAINT_FW_PENDING:-1}" = "1" ]; then
  printf 'BOOTLOADER: update available\n'
else
  printf 'BOOTLOADER: up to date\n'
fi
EOF
chmod +x "$TMP/mock-eeprom/rpi-eeprom-update"

cat >"$TMP/mock-fwupd/fwupdmgr" <<'EOF'
#!/bin/sh
printf '%s\n' "fwupdmgr $*" >> "$MAINT_TEST_LOG"
if [ "${MAINT_FW_PENDING:-1}" = "1" ]; then
  printf '{"Devices":[{"Name":"Fixture NIC","Releases":[{"Version":"2.0"}]}]}\n'
else
  printf '{"Devices":[]}\n'
fi
EOF
chmod +x "$TMP/mock-fwupd/fwupdmgr"

# ─── Power (sysfs) fixture roots -- filesystem only, no command execution ───
mkdir -p "$TMP/sysfs-mains/class/power_supply/AC0"
printf 'Mains\n' >"$TMP/sysfs-mains/class/power_supply/AC0/type"
mkdir -p "$TMP/sysfs-battery-charging/class/power_supply/BAT0"
printf 'Battery\n' >"$TMP/sysfs-battery-charging/class/power_supply/BAT0/type"
printf 'Charging\n' >"$TMP/sysfs-battery-charging/class/power_supply/BAT0/status"
mkdir -p "$TMP/sysfs-battery-discharging/class/power_supply/BAT0"
printf 'Battery\n' >"$TMP/sysfs-battery-discharging/class/power_supply/BAT0/type"
printf 'Discharging\n' >"$TMP/sysfs-battery-discharging/class/power_supply/BAT0/status"
mkdir -p "$TMP/sysfs-empty"

# ─── Runner ───────────────────────────────────────────────────────────────
run_plan() { # mockdir policy inventory workload("-" for none) now wdate missed deferral [ENV=VAL ...]
  local mockdir="$1" policy="$2" inventory="$3" workload="$4" now="$5" wdate="$6" missed="$7" deferral="$8"
  shift 8
  # No bash arrays here (kept bash-3.2-friendly, matching maintenance-report.sh's
  # convention): an empty array element under `set -u` is a portability trap on
  # older bash, so the optional --workload flag is a straight conditional instead.
  if [ "$workload" != "-" ]; then
    env -i PATH="$mockdir" MAINT_TEST_LOG="$LOG" BROKKR_MAINTENANCE_SYSFS_ROOT="${SYSFS_ROOT_OVERRIDE:-$TMP/sysfs-mains}" "$@" \
      "$NODE_BIN" "$PLANNER" --json \
      --policy "$policy" --inventory "$inventory" --workload "$workload" \
      --now "$now" --window-occurrence-date "$wdate" --missed-occurrences "$missed" --deferral-elapsed "$deferral"
  else
    env -i PATH="$mockdir" MAINT_TEST_LOG="$LOG" BROKKR_MAINTENANCE_SYSFS_ROOT="${SYSFS_ROOT_OVERRIDE:-$TMP/sysfs-mains}" "$@" \
      "$NODE_BIN" "$PLANNER" --json \
      --policy "$policy" --inventory "$inventory" \
      --now "$now" --window-occurrence-date "$wdate" --missed-occurrences "$missed" --deferral-elapsed "$deferral"
  fi
}

check() { "$NODE_BIN" "$TMP/check.mjs" "$@"; }
cat >"$TMP/check.mjs" <<NODE
import fs from "node:fs";
const { schemaErrors } = await import("${LIB_MAINT}");
const schema = JSON.parse(fs.readFileSync("${MAINT_SCHEMA}", "utf8"));
const read = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const die = (m) => { console.error(m); process.exit(1); };
const [command, ...rest] = process.argv.slice(2);
if (command === "assert") {
  const r = read(rest[0]);
  for (const expr of rest.slice(1)) if (!Function("r", "return (" + expr + ")")(r)) die("assertion failed on " + rest[0] + ": " + expr);
} else if (command === "decision-valid") {
  const r = read(rest[0]);
  if (r.decision === null) die("expected a decision to be present in " + rest[0]);
  const errs = schemaErrors(schema, r.decision);
  if (errs.length) die("decision violates pinned schema: " + errs.join("; "));
} else if (command === "no-private") {
  const text = fs.readFileSync(rest[0], "utf8");
  if (/\\b(?:10|127|192\\.168)\\.|\\b172\\.(?:1[6-9]|2\\d|3[01])\\.|\\/Users\\/|\\.ssh\\/|password=|token=|\\bsudo\\b|\\brm\\s+-rf\\b/i.test(text)) die(rest[0] + " leaked a private locator / credential / shell-command pattern");
} else {
  die("unknown check command " + command);
}
NODE

# ─── 6. Golden path: security + bugfix eligible, kernel denied by policy ───
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/golden.json" 2>"$TMP/golden.err"; then :; else
  cat "$TMP/golden.err" >&2; fail "golden clean-target plan is blocked"
fi
check assert "$TMP/golden.json" \
  'r.outcome === "planned"' \
  'r.kind === "brokkr-maintenance-plan"' \
  'r.node_id === "fixture-m5"' \
  'r.candidates.length === 3' \
  'r.candidates.find(c => c.name === "curl").eligible === true' \
  'r.candidates.find(c => c.name === "curl").class === "security"' \
  'r.candidates.find(c => c.name === "bash").eligible === true' \
  'r.candidates.find(c => c.name === "bash").class === "bugfix"' \
  'r.candidates.find(c => c.name === "linux-image-amd64").eligible === false' \
  'r.candidates.find(c => c.name === "linux-image-amd64").reasons.includes("class-not-allowed-by-policy")' \
  'r.decision.effect === "on_schedule"' \
  'r.decision.reason === "on_schedule"' \
  'r.gates.package_manager_lock === "unlocked"' \
  'r.gates.disk === "sufficient"' \
  'r.gates.power === "not_applicable"' \
  'r.gates.clock === "synchronized"' \
  'r.gates.kernel_recovery === "eligible"' \
  'r.gates.workload_hooks === "not_applicable"' \
  'r.blockers.length === 0' \
  'r.running_kernel === "6.1.0-1-amd64"'
check decision-valid "$TMP/golden.json"
check no-private "$TMP/golden.json"

# ─── 7. Determinism: identical inputs -> byte-identical --json, twice ───
run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/det1.json"
run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/det2.json"
diff -q "$TMP/det1.json" "$TMP/det2.json" >/dev/null || fail "identical inputs produced different --json output (non-deterministic)"
diff -q "$TMP/det1.json" "$TMP/golden.json" >/dev/null || fail "golden run is not byte-stable across invocations"

# ─── 8. Workload-hook readiness (optional input; structural only) ───
run_plan "$TMP/mock-none" "$TMP/policy-missed.json" "$TMP/inventory-m5.json" "$TMP/workload-hugin.json" \
  2026-07-23T10:30:00Z 2026-07-20 0 PT0S >"$TMP/hooks-ready.json"
check assert "$TMP/hooks-ready.json" 'r.gates.workload_hooks === "ready"' 'r.hook_gaps.length === 0'
run_plan "$TMP/mock-none" "$TMP/policy-missed.json" "$TMP/inventory-m5.json" "$TMP/workload-hugin-incomplete.json" \
  2026-07-23T10:30:00Z 2026-07-20 0 PT0S >"$TMP/hooks-incomplete.json"
check assert "$TMP/hooks-incomplete.json" \
  'r.gates.workload_hooks === "incomplete"' \
  'r.hook_gaps.some(h => h.code === "hook-drain-missing")' \
  'r.outcome === "planned"'

# ─── 9. Decision-effect precedence matrix (mirrors the Grimnir contract) ───
# 9a. disabled -> held/disabled
run_plan "$TMP/mock-none" "$TMP/policy-disabled.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/disabled.json"
check assert "$TMP/disabled.json" 'r.decision.effect === "held"' 'r.decision.reason === "disabled"' 'r.outcome === "planned"'
check decision-valid "$TMP/disabled.json"

# 9b. hold active -> held/hold_active
run_plan "$TMP/mock-none" "$TMP/policy-hold.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-20 0 PT0S >"$TMP/hold.json"
check assert "$TMP/hold.json" 'r.decision.effect === "held"' 'r.decision.reason === "hold_active"'
check decision-valid "$TMP/hold.json"

# 9c. missed window (run_as_soon_as_possible) -> run_deferred/missed_window,
#     matching grimnir's own missed-window-decision.json fixture exactly.
run_plan "$TMP/mock-none" "$TMP/policy-missed.json" "$TMP/inventory-m5.json" "$TMP/workload-hugin.json" \
  2026-07-23T10:30:00Z 2026-07-20 1 P1DT1H >"$TMP/missed.json"
check assert "$TMP/missed.json" 'r.decision.effect === "run_deferred"' 'r.decision.reason === "missed_window"'
check decision-valid "$TMP/missed.json"

# 9d. overdue (>= after_missed_windows), deferral still under the ceiling -> escalate/overdue
run_plan "$TMP/mock-none" "$TMP/policy-missed.json" "$TMP/inventory-m5.json" "$TMP/workload-hugin.json" \
  2026-07-23T10:30:00Z 2026-07-20 3 P2D >"$TMP/overdue.json"
check assert "$TMP/overdue.json" 'r.decision.effect === "escalate_operator_gate"' 'r.decision.reason === "overdue_after_missed_windows"'

# 9e. maximum_deferral exceeded takes precedence over the overdue count -> escalate/maximum_deferral_reached
run_plan "$TMP/mock-none" "$TMP/policy-missed.json" "$TMP/inventory-m5.json" "$TMP/workload-hugin.json" \
  2026-07-23T10:30:00Z 2026-07-20 5 P8D >"$TMP/max-deferral.json"
check assert "$TMP/max-deferral.json" 'r.decision.effect === "escalate_operator_gate"' 'r.decision.reason === "maximum_deferral_reached"'

# 9f. missed=0 with nonzero deferral_elapsed is an invalid, fail-closed input.
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT1H >"$TMP/bad-deferral.json"; then fail "missed=0 with nonzero deferral passed"; fi
check assert "$TMP/bad-deferral.json" 'r.outcome === "blocked"' 'r.blockers.some(b => b.code === "decision-input-invalid")'

# ─── 10. DST fail-closed: no decision may exist for an ambiguous occurrence
#     under ambiguous_time=fail_closed (2026-10-25 Stockholm fall-back). ───
if run_plan "$TMP/mock-none" "$TMP/policy-ambiguous-fail-closed.json" "$TMP/inventory-m5.json" "-" \
  2026-10-25T01:30:00Z 2026-10-25 0 PT0S >"$TMP/dst.json"; then fail "ambiguous fail_closed occurrence passed"; fi
check assert "$TMP/dst.json" 'r.outcome === "blocked"' 'r.blockers.some(b => b.code === "dst-fail-closed")' 'r.decision === null'

# ─── 11. Policy selector must actually cover the target ───
if run_plan "$TMP/mock-none" "$TMP/policy-missed.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-20 0 PT0S >"$TMP/unselected.json"; then fail "unselected node passed"; fi
check assert "$TMP/unselected.json" 'r.blockers.some(b => b.code === "policy-does-not-select-target")'

# ─── 12. Fail-closed matrix: each hard gate blocks alone, with the right code ───
# Missing inventory file.
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/does-not-exist.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/missing-inv.json"; then fail "missing inventory passed"; fi
check assert "$TMP/missing-inv.json" 'r.blockers.some(b => b.code === "inventory-unavailable")'

# Stale inventory (now is after valid_until).
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T12:00:00Z 2026-07-22 0 PT0S >"$TMP/stale.json"; then fail "stale inventory passed"; fi
check assert "$TMP/stale.json" 'r.blockers.some(b => b.code === "stale-inventory-evidence")'

# Package-manager lock held.
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S MAINT_LOCK_HELD=1 >"$TMP/lock.json"; then fail "held lock passed"; fi
check assert "$TMP/lock.json" 'r.blockers.some(b => b.code === "package-manager-lock")' 'r.gates.package_manager_lock === "locked"'

# Bad/unsigned source.
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S MAINT_APT_MODE=unsigned >"$TMP/unsigned.json"; then fail "unsigned source passed"; fi
check assert "$TMP/unsigned.json" 'r.blockers.some(b => b.code === "unsigned-source-detected")'

# Low disk.
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S MAINT_DISK_AVAILABLE_MIB=10 >"$TMP/lowdisk.json"; then fail "low disk passed"; fi
check assert "$TMP/lowdisk.json" 'r.blockers.some(b => b.code === "low-disk")' 'r.gates.disk === "insufficient"'

# Unsafe power (discharging battery).
SYSFS_ROOT_OVERRIDE="$TMP/sysfs-battery-discharging"
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/battery.json"; then fail "discharging battery passed"; fi
check assert "$TMP/battery.json" 'r.blockers.some(b => b.code === "unsafe-power")' 'r.gates.power === "battery"'
SYSFS_ROOT_OVERRIDE="$TMP/sysfs-battery-charging"
run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/charging.json"
check assert "$TMP/charging.json" 'r.outcome === "planned"' 'r.gates.power === "mains"'
SYSFS_ROOT_OVERRIDE="$TMP/sysfs-empty"
run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/nopower.json"
check assert "$TMP/nopower.json" 'r.outcome === "planned"' 'r.gates.power === "not_applicable"'
SYSFS_ROOT_OVERRIDE="$TMP/sysfs-mains"

# Bad clock (unsynchronized).
if run_plan "$TMP/mock-none" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S MAINT_CLOCK_SYNCED=0 >"$TMP/unsynced.json"; then fail "unsynchronized clock passed"; fi
check assert "$TMP/unsynced.json" 'r.blockers.some(b => b.code === "bad-clock")' 'r.gates.clock === "unsynchronized"'

# Bad clock (unsupported -- no timedatectl at all, e.g. a non-systemd host).
if run_plan "$TMP/mock-no-clock" "$TMP/policy-normal.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/noclock.json"; then fail "unsupported clock check passed"; fi
check assert "$TMP/noclock.json" 'r.blockers.some(b => b.code === "bad-clock")' 'r.gates.clock === "unsupported"'

# ─── 13. Unsupported firmware is reported honestly, never silently dropped ───
# Policy allows firmware, no adapter present at all.
run_plan "$TMP/mock-none" "$TMP/policy-firmware-allowed.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/fw-none.json"
check assert "$TMP/fw-none.json" \
  'r.outcome === "planned"' \
  'r.unsupported_classes.some(u => u.class === "firmware" && u.reason === "no-adapter-detected")'

# rpi-eeprom present, update pending -> candidate is always reported, never eligible.
run_plan "$TMP/mock-eeprom" "$TMP/policy-firmware-allowed.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S MAINT_FW_PENDING=1 >"$TMP/fw-eeprom.json"
check assert "$TMP/fw-eeprom.json" \
  'r.candidates.some(c => c.class === "firmware" && c.eligible === false && c.reasons.includes("firmware-recovery-unsupported"))' \
  'r.unsupported_classes.length === 0'

# fwupd present, one device pending -> same honesty guarantee via the other adapter.
run_plan "$TMP/mock-fwupd" "$TMP/policy-firmware-allowed.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S MAINT_FW_PENDING=1 >"$TMP/fw-fwupd.json"
check assert "$TMP/fw-fwupd.json" \
  'r.candidates.some(c => c.class === "firmware" && c.eligible === false)'

# ─── 14. Kernel candidates gated by policy AND recovery eligibility ───
run_plan "$TMP/mock-none" "$TMP/policy-kernel-allowed.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S >"$TMP/kernel-ok.json"
check assert "$TMP/kernel-ok.json" \
  'r.candidates.find(c => c.class === "kernel").eligible === true' \
  'r.gates.kernel_recovery === "eligible"'
run_plan "$TMP/mock-none" "$TMP/policy-kernel-allowed.json" "$TMP/inventory-m5.json" "-" \
  2026-07-23T10:30:00Z 2026-07-22 0 PT0S MAINT_KERNEL_COUNT=1 >"$TMP/kernel-no-rollback.json"
check assert "$TMP/kernel-no-rollback.json" \
  'r.candidates.find(c => c.class === "kernel").eligible === false' \
  'r.candidates.find(c => c.class === "kernel").reasons.includes("kernel-recovery-not_eligible")' \
  'r.gates.kernel_recovery === "not_eligible"'

# ─── 15. Redaction: no absolute local paths, credentials, or shell fragments ───
for f in golden hooks-ready missed overdue max-deferral fw-eeprom fw-fwupd kernel-ok; do
  check no-private "$TMP/$f.json"
done

# ─── 16. Provably non-mutating, end to end: every logged invocation across
#     every scenario above matches the documented read-only allowlist
#     exactly, and never a mutating verb. ───
[ -s "$LOG" ] || fail "no invocations were logged -- the audit would be vacuous"
while IFS= read -r line; do
  case "$line" in
    "apt-get -s dist-upgrade") ;;
    "fuser /var/lib/dpkg/lock-frontend") ;;
    "df -Pm /") ;;
    'dpkg-query -W -f=${Package}\n linux-image-*') ;;
    "timedatectl show") ;;
    "uname -r") ;;
    "rpi-eeprom-update") ;;
    "fwupdmgr get-upgrades --json") ;;
    *) fail "logged invocation is outside the documented read-only allowlist: $line" ;;
  esac
  # Second, independent, token-based check over the exact same log: no logged
  # invocation may contain a mutating verb as a whole argv token. Splitting on
  # spaces (rather than substring matching) deliberately avoids false
  # positives on tokens like "dist-upgrade" or "get-upgrades" that merely
  # contain "upgrade"/"update" as a substring but are themselves read-only.
  for token in $line; do
    case "$token" in
      -y|--yes|--force|--force-yes|install|remove|purge|reboot|shutdown|restart|-k|-i|configure|update|upgrade|-a|--apply)
        fail "logged invocation contains a mutating verb token '$token': $line" ;;
    esac
  done
done <"$LOG"
echo "maintenance-plan.test.sh: non-mutation audit covered $(wc -l <"$LOG" | tr -d ' ') invocations across $(sort -u "$LOG" | wc -l | tr -d ' ') distinct read-only commands"

echo "maintenance-plan.test.sh: PASS"
