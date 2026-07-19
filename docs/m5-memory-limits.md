# Inference-host memory-limit example

The drop-ins under `systemd/m5/` demonstrate how to contain non-critical services and
protect inference and unattended work on a cgroup-v2 host. They are examples, not a
portable capacity plan: service names, limits, and priorities must be derived from the
target host's measured `MemoryPeak`, workload, and recovery requirements.

## Design

1. Give non-critical services `MemoryHigh` and `MemoryMax` limits so an overrun is
   contained inside one cgroup.
2. Use `OOMScoreAdjust` only as a global-OOM backstop: expendable workloads receive
   positive values; work that is expensive to lose receives negative values.
3. Launch important unattended commands through `scripts/overnight-guard.sh`, which
   verifies that its protected systemd scope received the requested score.

`MemoryMin` protection is limited by ancestor slices. A service-level minimum is not an
effective reservation unless its slice is configured consistently. `OOMScoreAdjust` and
systemd-oomd's `ManagedOOMPreference` are different mechanisms; do not substitute one for
the other.

## Safe rollout

Applying `MemoryMax` to a running process takes effect immediately. Review current usage
and run the deploy helper in dry-run mode while the host is quiet:

```bash
./scripts/deploy-m5-memlimits.sh
./scripts/deploy-m5-memlimits.sh --apply
```

The helper separates system and user units, refuses to run wholly as root, does not
restart services, and blocks a cap below current usage. After rollout, exercise normal
load and tune from observed peaks:

```bash
systemctl show example.service -p MemoryCurrent -p MemoryHigh -p MemoryMax -p MemoryPeak
systemctl --user show example-user.service -p MemoryCurrent -p MemoryHigh -p MemoryMax -p MemoryPeak
```

Keep a comfortable margin. An overly tight limit replaces a fleet-wide failure with a
repeated same-service failure; containment still needs alerting and recovery.

## Protected unattended command

```bash
sudo ./scripts/overnight-guard.sh -- your-command --with-arguments
```

The wrapper uses the system manager so it can lower `oom_score_adj`, then drops the
payload back to the invoking uid/gid. It fails if the protection cannot be proven.

## Rollback

Remove only the installed `memory.conf` drop-ins, reset any slice property set during
rollout, and reload the matching system or user manager. Do not restart unrelated
services as part of rollback. The exact commands depend on the local unit names and must
be recorded before applying the example profile.
