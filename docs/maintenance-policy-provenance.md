# Maintenance-policy v1 contract provenance

The canonical schema and public-safe fixture set are consumed unchanged from
`Magnus-Gille/grimnir@a201afdab7accc5f32111dbc593a15063985cff2`:

- `docs/maintenance-policy-v1.schema.json`
- `tests/fixtures/maintenance-policy/{normal-window,hold,missed-window-decision,negative,dst-transition}.json`

They are an interoperability boundary, not a Brokkr-owned semantic protocol. Grimnir's
`docs/maintenance-policy-contract.md` (not vendored here — Brokkr consumes the machine
schema plus its own dependency-free re-implementation of the normative semantics in
`scripts/lib/maintenance-policy-contract.mjs`, mirroring the pattern already used for
`docs/node-substrate-contract-provenance.md`) is the normative prose. This contract
expresses **intent only**: a `maintenance-policy` record never proves eligibility, and a
`maintenance-decision` record is a mechanical projection bound to an opaque Brokkr
evidence pointer — never a live observation or a mutation authorization. Brokkr's own
`scripts/maintenance-plan.mjs` (brokkr#33) is the first real producer of
`maintenance-decision` records, always alongside its own fresh, freshness-checked
`node-capability` observation (brokkr#7) and additional Brokkr-owned safety gates
(package-manager lock, disk, power, clock, signed source, workload-hook readiness,
recovery eligibility) that this contract explicitly says it cannot substitute for.

SHA-256 pins: schema
`c5d26173698c976ab8c330f41f6bf97c8a921ccecb81b7f4659954524b3503e1`;
fixtures `dst-transition=388f86fbe57bcf6c498297150db038f66c7e3d57c6d1f48a7d035476ce24c811`,
`hold=16718fb3f35f0cde4eb9d6037198befd7553585cba082c064a1103673c8aa262`,
`missed-window-decision=996b0dd5194bb1a76b7e1b7b971ed52f88e1f60f328e42658c5418409e6d918a`,
`negative=b8136ab3862be99f5d3b9ada3916b31364f7ca2f6ac8286d6bb6aa4dadb3b067`,
and `normal-window=a1723557d036c94e76ebcee202aa95f8dcfe7ddbb8405d91b0ab2c9fe5c1eb17`.

The vendored copies were re-verified byte-identical against that upstream commit, and
`scripts/test/maintenance-plan.test.sh` recomputes every pin on each run (schema,
provenance note, and all five fixtures), so any local drift from the immutable Grimnir
contract fails the suite. `scripts/lib/maintenance-policy-contract.mjs` additionally pins
the schema and this provenance note by hardcoded SHA-256 at runtime (mirroring
`scripts/lib/node-substrate-contract.mjs`'s `assertPinnedContractFiles`), so an accidental
or hostile local edit to either file is refused before it is ever parsed.
