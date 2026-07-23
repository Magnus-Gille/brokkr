# Location, network, storage, and backup-role profiles

`location-network-storage.example.json` is a versioned, public declaration of
reusable substrate facts.  It uses logical storage IDs such as
`backup-primary`: device nodes and mount paths are intentionally absent, so a
disk replacement does not alter an application's storage identity.  Public
locations declare only requirements and thresholds — separate Wi-Fi and
Ethernet throughput minimums, signal, filesystem, capacity, backup transfer
windows, and whether a stable tailnet identity is required.

The owner creates a separate JSON overlay from
`location-network-storage.overlay.example.json`, keeps it outside this
repository, and sets it to mode `600`.  All private locators live only in the
overlay: the active SSID, the path to an owner-only credential file, the
stable tailnet identity, and mount paths.  `tailnet_identity` is required only
for a location whose public `tailnet.required` is true; `wifi` is likewise
required only where the public Wi-Fi requirement is true.  A wired,
no-tailnet location therefore needs no placeholder identity, SSID, or
credential path.  Optional evidence may still be supplied and is checked.
Neither file is printed by the preflight, and credentials themselves are
never stored in JSON.

Run a non-mutating preflight on the target host:

```sh
python3 profiles/preflight.py \
  --profile profiles/location-network-storage.example.json \
  --overlay /owner-private/brokkr/location-overlay.json
```

Both files are validated against tracked, closed Draft 2020-12 schemas before
any host evidence is gathered: `location-network-storage.schema.json` and
`location-network-storage.overlay.schema.json`.  The dependency-free runtime
implements and verifies only the documented schema subset, rejecting any
unsupported schema keyword so a schema edit cannot silently drift from runtime
behavior.  Unknown, mistyped, malformed, and out-of-range fields are rejected
with messages that name the offending field but never echo owner-supplied
values or paths.

The preflight is strictly read-only.  It proves the overlay's tailnet
identity against a running and online Tailscale backend, requires the
expected Wi-Fi connection profile to exist with autoconnect enabled even
while Ethernet is active, and validates the owner-selected Wi-Fi association,
signal, and link throughput when Wi-Fi carries traffic — or the Ethernet
link speed against the wired threshold otherwise.  Storage checks use
machine-readable `findmnt` evidence and require its canonical mount target to
equal the declared canonical overlay path; subdirectories and symlinked paths
are rejected.  Mount options and conservative permission evidence replace a
write probe, alongside filesystem, capacity, and each declared transfer
window.  Every external command is time-bounded and parsed locale-independently.
It fails closed whenever evidence is missing.  It does not configure a network,
mount a volume, create files, or run a backup.  Backup producer/consumer
semantics remain in their owning component repositories.
