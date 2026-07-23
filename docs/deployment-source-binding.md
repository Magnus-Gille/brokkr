# Deployment source binding

Every Brokkr deployment must bind the selected checkout to the immutable full
commit SHA accepted for the release. A clean checkout alone is not sufficient:
it can be a stale commit or an unintended worktree.

The canonical NAS and control-node deployment entry points require the binding
themselves. Run them from the selected worktree root:

```sh
cd /private/tmp/brokkr-release
BROKKR_EXPECTED_SOURCE=/private/tmp/brokkr-release \
BROKKR_EXPECTED_COMMIT=<accepted-full-commit-sha> \
  ./scripts/deploy-nas.sh
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
- the physical repository root containing the deployment entry script is that
  same expected worktree;
- the actual `HEAD` equals the expected immutable SHA.

Detached worktrees are supported. On any mismatch the command is not started,
so existing Brokkr deployment safety checks remain intact as inner gates and no
sync, copy, package installation, systemd change, restart, or remote mutation
can be reached through either canonical entry point.

`scripts/guarded-deploy.sh` remains available for other owning-repository
deployment commands. This is compatible with Grimnir's deployment-source-binding
contract while remaining self-contained: orchestration does not need another
repository's wrapper.
