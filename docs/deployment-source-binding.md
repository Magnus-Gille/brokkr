# Deployment source binding

Every Brokkr deployment must bind the selected checkout to the immutable full
commit SHA accepted for the release. A clean checkout alone is not sufficient:
it can be a stale commit or an unintended worktree.

Run deployment commands through Brokkr's local guard:

```sh
cd /private/tmp/brokkr-release
./scripts/guarded-deploy.sh \
  /private/tmp/brokkr-release \
  <accepted-full-commit-sha> \
  -- ./scripts/deploy-nas.sh
```

The SHA must be the accepted release revision, never a value derived from the
checkout at deployment time. The guard requires a lowercase full SHA (40 or 64
hexadecimal characters) and prints the expected and actual source identity:

```text
Expected source: /absolute/worktree @ <expected-sha>
Actual source: /absolute/worktree @ <actual-sha>
```

Before executing the guarded command it verifies all of the following:

- the expected path resolves to the caller's physical current directory;
- that directory is exactly the resolved Git worktree root, not a subdirectory;
- the actual `HEAD` equals the expected immutable SHA.

Detached worktrees are supported. On any mismatch the command is not started,
so existing Brokkr deployment safety checks remain intact as inner gates and no
sync, copy, package installation, systemd change, restart, or remote mutation
can be reached through this entry point.

This is compatible with Grimnir's deployment-source-binding contract while
remaining self-contained: orchestration may call this guard directly instead
of relying on another repository's wrapper.
