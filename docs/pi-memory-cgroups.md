# Pi memory-control preflight and bounded verification

This is a host capability gate for cgroup v2 on Linux with Python 3 and systemd.
It neither installs a kernel nor changes boot files, delegation, services or cgroups.
The same check works on other Linux hosts. RSS supervision remains soft telemetry;
it does not substitute for the hard-memory gate.

## Read-only gate

```sh
python3 scripts/memory-cgroup-preflight.py --dry-run
```

The command reads the unified mount, the process's own cgroup, the user manager's
controller availability, and an allowlist of kernel/boot facts. It queries only
`systemctl --user show`; unavailable bus access becomes unknown evidence. No unit
is started. The JSON omits hostnames, user IDs, cgroup paths, private addresses,
raw boot arguments and kernel configuration. Keep operational evidence private
until it has been checked for other sensitive output from surrounding commands.

Exit codes are **0 supported**, **1 unsupported**, **2 unverified**. A plain run
cannot return supported: controller availability alone does not prove that the
requested limits were applied. Use both expected byte limits inside an approved
bounded test to obtain supported. Invalid/incomplete expected limits are refused.
Supported is evidence for this process at this instant; it is not a durable
attestation for another process, unit, future run or hardware model.

The gate distinguishes:

- `controller_absent`: memory is unavailable at the unified root. Inspect the
  diagnosis before changing systemd; delegation cannot supply an absent controller.
- `delegation_absent`: root memory exists, but the queried user manager cannot
  distribute it to child units. A login shell's cgroup is not that manager.
- `delegation_unknown`: the user bus or controller files could not be observed.
- `accounting_unavailable`: memory/swap counters or required statistics cannot be
  read or parsed in the process's actual non-root cgroup.
- `limit_mismatch`: actual `memory.max` / `memory.swap.max` differ from the finite
  requested byte limits (including an actual `max` value).
- `membership_unverified`: PID membership or a stable cgroup binding is missing.
- `enforcement_unverified`: no explicit expected limits were supplied.
- `cgroup_unavailable`: unified host mount or safe non-root membership unavailable.

Actual expected-limit readback can prove the current process's boundary even if
the user manager query is unavailable, for example in a system transient unit.
Subtree-only cgroup mounts are refused: this gate is for the host view, not a
container namespace. PSI availability is a separate field and never determines
the memory-limit verdict.

`memory.current` includes anonymous memory, file cache and kernel charges.
`anon` and `shmem` describe different working-memory categories; `shmem` is already
included in `file`. `file_cache_bytes = max(file - shmem, 0)` avoids counting shared
working memory twice. `inactive_file` is a reclamation indicator, not a promise
that those bytes can immediately be freed. Neither statistic is subtracted from
the kernel-enforced total or presented as a model's physical appliance footprint.

## Bounded synthetic unit (separate operator approval)

After approving the target, immutable Brokkr revision and this test, run on the
host as the intended unprivileged evaluation user. Substitute the accepted source
path explicitly; do not execute from an unreviewed checkout.

```sh
systemd-run --user --wait --pipe --collect \
  --property=MemoryAccounting=yes \
  --property=MemoryMax=67108864 --property=MemorySwapMax=0 \
  --property=CPUQuota=10% --property=TasksMax=8 \
  --property=RuntimeMaxSec=15s \
  --property=NoNewPrivileges=yes \
  /usr/bin/python3 /opt/brokkr/scripts/memory-cgroup-preflight.py \
  --expect-memory-max 67108864 --expect-swap-max 0
```

This tiny synthetic reader allocates no model and does not provoke OOM. It reads
`/proc/self/cgroup`, confirms its own PID in `cgroup.procs`, and reads actual
`memory.max`, `memory.swap.max`, counters and keyed `memory.stat` while the unit
exists. A property listing or successful `systemd-run` alone is insufficient.
Require JSON supported and command exit 0; preserve finite-limit and accounting
readback as enforcement evidence. This proves the installed kernel boundary,
not a stress/OOM kill test. Refuse an unsupported/unverified result; do not
silently launch an evaluation under an RSS-only fallback. A separately approved
system-manager test can establish system-scope support, but cannot establish
user-scope support.

The unit expires within 15 seconds, exits normally after reading evidence, and
is collected. Record the generated unit identifier privately for readback or
operator cleanup if invocation is interrupted. Do not stop any unrelated unit.
For a later evaluation, repeat the gate inside its actual bounded unit before
loading the workload; the synthetic result does not transfer to another unit.

## Diagnose before proposing remediation

Issue #136 reports root controllers `cpuset cpu io pids`, user-manager controllers
`cpu pids` and absent memory PSI on a Pi 5 / 8 GB / ARM64. Those observations prove
root memory was absent at that time. They do not identify the running kernel,
its configuration, effective boot flags or whether memory was claimed by v1.
There is no live diagnosis or approved reboot receipt in this repository.

The preflight's `diagnosis` reports `CONFIG_MEMCG`, `CONFIG_PSI`,
`CONFIG_PSI_DEFAULT_DISABLED`, effective memory disable/enable flags, `psi=0`,
and whether `/proc/cgroups` assigns memory a nonzero v1 hierarchy. Missing kernel
config remains unknown; it is read from `/proc/config.gz` or the running kernel's
packaged `/boot/config-<release>` without loading a module. Repeated contradictory
boot flags require private manual examination; the booleans are observations,
not a reconstructed ordering/precedence diagnosis.

Choose the narrowest change only after reconciling the installed kernel package,
matching kernel source/config, firmware boot selection and effective command line:

1. **Memory compiled out:** `CONFIG_MEMCG` disabled cannot be fixed by a boot flag.
   Plan a supported distribution kernel update through the maintenance window
   tracked in #130. No automatic custom-kernel installation is provided.
2. **Memory disabled at boot:** if the installed kernel has MEMCG and the active
   boot configuration disables memory, prepare removal of only that verified
   disable request. Raspberry Pi's `rpi-6.12.y` source also implements
   `cgroup_enable=memory`; use it only after verifying the equivalent handler in
   the target's matching source and resolving conflicting disable flags. Do not
   blindly append historical `cgroup_memory=1` or other unverified parameters.
3. **Memory owned by v1:** prepare a distribution-supported unified-hierarchy
   migration after checking existing consumers. The Linux `cgroup_no_v1` parameter
   has a documented purpose, but switching hierarchy can affect other workloads;
   it is not a generic unattended fix.
4. **Root available, delegation absent:** inspect the effective `user@.service`
   delegation and parent controller restrictions privately. Prepare a narrowly
   scoped `user@<uid>.service.d/*.conf` drop-in adding memory to the existing
   required controller set. Do not overwrite other delegated controllers, write
   `cgroup.subtree_control` manually or restart the user manager without the
   maintenance approval. Recheck in a fresh approved user unit afterward.
5. **PSI alone absent:** inspect PSI build/default and `psi=0` independently.
   Raspberry Pi's referenced Pi 5 config enables PSI but defaults it off. Optional
   `psi=1` needs target-source confirmation and its own reviewed boot delta; PSI
   availability cannot enable the memory controller or fix hard enforcement.

## Maintenance, verification and rollback contract

Before any boot/kernel/delegation write or reboot, prepare a private maintenance
packet and obtain separate approval. Bind the exact target and 40-character
accepted Brokkr revision; list the precise command/file delta, window, stop
conditions, verification commands and reversal recipe. Include:

- The selected boot file (modern Raspberry Pi OS commonly uses
  `/boot/firmware/cmdline.txt`, older systems may use `/boot/cmdline.txt`; firmware
  selection can override it). Preserve its single-line format and all unrelated
  options. Never publish its raw contents.
- Owner-protected backups of the exact active boot file and relevant delegation
  drop-in, checksums, ownership/modes, supported prior kernel/boot selection,
  and a tested console or alternate-boot access path. A backup file alone does
  not demonstrate boot recovery.
- Pre-change access and protected-service health baselines, including application
  and database checks from their owning service runbooks. Agree downtime and
  prevent evaluations from starting during the window.
- Post-reboot access, expected kernel/boot selection, protected-service and data
  checks, no new failed units, read-only preflight and the approved synthetic
  unit's actual memory/swap evidence. Abort further work on unexpected anomalies.
- Rollback restoring only the approved boot/delegation/kernel baseline, with
  approved reload/reboot steps and repeated access/protected-service checks.
  Do not restore older application data or remove newer writes as boot rollback.

Keep #136 open until the approved Pi target has real synthetic-unit evidence and,
if a maintenance change was needed, protected-service and demonstrable rollback
receipts. This software path does not itself complete that operational acceptance.
Record hardware provenance separately: a limited Pi 5 experiment is not a physical
Zero 2 W or 3A+ test, even when its numeric memory cap resembles one.

## Primary references

- [Linux cgroup-v2 memory interfaces](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [Linux boot parameters](https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html)
- [systemd resource control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)
- [Raspberry Pi boot configuration](https://www.raspberrypi.com/documentation/computers/configuration.html)
- [Pi kernel memory-enable handler, rpi-6.12.y](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/kernel/cgroup/cgroup.c)
- [Pi 5 build configuration, rpi-6.12.y](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/arch/arm64/configs/bcm2712_defconfig)

Reference source proves those branches' behavior, not the installed target's
configuration. Check target-matching primary source before preparing a boot delta.
