# Android Oracle candidate control plane

This directory is a read-only validator. It accepts candidate artifacts, proves
their internal bindings, canonicalizes exact JSON, and compares protected shared
channels. It cannot publish, accept, record, promote, or update a golden.

Commands:

```text
doctor
canonicalize --input FILE
compare --expected-payload FILE --actual-artifact FILE
verify-proposal --proposal FILE --request-work-item ID
```

Every command also requires `--root REPOSITORY`. Output is stdout only; there is
no output-path or in-place option.

## Hash contracts

- Control JSON hashes are SHA-256 of the parsed document emitted with exact
  number tokens, sorted object keys, UTF-8, and no trailing newline.
- A generic fixture hash is SHA-256 of the canonical array of sorted
  `{path, sha256(raw_file_bytes)}` entries. It is not a SourceLab scenario hash.
- Payload hash and byte count bind the same raw bytes. A payload must already be
  canonical-v1 bytes.
- Proposal bindings cover the frozen Android commit/tree, clean checkout,
  runner/image digests, protected request work item, baseline, generic fixture
  manifest, Fact inventory, Requirement catalog, envelope schema, canonicalizer
  config/implementation, and comparator implementation.

The repository validator does **not** prove that a claimed runner, commit, or
attestation actually produced the payload. The trusted external Supervisor must
verify CI identity, job inputs, signatures, and attestation before a separate
publisher may change protected goldens. A valid proposal always remains
`candidate_only`.

## Comparison contract

The shared view compares envelope identity/profile, request plan, decode,
stages, result type, `portable_known_projection`, and issues. Android
`android_characterization`, iOS `ios_lossless_extension`, and engine
platform/revision are explicit extensions or provenance and are not compared.
Unknown result lanes fail closed.

The exact parser preserves arbitrary number tokens, rejects duplicate and
canonically-equivalent object keys, non-finite values, invalid UTF-8, unpaired
surrogates, excessive nesting, and oversized inputs. Object keys are preserved;
their deterministic order uses NFC identity followed by raw UTF-8.
