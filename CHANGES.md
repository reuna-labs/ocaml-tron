# Changes

## 0.1.0~alpha2 (2026-08-30)

- Added verified HTTPS for public providers using the system CA store,
  hostname verification and SNI, while keeping the pure/Mirage flow packages
  free of Unix and TLS dependencies.
- Added strict endpoint parsing and three endpoint regression tests; the full
  public matrix now passes 97 tests on OCaml 4.14.2 and 5.2.1.
- Made the Mirage Crypto fork pins semver-compatible with TLS's dependency
  solver.

## 0.1.0~alpha1 (2026-08-30)

The G6 kickoff milestone: the offline path, a transport that reaches both Unix
and Solo5 vsock, and two independent conformance oracles.

### Added

- **`tron-proto`** — protobuf bindings generated from `tronprotocol/protocol`
  at `8432bec`, committed, so an ordinary build needs neither `protoc` nor
  `ocaml-protoc-plugin`.
- **`tron-types`** — addresses (21-byte binary as the type, Base58Check / hex /
  ABI word as renderings), checked `sun` amounts, transaction ids, and block
  references that slice `[6,8)` of the number and `[8,16)` of the id.
- **`tron-crypto`** — secp256k1 recoverable signing over a SHA-256 digest.
  Constant-time backend for the secret path, reference backend for recovery,
  following `ocaml-evm`'s split. Deterministic nonces; no RNG.
- **`tron-transaction`** — a closed contract variant over `google.protobuf.Any`
  with an opaque fallback, `raw_data` construction and decoding, signing and
  multisig accumulation, the permission model including the operations bitmap,
  TRC-20 through `evm-abi`, and an intent layer derived from the signed bytes.
- **`tron-rpc`** — the `/wallet/*` catalogue, java-tron's non-canonical JSON,
  a fee model, a tagged confirmation state, and a submission state machine in
  which expiry forces a rebuild rather than a replay.
- **`tron-rpc-flow` / `tron-rpc-unix`** — HTTP/1.1 over any `Mirage_flow.S`;
  the Unix path is the same functor applied to a file descriptor or a verified
  TLS flow. HTTPS uses the system trust store, hostname verification and SNI.
- **`tron-rpc-grpc`** — the Wallet service over gRPC, decoding into the same
  types the HTTP client produces, and functorised over the same flow. Closes
  the G6 gate that HTTP and gRPC responses must agree.
- Conformance fixtures from TronWeb 6.5.0 and trident 1.0.0, both offline.
- `test/no_io_guard.sh` and two link proofs, run in CI.
- **A real Solo5 unikernel.** `validation/solo5-image/` cross-compiles GMP and
  zarith against `ocaml-solo5` and boots an `sptmac` guest that runs the whole
  offline path and checks its own address against the TronWeb fixture.
- Six Crowbar fuzz targets, a threat model with a review scope, and a release
  checklist that names what blocks a release. The targets found four defects on
  their first run, one of them a segfault; see below.

### Found along the way

- **Both `v`-byte conventions are on chain.** trident writes the raw recovery
  id; TronWeb writes it plus 27. java-tron accepts both, and mainnet block
  85634951 carries both. Decoders here accept either; the writer defaults to
  the recovery id. Documentation naming only one is incomplete rather than
  wrong. See `conformance/README.md`.
- **`ocaml-protoc-plugin` cannot generate working code for Tron's schema
  unaided.** `ResourceReceipt` is declared before `Transaction` and refers to
  `Transaction.Result.ContractResult`; forcing that during module
  initialisation raises `Undefined recursive module`. Upstream's `apply_lazy`
  (PR #27) covers exactly this failure but only on Melange, and only for the
  serialisers — `merge` is emitted eagerly and is not routed through it. Both
  are addressed in `ocaml-web3-codec`: the runtime patch and
  `tools/lazify-merge.py`. Either alone still raises. Should go upstream.
- **A response arriving in one read lost its HTTP status.** The lifted parser
  returned `Done of string`, discarding the state that held the status line, so
  a 503 carrying a JSON body read as success. `Done` now carries the status.
- **The wire form did not preserve the bytes that were signed.**
  `Transaction.to_bytes` decoded the `raw_data` and re-encoded it. Protobuf
  permits encodings that decode alike and re-encode differently -- a
  non-repeated scalar appearing twice, redundant varint padding, fields out of
  tag order -- so a transaction decoded from anywhere else went onto the wire
  with a different id than the one that was signed and reviewed. The wire form
  is now framed by hand around the retained bytes. Surfaced by designing the
  gRPC broadcast path, which would have made the same mistake more loudly.
- **A segfault in the protobuf reader, from 85 bytes of untrusted input.**
  `reader.ml`'s bounds check is `t.offset + count <= t.end_offset`, and `count`
  is `Int64.to_int` of a varint the sender chose. A large value overflows the
  addition to negative, the check passes, and `String.unsafe_blit` then reads
  far past the buffer. No caller-side guard helps -- a segfault is not an
  exception. Fixed in the vendored runtime by comparing against the remaining
  space, which cannot overflow. **Should be reported upstream**: anything
  decoding untrusted protobuf with `ocaml-protoc-plugin` is exposed.
- **`from_proto` raises despite returning a `result`.** `Failure "Illegal field
  header"` escapes `Result.catch`, which handles only the library's own
  exception. Every decoder here now goes through `Proto_decode.protect`.
- **`public_key_of_bytes` raised on a short compressed point.** A 29-byte
  buffer announcing a compressed point sends `mirage-crypto-ec`'s `decompress`
  past the end and `String.sub` raises. Public keys come off the wire and the
  function's type promises a `result`.
- **Terminal submission states were not absorbing.** A machine that had given
  up could be walked back into asking for a broadcast. A driver would not
  normally do that, but a pure state machine should not depend on being driven
  politely.
- **The Solo5 allocator problem was already solved.** A first attempt at the
  unikernel wrote a shim mapping `malloc` onto `ocaml_solo5_malloc`. It was the
  wrong answer: ocaml-solo5 force-includes `<_solo5/overrides.h>` into every C
  compile precisely so a guest never exports `malloc`, and the sgx reason for
  that is sharp. The shim also did not work -- GCC folds such a forwarder into
  its callee. Building GMP through the same header removed both the shim and
  the flags it needed.
- **gRPC did not have to be Unix-only.** The earlier assessment was that
  HTTP/2 does not fit the flow model. It does: what h2 needs from a transport
  is `Gluten_lwt.IO`, which is four functions, and `Io_of_flow` implements them
  over a `Mirage_flow.S`. Taking `h2-mirage` instead would have worked and
  pulled 48 packages, conduit-mirage and tcpip among them, on targets that have
  no network stack.

### Not done The link proof is structural; the sptmac cross-compile
  has an open question about GMP, recorded in `docs/unikernel.md`.
- Live Nile evidence. The workflow exists and has not been run.
- The confidential Solo5 targets. Only `sptmac` is built; `sgx`, `nitro`,
  `cca`, `snp` and `tdx` are untested.
- A sustained fuzz campaign. The targets run bounded in CI; a real campaign
  needs an AFL-instrumented switch.
- A public dependency closure, and therefore a release. `docs/release.md`.
- Release, fuzzing, threat model, independent review — all of L6.
