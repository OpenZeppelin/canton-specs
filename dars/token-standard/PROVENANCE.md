# Token Standard DAR provenance

Built from the local `splice/` checkout (hyperledger-labs/splice, `main`) at commit
`69b43eb761e38695052c983715aa855c8cb207fc`, packages under `token-standard/`.

Two local patches were applied before building (source unchanged otherwise):

- `sdk-version: 3.5.2` -> `3.5.1` in each `daml.yaml` (3.5.2 is not distributed;
  3.5.1 is the closest dpm-sdk available locally). Built with `dpm build`.
  All packages target LF 2.1.
- data-dependency DAR names `-current.dar` -> `-1.0.0.dar` (the splice CI renames
  package versions to `current`; a plain build emits the versioned name).

Token Standard V2 (CIP-0112) is devnet-stage upstream. When upstream cuts a
release, replace these DARs with the released artifacts and re-validate; package
ids will change.

To rebuild: copy the 13 package directories to a scratch area, apply the two
patches above, and `dpm build` them in dependency order (metadata-v1 first,
`splice-token-standard-utils` last).
