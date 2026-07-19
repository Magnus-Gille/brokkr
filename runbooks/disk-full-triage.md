# Backup volume full or filling

A shared backup volume can affect Time Machine and multiple service-owned backup tenants
at once. Use the configured mount path; do not copy live capacity or object names into
this repository.

## Triage

```bash
mount_path=/srv/backups
df -Ph "$mount_path"
sudo du -xh --max-depth=1 "$mount_path" | sort -h
```

## Levers, safest first

1. Review the Time Machine quota in the ignored live Samba config. Change it only after
   comparing client retention needs with the complete volume budget.
2. Apply each producer's documented retention policy. Brokkr must not invent deletion
   rules for Mimir, Munin, or another application's data.
3. Repack or recreate only artifacts whose source of truth and recovery path have been
   independently verified.

Never delete inside a sparsebundle, recursively remove a tenant directory, or lower a
quota without a rollback plan and verified source copy. After remediation, rerun the mount
and capacity checks and validate at least one producer write.
