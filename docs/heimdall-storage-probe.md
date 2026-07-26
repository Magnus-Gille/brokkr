# Heimdall storage-probe identity

`scripts/provision-heimdall-storage-probe.sh` is the public-safe, reviewed
contract for the dedicated NAS identity that serves Heimdall's storage and
backup probe. It is intentionally separate from a personal SSH identity and
from Brokkr's broad health push agent.

## Contract

The provisioner requires an explicit administrative SSH target and an exact
reviewed Brokkr source binding (`BROKKR_EXPECTED_SOURCE` and
`BROKKR_EXPECTED_COMMIT`). None of those runtime locators belong in git.

For `apply`, supply these protected, local files through the environment:

- `BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS` — a pinned `known_hosts` file used for
  the administrative connection and the dedicated-key readback. It is also
  required by `revoke`; host-key checking never falls back to trust-on-first-use.
- `BROKKR_HEIMDALL_STORAGE_PROBE_PUBLIC_KEY_FILE` — exactly one ED25519 public
  key, mode `0600` or stricter.
- `BROKKR_HEIMDALL_STORAGE_SSH_KEY` — the matching private key, mode `0600` or
  stricter. Configure this same host-owned secret surface as
  `HEIMDALL_STORAGE_SSH_KEY` for Heimdall; do not put the path or key in a
  tracked file.
- `BROKKR_HEIMDALL_STORAGE_PROBE_CONFIG` — six newline-delimited
  `NAME=/absolute/path` values for the Time Machine, Munin, and Mimir sources,
  mode `0600` or stricter. The parser accepts a closed key set and paths only;
  it never sources the file as shell code.

The forced command itself is the tracked
`scripts/heimdall-storage-probe.sh` from the exact bound revision. The
provisioner and root-side reconciler validate the probe, validate the
configuration, and compare both staged SHA-256 digests with the local reviewed
bytes before any managed artifact is replaced. An arbitrary external
19-section script cannot be substituted.

The remote account is a purpose-specific system account. Its only
`authorized_keys` entry is forced to
`/usr/local/lib/brokkr/heimdall-storage-probe`, with `restrict`, no port,
agent, or X11 forwarding, and no PTY. The forced command means an SSH client
cannot substitute a shell command. The account's home and SSH authorization
directory are root-owned, so the probe cannot replace its own key. The config
is root-owned and group-readable only by the dedicated account. The
provisioner writes a root-owned marker binding the authorization, probe,
configuration, and SSH-policy digests; it refuses to replace or revoke
unmarked, symlinked, or drifted artifacts.

### PAM and interactive-login boundary

The account must not be password-locked: PAM rejects a locked account before
the forced public-key command can run. During `apply`, only after all
content-bound artifacts and their marker are durable, the remote root
reconciler generates a fresh random SHA-512 password hash locally and assigns
that hash to the account. It never prints, transfers, records, or retains the
password material. That hash exists only to give PAM a non-locked account
state; it is not an interactive credential.

The tracked SSH daemon `Match User` policy is a second, independently bound
control. Before authorization is written, the reconciler runs `sshd -t` and
reads `sshd -T` for the dedicated user. It requires public-key authentication,
the exact forced command, and explicit denial of password and
keyboard-interactive authentication, empty passwords, TTYs, TCP, Unix-domain,
agent, and X11 forwarding, gateway ports, tunnels, and user RC files. Thus
even possession of the unrecorded random password cannot open an SSH
interactive session; the authorized key is additionally restricted as defence
in depth. An SSH daemon that does not include the managed fragment, or whose
effective policy differs, causes `apply` to fail before the key is replaced.
Only after this validation does it reload the active `ssh.service` (or
`sshd.service`); a host without one of those active service units fails closed.

On a first apply, any failure after the provisional policy is installed but
before the marker is complete removes the authorization, probe, path config,
marker, and new policy, re-locks the account, and reloads SSH. A reapply must
be content-identical (including the public key and SSH policy); content changes
are refused rather than overwriting managed state. This keeps a valid marker as
the boundary before PAM admission.

Run only from the bound clean checkout:

```sh
BROKKR_EXPECTED_SOURCE=/absolute/reviewed/worktree \
BROKKR_EXPECTED_COMMIT=full_reviewed_commit_sha \
BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS=/protected/local/known_hosts \
BROKKR_HEIMDALL_STORAGE_PROBE_PUBLIC_KEY_FILE=/protected/local/probe.pub \
BROKKR_HEIMDALL_STORAGE_SSH_KEY=/protected/local/probe \
BROKKR_HEIMDALL_STORAGE_PROBE_CONFIG=/protected/local/probe.conf \
  scripts/provision-heimdall-storage-probe.sh apply operator@nas.example.test
```

The final authenticated readback runs the forced command and accepts only the
19-section output shape. Its receipt line contains only the key fingerprint,
tracked-probe digest, a `config_bound=true` result, and section count—never the
private config digest, target, key material, paths, or probe data. The
source-binding preflight still names the reviewed checkout and revision for
operator audit; do not copy those local lines into public evidence. SSH/SCP
failures are mapped to content-blind error classes. Fresh metrics must then be
verified in Heimdall under its own deployment/evidence process.

## Reversal

Use the same reviewed source binding and administrative target:

```sh
BROKKR_EXPECTED_SOURCE=/absolute/reviewed/worktree \
BROKKR_EXPECTED_COMMIT=full_reviewed_commit_sha \
BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS=/protected/local/known_hosts \
  scripts/provision-heimdall-storage-probe.sh revoke operator@nas.example.test
```

`revoke` is deliberately bounded: it requires the root-owned marker, removes
only the content-bound authorization, forced-command file, path config, and
SSH daemon fragment, then locks the dedicated account. It does not delete the
account or any backup data. Any artifact drift blocks automatic removal and
requires manual review. It validates and reloads SSH after removal; if that
reload cannot complete, authorization has already been removed and the account
has already been locked, so the command fails without claiming a completed
receipt. Record the resulting metadata-only command outcome with the Heimdall
#23 evidence.
