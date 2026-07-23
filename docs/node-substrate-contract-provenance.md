# Node/substrate v1 contract provenance

The canonical shared schema and public-safe fixture set are consumed unchanged from
`Magnus-Gille/grimnir@6d54d49c91612eae7dce5f66286d801900c38c35`:

- `docs/node-substrate-contract-v1.schema.json`
- `tests/fixtures/node-substrate-contract/{positive,partial-drain,partial-substrate,negative,consumer-fixture-set}.json`

They are an interoperability boundary, not a Brokkr-owned semantic protocol. Brokkr
only produces observed `node-capability` records. Runtime output and probe detail stay
outside this repository; repository fixtures must use reserved/public-safe values.

SHA-256 pins: schema `9a69f1b23499cd6e70fdaa80ee57bf983e7e5b288882e0cf2b0f01f10824fbbe`;
fixtures `consumer-fixture-set=355481f2b3866840795ba18033077d6f36487d1a447b36c323384cf7837c5fcb`,
`negative=e67d9233a556aa6da9728e9c07ae95ac3b1bc9abe9a4ac8ad817158829b8ead5`,
`partial-drain=b596e56fb60a0710e1653c1a7935e15a98baf818b7ce6c56421a84cfbdd21d7b`,
`partial-substrate=3a26d123bfcb98adbd8f8f81c2736b38d485a1ac2665deb1770636f219ba6d07`,
and `positive=42f34fe1c576648240cef0f7f427073e9f39c11f8bfe0cf3f2ea74899bfee234`.
