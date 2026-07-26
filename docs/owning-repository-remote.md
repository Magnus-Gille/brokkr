# Owning-repository remote reconciliation

Operational Brokkr checkouts that deploy current Brokkr must use the owning
public repository as `origin`: `https://github.com/Magnus-Gille/brokkr.git`.
Historic archive repositories remain history only. This procedure does **not**
delete an archive, rewrite history, or change repository visibility.

Run it only after recording the current URL out-of-band (it may be a private
locator), confirming a clean worktree, and preserving any local branch commits:

```sh
git remote get-url origin
git status --short
git branch -vv
bash scripts/reconcile-owning-remote.sh --check
```

After review, reconcile just the `origin` URL and prove the current public main
commit resolves:

```sh
bash scripts/reconcile-owning-remote.sh --apply --yes
```

`--apply` fetches `origin` with pruning and prints the full `origin/main` SHA.
It restores the former URL automatically if the fetch or main resolution fails.
For a later manual reversal, use the recorded prior value:

```sh
git remote set-url origin '<previous-url-recorded-out-of-band>'
git fetch --prune origin
git rev-parse --verify 'origin/main^{commit}'
```

Do not run the apply command on an unreviewed, dirty, or locally diverged
checkout. The guard refuses those states rather than guessing whether local work
depends on historic authority.
