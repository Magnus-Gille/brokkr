# Brokkr

Brokkr is the reusable platform and operations layer for the
[Grimnir](https://github.com/Magnus-Gille/grimnir) personal-AI ecosystem. It keeps
the hosts beneath the AI services healthy: operating-system patching, disk and
mount checks, encrypted offsite backups, Time Machine/Samba configuration,
network-tunnel examples, resource limits, and hardware-health reporting.

It also works as a standalone collection of conservative operations scripts. The
name comes from the Norse smith: Grimnir is the system's mind; Brokkr maintains the
gear it runs on.

## Where it fits

Use one boundary question: **would this concern remain if the application on the
host were replaced?** Disk capacity, OS updates, mounts, backups, network substrate,
and resource limits belong in Brokkr. An application's API, data model, and
deployment behavior belong in that application's repository.

```text
operators / system timers
          |
          v
       Brokkr  ---- hardware/OS health ----> Heimdall
          |
          +---- reads host inventory ------> Grimnir services.json
          |
          +---- maintains substrate for ---> Hugin, Munin, Mimir,
                                               Gille Inference, ...
```

The public ecosystem is understandable from these repositories:

| Repository | Role |
|---|---|
| `grimnir` | System map, shared conventions, and component registry |
| `hugin` | Task dispatch and orchestration |
| `munin-memory` | Persistent memory service |
| `mimir` | Authenticated artifact and file service |
| `heimdall` | Health contract and dashboard |
| `gille-inference` | Local inference gateway and evaluation harness |
| `brokkr` | Host, storage, backup, and OS substrate (this repository) |

Other integrations mentioned in historical design notes are optional; none is
required to run or understand Brokkr.

## What is included

| Path | Purpose |
|---|---|
| `apt/` | Security-only unattended-upgrade policy examples |
| `disk/`, `timemachine/`, `samba/` | Storage, capacity, Time Machine, and share checks |
| `scripts/offsite-photos-backup.sh` | Fail-closed `rclone crypt` backup with deletion gates |
| `heimdall/` | Compose and push hardware-health snapshots |
| `scripts/maintenance-report.sh` | OS, dependency, and firmware visibility |
| `systemd/`, `launchd/` | Example timers, service units, and resource limits |
| `network/cloudflared/config.example.yml` | Placeholder-only tunnel configuration |
| `profiles/` | Public location/network/storage examples and a non-mutating owner-overlay preflight |
| `docs/`, `runbooks/` | Backup evidence, recovery, and operations guidance |
| `scripts/test/` | Hermetic shell regression suite |

## Quick start

Requirements vary by feature. Local validation needs Bash, Node.js (for registry
queries), `make`, and `shellcheck`. Deployment helpers additionally need tools such
as SSH, rsync, systemd, Samba, `rclone`, or cloudflared on the relevant host.

```bash
git clone https://github.com/Magnus-Gille/brokkr.git
cd brokkr
make test
make shellcheck
```

Start with examples, never live values:

```bash
cp network/cloudflared/config.example.yml network/cloudflared/config.yml
cp scripts/lib/notify.env.example ~/.config/grimnir/notify.env
chmod 600 ~/.config/grimnir/notify.env
```

`network/cloudflared/config.yml`, `STATUS.md`, `.env` files, and `rclone.conf` are
ignored intentionally. Supply deployment identity and paths explicitly, for example:

```bash
BROKKR_SSH_TARGET=brokkr@nas-host \
BROKKR_REMOTE_DIR=/opt/brokkr \
  ./scripts/deploy-nas.sh

REGISTRY_PATH=/opt/grimnir/services.json DEPLOY_USER=brokkr \
  ./scripts/setup-host-patching.sh --dry-run
```

Feature-specific setup and acceptance checks live in:

- [`docs/offsite-photos-backup.md`](docs/offsite-photos-backup.md)
- [`docs/backup-evidence.md`](docs/backup-evidence.md)
- [`docs/control-node-deadman.md`](docs/control-node-deadman.md)
- [`docs/heimdall-agent-watchdog.md`](docs/heimdall-agent-watchdog.md)
- [`runbooks/restore.md`](runbooks/restore.md)

## Security model and limitations

Brokkr deliberately does not track credentials or live topology. Tunnel credential
JSON, rclone OAuth/crypt material, notification tokens, host inventories, and
operator status belong outside Git with owner-only permissions. The offsite backup
script refuses non-crypt remotes, weak filename encryption, unsafe sourced env files,
and unexpectedly large deletion sets.

These scripts are examples for trusted machines, not a turnkey fleet manager. Several
deploy helpers assume passwordless `sudo`, SSH host trust, and a correctly provisioned
service account. Review targets and rendered unit files before deployment. Health
reporting is best-effort in some paths, and a configured backup is not proof of a
successful restore. See [`SECURITY.md`](SECURITY.md) and the backup evidence contract
for the exact guarantees.

Compared with Ansible, NixOS, or Kubernetes operators, Brokkr is intentionally small
and host-oriented. Its differentiator is the Grimnir health contract plus explicit,
testable safety gates around personal-AI backup and substrate operations; it is not a
general-purpose configuration-management framework.

## Contributing and support

Bug reports and patches are welcome through GitHub Issues and pull requests. See
[`CONTRIBUTING.md`](CONTRIBUTING.md). Security reports should follow
[`SECURITY.md`](SECURITY.md), not a public issue.

## License

MIT. See [`LICENSE`](LICENSE).
