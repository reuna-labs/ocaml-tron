# Fuzzing

`fuzz/` holds six Crowbar targets. They run two ways from one source, which is
the point: a fuzz target that only builds on a special switch stops building
and nobody notices.

| Target | What it attacks |
| --- | --- |
| `fuzz_address` | Base58Check, hex and ABI-word decoding; the round trip; single-character mutation of a Base58Check string |
| `fuzz_raw_data` | The protobuf decode path, byte retention, the `Any` narrowing, and that nothing decoded is ever approvable by accident |
| `fuzz_http` | HTTP/1.1 framing, at every chunk size, against the body and header limits |
| `fuzz_json` | java-tron's response decoders, and the block number/id consistency check |
| `fuzz_signature` | Signature decoding, the two `v` conventions, and sign/verify/recover |
| `fuzz_submission` | The submission state machine under arbitrary event orders |

## Running them

As ordinary randomised tests, which is what CI does:

```sh
OPAMSWITCH=reuna-5.5 opam exec -- dune build fuzz/
for t in fuzz/*.exe; do OPAMSWITCH=reuna-5.5 opam exec -- dune exec "$t"; done
```

As real fuzz targets, which needs an AFL-instrumented compiler and therefore a
switch of its own — `reuna-5.5` is shared with nethsm's confidential unikernel
builds and must not grow an instrumented compiler:

```sh
opam switch create tron-afl ocaml-variants.5.5.0+options ocaml-option-afl --no-switch
opam install --switch tron-afl crowbar zarith digestif  # and the rest of the closure
mkdir -p /tmp/afl-in && echo seed > /tmp/afl-in/seed
afl-fuzz -i /tmp/afl-in -o /tmp/afl-out -- ./_build/default/fuzz/fuzz_raw_data.exe @@
```

## What the properties are, and why those

Crashing is the floor, not the goal. Each target asserts something that would
still be a defect if nothing ever raised:

- **`fuzz_raw_data`** — a decoded `raw_data` keeps the bytes it decoded, and
  the wire form carries those same bytes. This is what stops a signature
  covering something other than what gets broadcast, and it is the property
  that a real defect in `Transaction.to_bytes` violated before it was found.
- **`fuzz_http`** — feeding the same response in two different chunk sizes
  gives the same answer. A parser correct only on convenient chunk boundaries
  is wrong on a socket.
- **`fuzz_json`** — a block whose number and id disagree never decodes, and a
  consistent one always does. The second half matters: a check that passes by
  rejecting everything is not a check.
- **`fuzz_signature`** — only `v` in `{0, 1, 27, 28}` decodes, and signing is
  deterministic. Determinism is what makes the two-oracle conformance
  comparison mean anything.
- **`fuzz_submission`** — after expiry the machine never asks for a broadcast
  without a rebuild first, and never reports finality it was not shown
  evidence for.

## What they found

On the first run, four defects. Three were in this repository's contracts and
one was in a dependency:

1. **A segfault in `ocaml-protoc-plugin`'s reader**, from 85 bytes.
   `validate_capacity` compares `t.offset + count <= t.end_offset`, and `count`
   is `Int64.to_int` of an attacker-chosen varint; a large value overflows the
   addition to negative, the check passes, and `String.unsafe_blit` reads past
   the buffer. Fixed in `ocaml-web3-codec`'s vendored runtime; should go
   upstream. Nothing on the caller side could have defended against it.
2. **`from_proto` raises despite returning a `result`.** `Result.catch` handles
   only the library's own exception, so a `Failure` from the field-header
   reader escapes. `Proto_decode.protect` now wraps every decode here.
3. **`Tron_crypto.public_key_of_bytes` raised** on a short buffer announcing a
   compressed point.
4. **Terminal submission states were not absorbing**, so a machine that had
   given up could be driven back into asking for a broadcast.

The first is the one worth the exercise on its own: it was reachable from any
node this library talks to, and no amount of careful code above it would have
mattered.

## Status

Bounded randomised runs only, in CI and by hand. **No sustained AFL campaign
has been run**, which is what L6 actually asks for; see `docs/release.md`.
