# Brokkr project instructions

## Scope

Brokkr is the platform/substrate layer of the Grimnir ecosystem. It owns reusable
host maintenance, storage, backup, network-example, systemd, and hardware-health
automation. Application behavior belongs in the repository for that service.

Use this decision rule: if a concern survives replacing the application on a host,
it belongs here. If it is application logic or application-specific deployment, it
belongs with that application.

## Public-repository hygiene

- Keep live infrastructure configuration, operator status notes, credentials,
  tokens, account identifiers, private addresses, and personal paths untracked.
- Commit only `.example` configuration using reserved example domains and TEST-NET
  addresses. Runtime values must be explicit arguments or environment variables.
- Never weaken the fail-closed encryption and deletion guards in backup scripts.
- Treat sourced environment files as executable code: require a regular,
  non-symlink, current-user-owned file with no group/other permissions.
- Do not claim a backup is healthy solely because it is configured; distinguish
  copy, integrity, restore, and key-recovery evidence.

## Verification

- Add a failing regression before changing non-trivial shell behavior.
- Run `make test`, `make shellcheck`, and `git diff --check` before completion.
- Keep tests hermetic: mock network, SSH, systemd, cloud, and notification clients.
- Do not deploy, restart services, rotate credentials, or mutate remote hosts as a
  side effect of local verification.
