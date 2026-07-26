# Platform faults and node-agent negotiation

`brokkr-platform-fault/v1` is a small operational record, not a second node
inventory. Its `node_substrate_ref` links every fault to the immutable Grimnir
node/substrate v1 observation that supplied the node identity and capability
facts. The fault adds only a category, severity, evidence/provenance, bounded
freshness, and one recovery owner.

The first detectors cover the platform failures not represented by the existing
disk-capacity/mount, failed-systemd-unit, and agent-watchdog checks: a mounted
filesystem turning read-only, loss of time synchronisation, and a changed boot
identity. They are read-only signal projections; production command details,
hostnames, state locations, and incidents belong in an owner-only overlay.

Before an agent is installed or upgraded, its `brokkr-node-agent-handshake/v1`
is checked against the deployment's required platform-fault and node/substrate
versions:

```sh
node scripts/node-agent-compatibility.mjs --agent agent.json --deployment deployment.json
```

An unavailable version is rejected before installation. Public fixtures use
synthetic identifiers only.
