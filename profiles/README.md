# Location, network, storage, and backup-role profiles

`location-network-storage.example.json` is a versioned, public declaration of
reusable substrate facts.  It uses logical storage IDs such as
`backup-primary`: device nodes and mount paths are intentionally absent, so a
disk replacement does not alter an application's storage identity.

The owner creates a separate JSON overlay from
`location-network-storage.overlay.example.json`, keeps it outside this
repository, and sets it to mode `600`.  The overlay contains private locators
and the active SSID plus a path to an owner-only credential file.  Neither file
is printed by the preflight.  Credentials themselves are never stored in JSON.

Run a non-mutating preflight on the target host:

```sh
python3 profiles/preflight.py \
  --profile profiles/location-network-storage.example.json \
  --overlay /owner-private/brokkr/location-overlay.json
```

Preflight proves the configured tailnet identity separately from LAN and mDNS,
uses Ethernet when ready and otherwise validates the owner-selected Wi-Fi
association, and checks signal, link throughput, mounts, filesystem, a
create-and-remove write probe, capacity, and each declared transfer window.
It fails closed whenever evidence is missing.  It does not configure a network,
mount a volume, or run a backup.  Backup producer/consumer semantics remain in
their owning component repositories.
