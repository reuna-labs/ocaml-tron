# ocaml-tron

Tron for OCaml: the pinned protobuf wire types, 21-byte addresses and their
Base58Check spelling, secp256k1 recoverable signing, TRX / TRC-10 / TRC-20 /
TVM transaction construction with a byte-derived intent layer, and a typed
java-tron HTTP client that runs over a Unix socket or a Solo5 vsock without
changing implementation.

> **Unaudited alpha software. Do not use it to control assets of value.**
> No package here has been released, reviewed or fuzzed. See `SECURITY.md`.

## What it does

- **Addresses.** The 21-byte binary form is the type; Base58Check, hex and the
  20-byte ABI word are renderings of it.
- **Signing.** secp256k1 over the SHA-256 of a serialized `raw_data`, producing
  Tron's 65-byte `r ‖ s ‖ v`. Deterministic (RFC 6979), so a signature is
  reproducible and comparable against another implementation's.
- **Transactions.** TRX transfers, TRC-10 transfers, TVM calls including
  TRC-20, staking and resource delegation. Built locally — never by the node.
- **Intent.** A reviewable meaning derived from the bytes about to be signed,
  with `permission_id`, `fee_limit` and `expiration` as first-class fields, and
  allow-list policies over it.
- **Client.** The `/wallet/*` methods, a fee model, a confirmation state that is
  tagged rather than boolean, and a submission state machine in which expiry
  forces a rebuild rather than a replay.
- **Two transports, one set of types.** HTTP/1.1 with JSON and gRPC with
  protobuf, both decoding into the same OCaml values, and both functorised over
  `Mirage_flow.S` so either reaches a Solo5 vsock.

## What it does not do

Deliberately, and each is a decision rather than an omission:

- **Node-built transactions.** `/wallet/createtransaction` exists and is not
  used on the product path. Signing bytes the node chose means trusting it
  about the destination and the amount.
- **Unrecognised contract types.** Tron has 41; this decodes six. The rest
  decode as opaque, can be displayed, and can never satisfy a policy.
- **Deciding whether a signer is authorised.** Permissions live on chain.
  `Permission` makes one legible; fetching it is the caller's job.
- **Reading a clock, or drawing randomness.** Neither happens anywhere in
  `lib/`. Expiration is an input; nonces are deterministic.

## Layout

```
lib/proto/          generated protobuf, committed, from proto/ @ 8432bec
lib/types/          addresses, amounts, transaction ids, block references
lib/crypto/         secp256k1 recoverable signing, address derivation
lib/transaction/    contracts, raw_data, signing, permissions, TRC-20, intent
lib/rpc/            the /wallet/* catalogue, fees, confirmation, submission
lib/rpc_flow/       HTTP/1.1 over any Mirage_flow.S -- including Solo5 vsock
lib/rpc_grpc/       the Wallet service over gRPC, over the same flow signature
lib/rpc_unix/       the HTTP functor, applied to a Unix file descriptor
lib/umbrella/       the offline surface, with no transport in its closure

proto/              the pinned .proto tree
conformance/        two independent oracles and their golden fixtures
validation/solo5/       the Mirage link proof, offline closure only
validation/grpc-flow/   gRPC built over a flow that is not a socket
validation/solo5-image/ a real sptmac unikernel, GMP and zarith cross-compiled
fuzz/                   Crowbar targets for the parsers and state machines
examples/           the guarded Nile testnet executable
docs/               the specification pin, the build switch, the unikernel state
```

## Package boundaries

`tron-types`, `tron-crypto`, `tron-proto`, `tron-transaction`, `tron-rpc` and
the `tron` umbrella are free of Unix, Lwt, clocks, randomness and sockets.
`test/no_io_guard.sh` checks that from the declared dependencies, and
`validation/solo5/unikernel.exe` checks it again by linking the closure with no
transport at all. Both run in CI on every commit.

`tron-rpc-flow`, `tron-rpc-grpc` and `tron-rpc-unix` own the socket. They are
separate packages so that a consumer linking `tron` takes on none of them.

`tron-rpc-flow` and `tron-rpc-grpc` are held to a second rule: they may have
Lwt and a flow, but nothing that assumes a host operating system or a TCP
stack, because the confidential Solo5 targets have neither. The guard checks
that too, and `validation/grpc-flow/` builds the gRPC client over a flow made
of two in-memory buffers to prove the functor closes without one.

That is why `tron-rpc-grpc` uses `h2-lwt` and implements `Gluten_lwt.IO` over a
flow itself, rather than taking `h2-mirage`: `h2-mirage` would do the
functorising, but its closure is 48 packages -- conduit-mirage, tcpip, tls,
x509, dns-client, vchan, xenstore -- because it assumes a stack. What h2
actually needs from a transport is four functions.

## Running as a unikernel

Two claims. The offline closure contains no I/O, checked on every commit by
`test/no_io_guard.sh` and two link proofs. And it runs as a real Solo5 guest:

```sh
OPAMSWITCH=reuna-5.5 ./validation/solo5-image/build.sh
```

That cross-compiles GMP and zarith against `ocaml-solo5`, builds an `sptmac`
image, and boots it. Unlike `ocaml-cardano`, a Tron guest cannot avoid a
bignum -- Base58, secp256k1 recovery and the ABI's `uint256` all need one --
so GMP had to be made to cross-compile. `docs/unikernel.md` records the four
obstacles and the run.

## Build

This repository builds in the shared **`reuna-5.5`** opam switch and carries no
local `_opam`. That switch is the opam global default and is shared with
nethsm's confidential unikernel builds, so changes to it must be additive.
**Read `docs/switch.md` before running any opam command here.**

```sh
export OPAMSWITCH=reuna-5.5
opam install --switch reuna-5.5 --deps-only --with-test --show-actions .  # look first
opam install --switch reuna-5.5 --deps-only --with-test .
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- ./test/no_io_guard.sh
```

Regenerating the protobuf bindings needs a second, dedicated switch; the
generated sources are committed, so an ordinary build does not.
See `docs/protocol-pin.md`.

## HTTP and gRPC

Both clients decode into the same types, which is what makes
"the two transports agree" a claim that can be tested rather than a slogan.
`test/test_grpc_parity.ml` feeds each decoder a body the node would have sent
and compares the results -- blocks, accounts, resources, chain parameters,
energy estimates, receipts, reverts and the absent/pending cases where an empty
answer must not read as an error. It also checks that both reject an
inconsistent block: a check present on one wire path and not the other is a
check an attacker picks their way around.

Prefer gRPC for reads. Protobuf has types, so there is no hex-versus-base64
question and no `visible` flag changing the shape of a reply. For broadcast the
two are equivalent here, because neither re-encodes: both send
`Transaction.to_bytes`, which carries the signed `raw_data` through unchanged.

## Conformance

Golden bytes come from two independent implementations — TronWeb 6.5.0
(JavaScript) and trident 1.0.0 (Java, the official java-tron SDK) — generated
offline and committed. Tests compare against those literals, never against
this library's own output.

The two agree on `raw_data`, on the transaction id, and on `r` and `s` for
every signature. They differ on the signature's `v` byte, and that divergence
is asserted rather than resolved: see `conformance/README.md`.

## Status against the launch gates

`vault/Reuna/Attic/OCaml web3 state of the art status.md` measures each chain
against L0–L6. Honestly, for this repository:

| Gate | State |
| --- | --- |
| **L0** specification pin | Pinned. `docs/protocol-pin.md` records the schema commit, the node release, both oracles, and every rule that is not in the `.proto` files. |
| **L1** canonical data | Addresses, amounts, ids and block references validated at construction, with rejection tests and two-oracle agreement. |
| **L2** offline transaction path | Green. Five transaction shapes produce byte-identical `raw_data`, transaction ids and signatures against both oracles. |
| **L3** online client path | Typed reads, simulation, submission and a tagged confirmation state, over HTTP and gRPC alike, both reaching Unix and vsock. **No live-network evidence yet.** |
| **L4** product policy | An intent derived from the signed bytes, with permission, fee limit and expiration always shown, and allow-list policies. Not yet bound into a signer transcript. |
| **L5** conformance | Hermetic, two independent oracles, negative cases, and HTTP/gRPC parity. The scheduled testnet suite exists but has not been run. |
| **L6** release and assurance | **Partial.** Threat model and review scope written, fuzz targets exist and run in CI. Unreleased, unaudited, no sustained fuzz campaign, and the dependency closure is still private -- see `docs/release.md`. |

Launch-blocked, and the blockers are named rather than implied.
