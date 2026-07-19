# Contributing

Thanks for helping improve Brokkr.

1. Open an issue for substantial behavior or architecture changes.
2. Work on a focused branch and add a failing regression for non-trivial shell logic.
3. Keep tests hermetic: mock SSH, systemd, cloud, rclone, and notification clients.
4. Run `make test`, `make shellcheck`, and `git diff --check`.
5. Submit a pull request describing the risk, verification, and rollback path.

Never put live infrastructure data in a contribution. Use `example.com`, TEST-NET
addresses (`192.0.2.0/24`, `198.51.100.0/24`, or `203.0.113.0/24`), placeholder UUIDs,
generic account names, and temporary paths. Keep local `STATUS.md`, `.env`, live tunnel
configuration, rclone configuration, and credentials untracked.

By contributing, you agree that your contribution is licensed under the MIT License.
