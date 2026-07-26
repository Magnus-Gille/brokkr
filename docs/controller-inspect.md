# Controller node inspection

`make inspect ARGS=<stable-node-id>` is Brokkr's read-only controller path for
a node's existing v1 capability record and its signed operational detail. It
accepts only a stable node ID, never a hostname. The node's owner-only overlay
maps that ID to a permitted SSH host alias, remote checkout, detail public key,
and location evidence. Copy
`profiles/controller-inspect.overlay.example.json` outside this repository,
replace every example value, and set it mode `0600`:

```sh
BROKKR_INSPECT_OVERLAY=/owner-private/brokkr/controller-inspect.json \
make inspect ARGS=example-node
```

The transport is fixed to batch-mode SSH with a five-second connection timeout,
a 15-second total timeout, and a 1 MiB output cap. The overlay cannot select an
executable or alter the remote command. The controller requires the returned
`node_id` to equal the requested configured ID, validates the returned
`node-capability` unchanged against the pinned Grimnir v1 schema, binds the
detail to that record's evidence values, and verifies its configured Ed25519
public key. A bad transport, identity mismatch, malformed contract record, or
untrusted detail is emitted only as a closed controller status; no remote
output is passed through.

`location_secret` is a high-entropy private stable token, not a human location name. Output
contains only its SHA-256 digest, timestamps, and `known`/`partial`/`unknown`
provenance. Moving a host changes this opaque evidence while preserving its
configured stable node identity. Expired node or location evidence is retained
as `partial` with `freshness: stale`; it is never reported as current.

This is inspection evidence, not placement intent. It does not write, merge, or
reinterpret desired state, and it performs no exploratory SSH or live mutation.
