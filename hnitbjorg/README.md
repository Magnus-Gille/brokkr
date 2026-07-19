# Hnitbjorg — backup-vault concept

Hnitbjorg names the shared backup-store concept inside Brokkr. It is not a missing
repository or service. Disk and mount mechanics live in `../disk/`, the public Samba
example lives in `../samba/`, and recovery guidance lives in `../runbooks/restore.md`.

A local deployment may allocate tenant directories for Time Machine, Mimir, Munin, or
other producers. Their exact paths, object names, schedules, counts, and retention state
are operator-local and should not be committed. Brokkr guarantees mount health and
headroom; each producer repository owns its backup format, integrity checks, and restore
procedure.
