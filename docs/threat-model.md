# Threat model

What this library is trusted for, what it is not, and where the boundaries are.
Written for the independent review L6 asks for; the scope that review should
cover is at the end.

This is about `ocaml-tron` specifically. The platform-level model — attestation,
sealing, fencing — lives in `../vault/Reuna/SDD/`.

## What the library is

A signer and a client. It turns an intention into bytes, hashes them, signs
them, and sends them to a node. It also reads the chain back. It holds no
policy of its own beyond the allow-lists in `Intent`, and it decides nothing
about authority.

## Assets

| Asset | Where it lives | What loss looks like |
| --- | --- | --- |
| The private key | Supplied by the caller; never generated here | Funds move without authorisation |
| The signed bytes | `Transaction.to_bytes` | The chain executes something other than what was reviewed |
| The reviewer's understanding | `Intent.derive` and `Intent.pp` | A human approves a transaction they did not read |
| Chain identity | `Network.verify` against block 0 | A transaction is replayed onto a different Tron chain |

## Adversaries

### A hostile or compromised node

The one this library is mostly written against, because it is the party it
talks to and cannot authenticate.

It can: return any bytes, lie about the head, lie about fees, lie about a
receipt, withhold a receipt, replay an old block, return a well-formed
transaction that is not the one asked for, and fail in the middle of a
broadcast so the caller cannot tell whether it landed.

It cannot: change what gets signed. The library builds `raw_data` locally and
never asks the node to build it — `/wallet/createtransaction` is used only as a
test oracle. The digest is computed over bytes the library produced, and the
wire form carries those exact bytes.

Mitigations, and their limits:

- **Chain identity.** `Network.verify` compares block 0 against a value the
  deployment configured. A Tron transaction carries no chain id; the only thing
  binding it to a chain is a reference block taken from this node, so this
  check has to happen before signing. It is not automatic — a caller that skips
  it gets no warning.
- **Reference block consistency.** `Block_ref.of_block` rejects a block whose
  number and id disagree, on both transports. It does not detect a *stale but
  internally consistent* block; expiry is what bounds that, and expiry is
  supplied by the caller's clock.
- **Bounded reads.** `Http.limits` caps headers and body. A declared
  `Content-Length` is a claim, not a fact.
- **Simulation is not a promise.** `estimate_energy` runs against state that
  will have moved. `Fees.suggested_fee_limit` adds headroom; the reviewer still
  sees the number.
- **Broadcast ambiguity.** A transport failure mid-broadcast leaves it unknown
  whether the node accepted. The submission machine polls for the receipt
  rather than resending, because the transaction id is deterministic and a
  duplicate is refused — so polling answers the question and resending does
  not.

### A malicious counterparty or contract

Can: publish a contract that exposes `transfer(address,uint256)` and does
something else; craft a transaction whose `Any` names a contract type this
library does not model; put a plausible-looking address in an ABI word.

Mitigations:

- **Unrecognised is not approvable.** Any `type_url` the contract layer does
  not know decodes to `Unknown`, reaches `Intent` as `Opaque`, and fails every
  policy. Adding a case to `Contract.t` moves something from unapprovable to
  approvable and is a security decision.
- **`trusted_contracts` has no default.** Nothing in the bytes distinguishes
  the real USDT from a contract that looks identical. `validate_trc20_transfer`
  will not accept an empty list by omission — the caller must name the
  addresses it means.
- **The ABI word is 20 bytes.** `Address.to_abi_word` strips the `0x41` prefix.
  Writing 21 bytes would shift every following byte without failing anything.

### Someone who can supply a transaction to be signed

The external-signer case: the library is handed bytes and asked to sign.

- `Intent.derive` takes the serialized `raw_data` and nothing else, so what is
  displayed and what is signed are the same object.
- `permission_id`, `fee_limit` and `expiration` are non-optional fields of the
  reviewable record. A signer rendering `Intent.pp` cannot omit them by
  accident — the vault document names hiding those as the Tron failure mode.
- `Raw_data.of_bytes` retains its source and `Transaction.to_bytes` frames
  around it, so a transaction supplied with unusual-but-legal protobuf framing
  is broadcast as received rather than re-encoded into a different id.

**Not mitigated:** whether the signing key is authorised. Permissions live on
chain. `Permission` makes a fetched one legible and `recover_signers` says who
signed; deciding is the caller's.

### An attacker observing timing

- Secret-key operations go through `mirage-crypto-ec`'s fiat-crypto
  `P256k1.Dsa`, which is constant time.
- Recovery goes through `mirage-crypto-blockchain`'s reference implementation,
  documented **not** constant time, and is given only a signature, a digest and
  a recovery id — all about to be broadcast.
- `Address.equal` and `Tx_id.equal` are `String.equal`, which is not constant
  time. They compare public values.

**The split is load-bearing and easy to undo.** The reference backend also
offers `sign` and `sign_recoverable`; calling either would put a secret key
through non-constant-time scalar multiplication. `lib/crypto/dune` says so.

**A known improvement:** `Mirage_crypto_ec.P256k1.Primitive` exposes
constant-time point arithmetic sufficient to do recovery without the reference
backend. Taking that route would remove the non-constant-time code from the
closure entirely, and remove one of the three reasons this library needs a
bignum. Not done; recorded in `docs/unikernel.md`.

### An attacker with the machine

Out of scope here and in scope for the platform. This library assumes its
process memory is private. In the intended deployment that assumption is
carried by the enclave, not by anything in `lib/`.

Keys are not zeroised after use. OCaml's GC moves and copies, so a library-level
wipe would be theatre; the enclave's memory lifetime is the real control.

## Trust boundaries

```
  caller's policy and key custody        <- not this library
        |
  Intent.derive / validate_*             <- the reviewable surface
        |
  Raw_data / Transaction                 <- the bytes; deterministic, no I/O
        |
  tron-crypto                            <- constant-time sign, public-data recover
        |
  ------------------------------------   the process boundary
        |
  tron-rpc                               <- pure; decides nothing about trust
        |
  tron-rpc-flow / -grpc / -unix          <- the socket
        |
  the node                               <- untrusted
```

Everything above the process boundary is deterministic and free of clocks,
randomness and I/O, checked by `test/no_io_guard.sh` on every build. That is
what makes the layer auditable in isolation: it cannot reach out, so its
behaviour is a function of its inputs.

## Assumptions

Stated so a reviewer can attack them:

1. **The caller supplies a correct current time.** Nothing here reads a clock,
   so `expiration` and freshness checks are only as good as the caller's clock.
   A signer with no trusted time source should not pass `?now` at all rather
   than pass a value it does not trust.
2. **The pinned schema matches the node.** `docs/protocol-pin.md` fixes a
   commit. A node running a different protocol version could interpret the same
   bytes differently. Nothing detects that.
3. **`digestif` and `mirage-crypto` are correct.** Their forks are not audited
   here.
4. **Base58Check has no second preimage that matters.** A 4-byte checksum
   catches accidents, not attacks; a Base58Check string is not a security
   boundary and should not be treated as one.
5. **The Solo5 image's GMP is correct.** It is cross-compiled from upstream
   source, checksummed, with a small shim mapping its allocator onto the guest
   heap. The shim is 30 lines and in the review scope below.

## What the review should cover

In rough order of how much a mistake would cost:

1. `lib/transaction/transaction.ml` — the wire form, and that it carries the
   signed bytes through unchanged. A defect here was found late; it is the
   part most worth a second pair of eyes.
2. `lib/transaction/intent.ml` — that what is displayed follows from the bytes,
   that no policy can be satisfied by an `Opaque`, and that `permission_id`,
   `fee_limit` and `expiration` cannot be dropped.
3. `lib/crypto/tron_crypto.ml` — the constant-time split, the low-S
   normalisation, and the recovery-id search.
4. `lib/transaction/contract.ml` — the `Any` narrowing, and that an
   unrecognised `type_url` cannot become a known contract.
5. `lib/transaction/permission.ml` — the operations bitmap and the
   deduplicating weight sum.
6. `lib/rpc/submission.ml` — that expiry forces a rebuild and never a replay.
7. `lib/rpc_flow/http.ml` and `lib/rpc/json.ml` — parsers on untrusted input.
8. `validation/solo5-image/heap_shim.c` — 30 lines of C in the guest.

Out of scope: the generated protobuf bindings (`lib/proto/gen/`), which are
machine-produced from a pinned schema and should be reviewed as a schema pin
rather than as code.
