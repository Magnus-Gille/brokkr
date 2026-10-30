# Archive near-site self-check

The near-site copy of an [archive](archive-offsite.md) (a NAS on the same site) checks
itself. [`scripts/archive-nearsite.sh`](../scripts/archive-nearsite.sh) runs on the NAS
from a monthly systemd user timer, re-hashes the copy with `sha256sum --check`, and
reports to its own Heimdall panel. The archive node does not ssh into the NAS and no new
credential exists: delivery uses the Heimdall producer credential
(`HEIMDALL_HUB_URL` and `HEIMDALL_FLEET_TOKEN`) already present in the NAS's runtime env
file. The script never prints, logs, or writes either value.

## Trust model

The NAS computes the hashes, and it also holds the files and the manifest, so a check that
trusted whatever manifest is on the NAS could be satisfied by changing the manifest. The
**pin** closes that gap. The config holds `ARCHIVE_NEARSITE_MANIFEST_SHA256`, the sha256
of the manifest file. The `manifest` row fails unless the manifest on the NAS has exactly
that digest, and the hash run then reads a private copy of those same bytes, so the file
cannot change between the pin check and the hash run. A manifest that differs from the
pin never passes.

The pin is only as good as how it was made. Compute it on the archive node (`sha256sum
<manifest>`), compare it with `sha256sum` of the NAS copy, and paste the value into the
NAS config. A manifest from before a legitimate archive change needs its pin updated the
same way: the archive is append-only and immutable, so that is a deliberate, owner-
attended step.

What the check does not prove: that the pinned manifest describes the right archive (it
is the same manifest the archive node pushes off-site, whose copy and integrity rows
check it independently), or that the NAS could not be altered together with its config.
Extra files on the NAS are reported as information, because `sha256sum --check` cannot
notice them. A manifest entry whose path is exactly `-` is refused: `sha256sum --check`
reads standard input for it, so an empty-content digest would pass with the file absent
(the hash run also reads `/dev/null`, never the caller's stdin).

## Rows

The panel is `archive-nearsite-<node>`, labelled `Archive Near-site Verification
(<node>)`. The state is the worst row; there is no `warn`.

| Row | Evidence | pass | fail |
|---|---|---|---|
| `manifest` | The file is a regular non-symlink file; its sha256 equals the pin; it is non-empty, ends with a newline, and every line is plain GNU text-mode `<64 lowercase hex>  <relative path>` | all of those hold | a violated condition, named by line number only. Absolute paths, `.` or `..` components, a leading `./`, empty components, GNU backslash-escaped lines, CR and other control characters are refused. Non-ASCII (UTF-8) names are accepted |
| `nearsite` | `sha256sum --check --quiet --strict` of the pinned manifest copy, run inside `ARCHIVE_NEARSITE_DIR` | exit 0: `matched all N manifest entries` | `exit N: A mismatched, B missing of N manifest entries`, or `not checked: manifest row failed` (hashing is skipped), or a missing directory, or no GNU `sha256sum` |

The `nearsite` row adds a note of how many regular files in the directory are not in the
manifest (`K extra files ... (informational)`). It never changes the row's status, and
the panel message carries it when K is not zero. File names are personal data, so only counts reach
the panel, the snapshot, the journal, and stderr.

The panel message starts with every row's status (for example `manifest=pass
nearsite=pass`), then the details of any row that is not pass or that carries an extras
note. Exit status: 0 delivered and passing, 1 delivered with a failing row (systemd marks
the run failed), 2 for everything else: setup (including an unusable state directory or lock
file), config, a missing or malformed delivery env, an interruption before delivery, a
delivery failure, or a failure to remove the work directory afterwards. A cleanup failure
is never allowed to change the result silently: it maps to 2 whatever was delivered (a
delivered pass does not become 1, and a delivered failing row is reported as 2 with the
result still delivered). The snapshot is `~/.local/state/brokkr/archive-nearsite.json`; delivery stamps
use the `archive-nearsite-` prefix.

## Config

Copy [`scripts/lib/archive-nearsite.conf.example`](../scripts/lib/archive-nearsite.conf.example)
to `~/.config/brokkr/archive-nearsite.conf` on the NAS and `chmod 600`. It is parsed, never
sourced, with the same strict rules as the off-site verifier: a regular, non-symlink,
current-user-owned file with no group/other permissions; `KEY=value` lines; only the
listed keys, each at most once; values plain or wholly quoted with no `$` or backticks.
The directory, manifest and pin come only from this file, never from the environment.

| Key | Meaning |
|---|---|
| `ARCHIVE_NEARSITE_DIR` | Absolute plain path of the near-site copy; manifest paths are relative to it |
| `ARCHIVE_NEARSITE_MANIFEST` | Absolute plain path of the manifest on the NAS |
| `ARCHIVE_NEARSITE_MANIFEST_SHA256` | Exactly 64 lowercase hex: the pinned sha256 of that manifest |
| `ARCHIVE_NODE` | Optional panel node name (default the short hostname, at most 40 characters) |

`archive-nearsite.sh --config FILE [--delivery-env FILE] --validate` runs only the config
and manifest checks (and the delivery env's shape, when given): no hashing, no delivery,
no state. `--verify` requires `--delivery-env FILE` and refuses (exit 2) without it; the
process environment is never a source of the credential.

## The credential and the clean environment (allowlist)

The Heimdall producer credential lives in a delivery env file shared with other Brokkr
units. A blacklist of variables to strip from such a file can never be complete (loader
hooks like `LD_AUDIT`, interpreter user-site hooks like `PYTHONUSERBASE`, `BASH_ENV`,
exported shell functions, tracing options all exist), so the unit does not load the file
into an environment at all:

- the unit has no `EnvironmentFile=` and starts the verifier as
  `/usr/bin/env -i HOME=%h PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 <script>
  --config <conf> --delivery-env <file> --verify`, so the process begins with exactly
  those three variables. The command line holds file paths only, never a secret;
- the script reads `--delivery-env` itself, in-process with shell builtins (no subprocess
  gets a value on its command line), after checking the file is a regular non-symlink
  file owned by the user with no group/other permissions;
- it accepts only the canonical lines `HEIMDALL_HUB_URL=<value>` and
  `HEIMDALL_FLEET_TOKEN=<value>`, each exactly once and non-empty. An `export` prefix,
  indentation, spaces around `=`, quotes, a duplicate or an empty value is refused with
  exit 2 and a message that names the key and never shows a value, a prefix, a length or a
  hash. Every other line is ignored. The token must be a single unquoted token
  (`[[:alnum:]._~+/-]+` with up to two `=`, the grammar of
  `scripts/prepare-heimdall-runtime-env.sh`) and the URL a plain `http(s)` endpoint (the
  check the other Heimdall tooling here uses);
- the two values are handed to `heimdall/push.sh` alone, as that one command's environment.
  No other child process (python, sha256sum, grep) receives them, and the script switches
  off `xtrace`/`verbose` and unsets `BASH_ENV`/`ENV` first as cheap defence for manual runs.

## Heimdall producer scope

The NAS's existing producer posts panels for service `brokkr`, and
[`heimdall/push.sh`](../heimdall/push.sh) sends exactly that service. The producer
credential on the NAS must therefore already be authorized for service `brokkr`; when it
is (the usual case for a host that runs other Brokkr checks), no registry change and no
new credential is needed. If the hub rejects the panel, delivery fails and the run exits
2, which is visible in the service state. Authorizing a producer is a hub-side change
owned by the Heimdall operator, not part of this deployment.

## Deployment

[`scripts/deploy-archive-nearsite.sh`](../scripts/deploy-archive-nearsite.sh) installs the
check on the NAS as a revision-bound user-unit release, parallel to
[`deploy-archive-verify.sh`](archive-offsite.md#deployment). It defaults to a dry run,
requires the exact accepted commit (see
[deployment-source-binding.md](deployment-source-binding.md)), ships only the script,
`heimdall/push.sh` and the two units, and renders them on the NAS. It does not touch the
archive-verify units.

```bash
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT=<accepted-full-sha> \
BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV=/home/operator/.config/brokkr/env \
  scripts/deploy-archive-nearsite.sh operator@nas.example          # dry run
# … then the same command with --apply
```

`BROKKR_ARCHIVE_NEARSITE_CONFIG` selects another config path (default
`${XDG_CONFIG_HOME:-~/.config}/brokkr/archive-nearsite.conf`). The preflight requires:
a non-root user with lingering enabled; the delivery env and the config as regular,
non-symlink files, mode 600, owned by that user; the delivery env defining
`HEIMDALL_HUB_URL` and `HEIMDALL_FLEET_TOKEN` once each and non-empty (tested with
`grep -q`, exit status only). There is no forbidden-variable list: other keys in the shared
file are simply ignored by the verifier, as described above. The directory and manifest
must lie outside the unit's private `/tmp` (checked on the resolved physical path too, so
a symlinked parent directory into `/tmp` or `/var/tmp` is refused; the delivery env and
config are checked the same way); the tools the check uses (bash, python3, GNU
`sha256sum`, date, mktemp, tr, sed, stat, id, grep, rm, mv, mkdir, cat) must exist on the
unit's own `PATH` (`/usr/local/bin:/usr/bin:/bin`), not merely on the ssh session's: the
probes and the `--validate` run use the same `env -i HOME=… PATH=… LANG=…` prefix that is
rendered into the unit, defined once in the deploy script; and the shipped script's own `--validate --delivery-env` must accept the config, the
delivery env's shape and the pin, which proves the pin matches the manifest and exercises
the same parser the timer run uses. The deploy never creates or modifies the delivery env
or any credential, and prints no value.

Apply installs `brokkr-archive-nearsite.service` and `.timer` and enables the timer
(`enable --now`). It does not start the service itself, because a check re-hashes the
whole copy and takes hours. The timer is `Persistent=true`, though: on an upgrade where a
scheduled run was missed while the timer was inactive, systemd can start one catch-up
check shortly after the timer is enabled. A first install has no earlier trigger and
starts nothing. The deploy prints this too. The unit runs at idle I/O priority with
`ProtectSystem=strict` (the whole filesystem read-only) and `ProtectHome=read-only`, the
state directory as the only writable path, a private `/tmp`, and a 12 h start timeout.
Everything the check and `heimdall/push.sh` write (work directory, lock, snapshot,
stamps) is under the state directory. The timer fires on the 2nd of each month at
03:30 (random delay up to 2 h, persistent), the day after the archive node's
verification on the 1st. A failed run is visible in the service state and as a
failing or stale `archive-nearsite-<node>` panel.
