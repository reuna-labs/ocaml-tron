# Security

## Status

**Unaudited alpha. Do not use this to control assets of value.**

Nothing here has been released, independently reviewed or fuzzed, and its
dependency closure includes private repositories. The launch gates in
`vault/Reuna/Attic/OCaml web3 state of the art status.md` place this at L6 —
release and assurance — not started.

## Reporting

Privately, to `security@reuna.io`. Please do not open a public issue for
anything affecting the signing path.

## Fixed, and worth knowing about

Fuzzing found a **segfault in `ocaml-protoc-plugin`'s reader**, reachable from
85 bytes of protobuf sent by a node. An integer overflow in its bounds check
let `String.unsafe_blit` read past the buffer. It is fixed in the vendored
runtime in `ocaml-web3-codec`; the details are in `docs/fuzzing.md` and that
package's `lib/protobuf/README.md`.

Two things about it matter beyond this library. No caller-side guard could have
helped -- a segfault is not an exception, so neither `Result.catch` nor a `try`
around `from_proto` would have caught it. And it is upstream's bug, not a
vendoring artefact: **any project decoding untrusted protobuf with
`ocaml-protoc-plugin` is exposed** until it is reported and fixed there.

## Known limitations

### Not constant time

`mirage-crypto-blockchain`'s `Secp256k1` carries a "NOT CONSTANT TIME" banner in
its own interface. `tron-crypto` therefore hands it only public data — a
signature, a digest and a recovery id, all about to be broadcast — and routes
every operation on a private key through `mirage-crypto-ec`'s fiat-crypto
`P256k1.Dsa`, which is constant time.

That split is load-bearing and easy to undo by accident: the reference backend
also offers `sign` and `sign_recoverable`, and either would put a secret key
through non-constant-time scalar multiplication. `lib/crypto/dune` says so.

### The signer's authority is not checked here

Nothing in this library knows whether the key it is signing with is authorised
to. Permissions live on chain, `Permission` makes a fetched one legible, and
that is where the check belongs. A transaction this library builds and signs is
not a transaction the chain will accept.

### An intent is not a guarantee

`Intent.derive` says what a transaction's bytes mean. It does not say what a
contract will do. `Trc20_call` means the call data looks like a TRC-20
function; whether that contract address is the token anyone thinks it is, is a
question only the caller can answer — which is why
`validate_trc20_transfer` has no default for `trusted_contracts` and will not
accept one.

### Cross-chain replay is prevented by the reference block, not a chain id

A Tron transaction carries no chain id. What stops a signed transaction
replaying onto another Tron chain is that its `ref_block_hash` names a block
that exists only on the chain it was read from. A signer that does not know
which chain its reference block came from cannot claim the transaction is bound
to one; `Network.verify` against the node's genesis block is how to find out,
and it has to happen before signing.

### The Unix transport is plaintext

`tron-rpc-unix` speaks HTTP/1.1 over whatever flow it is given. Public Tron
endpoints are HTTPS. Wrap the descriptor in a TLS flow before handing it over —
a TLS flow is a flow — or point it at a local node. `examples/nile_transfer.ml`
refuses an `https://` URL rather than connecting anyway.

## Signing elsewhere

The external-signer path is `Transaction.signing_bytes` and
`Transaction.add_signature`: the signer is handed a 32-byte digest and returns
65 bytes, and never sees a key belonging to this process.

`add_signature` deliberately does not verify what it is given. Which key may
sign is a permission question, and a check against "some key" would be theatre.
Use `Transaction.recover_signers` against a `Permission` the caller fetched.

**Derive the intent from the bytes, evaluate it, and enforce a policy before
signing.** `Intent.derive` takes the serialized `raw_data` and nothing else,
precisely so that what a reviewer is shown and what gets signed are the same
object. A signer that renders `Intent.pp` cannot omit `permission_id`,
`fee_limit` or `expiration` by accident — the vault document names hiding those
as the Tron signing failure mode.

## Two hashes, and they are not interchangeable

- The transaction id and the signing digest are **SHA-256** over the serialized
  `raw_data`.
- **Keccak-256** appears only in address derivation and ABI selectors.

Both produce 32 bytes, so swapping them is neither a type error nor a runtime
failure. It is the most dangerous mistake available in this repository.

## Live-network use

`examples/nile_transfer.ml` is the only executable here that signs with a real
key and touches a network. It refuses every missing input rather than
defaulting, verifies the node's genesis block against a configured value before
signing anything, re-derives the intent from the bytes it is about to sign, and
runs a policy over it. It is reachable only through a manually dispatched
workflow gated behind a GitHub Environment, never on push.

Mainnet is out of scope for the alpha.
