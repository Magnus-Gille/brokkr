# Read-only node inventory (brokkr#7)

Run `make node-inventory`. Standard output is exactly one schema-valid Grimnir v1
`node-capability` record; standard error is the concise operator view, including
observed unit names. Treat that view as private runtime evidence. A failed probe
produces `capability_status: unknown`, conservative placeholder resources required by
the schema, and an explicit `partial probes=` notice; it cannot silently satisfy a
placement capability.

This is the Brokkr observation producer side of the versioned node-agent boundary in
#2. It intentionally does not add an ownership or upgrade protocol: that work remains
with #2, while the cross-system schema remains pinned to Grimnir.
