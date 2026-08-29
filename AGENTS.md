# ocaml-tron

Tron for OCaml: the pinned protobuf wire types, 21-byte addresses and their
Base58Check spelling, secp256k1 recoverable signing over a SHA-256 transaction
id, TRX / TRC-10 / TRC-20 / TVM transaction construction with a byte-derived
intent layer, and a typed java-tron client over both HTTP and gRPC. Built to
run as a MirageOS/Solo5 unikernel, not only as a Unix library.

## Invariants

Signed-data libraries are deterministic and free of Unix, Lwt, environment,
clock, RNG and transport dependencies. `test/no_io_guard.sh` enforces this by
inspecting declared dependencies, not by grepping sources.

**Nothing here reads a clock.** `expiration` and `timestamp` in `raw_data` are
wall-clock milliseconds, and a signer that could fetch the current time could be
walked into widening its own validity window. The current time is an input.

**Nothing here draws randomness.** ECDSA nonces are RFC 6979 deterministic, so
no generator is needed and `mirage-crypto-rng` initialisation stays off a
unikernel's critical path.

**The node never builds a transaction this library signs.**
`/wallet/createtransaction` exists and is used only as a differential oracle in
tests. The product path constructs `raw_data` locally, hashes it, signs it and
broadcasts the bytes it built.

**Unrecognised is not approvable.** `Transaction.Contract.parameter` is a
`google.protobuf.Any`. Any `type_url` the contract layer does not know decodes
as opaque, reaches the intent layer as opaque, and cannot satisfy a policy.

**The bytes that were signed are the bytes that go out.** `Raw_data.of_bytes`
retains its source, and `Transaction.to_bytes` frames the wire form around
those retained bytes by hand rather than re-encoding the model. Protobuf allows
encodings that decode alike and re-encode differently, so round-tripping would
change the transaction id -- and with it what the node is being asked to do.

**Both transports must reach a vsock.** `tron-rpc-flow` and `tron-rpc-grpc` are
functorised over `Mirage_flow.S` and may not depend on anything that assumes a
host operating system or a TCP stack. `test/no_io_guard.sh` checks that
separately from the offline rule, and `validation/grpc-flow/` builds the gRPC
client over a flow made of two in-memory buffers to prove it. `tron-rpc-unix`
is the deliberate exception.

Network tests are opt-in; ordinary `dune runtest` is hermetic.

### Two hashes, and they are not interchangeable

- `txID` and the signing digest are **SHA-256** over the serialized `raw_data`.
- **Keccak-256** appears only in address derivation and ABI selectors.

Both produce 32 bytes, so swapping them fails silently. This is the most
dangerous mistake available in this repository. `docs/protocol-pin.md` is the
citation for every such rule; nothing in `lib/` may encode a rule that is not
traceable to a line there.

### zarith and GMP are unavoidable here, and they work

Unlike `ocaml-cardano`, this closure carries zarith and therefore GMP. It
enters three times and none is removable today: `web3-codec-basen` backs
Base58, `mirage-crypto-blockchain`'s `Secp256k1` is the bignum behind
public-key recovery, and `evm-abi` has `uint256`.

GMP cross-compiles against `ocaml-solo5` and the guest boots --
`validation/solo5-image/build.sh`, recorded in `docs/unikernel.md`. Four
obstacles had to be cleared and none of them was a GMP bug; the one worth
knowing is that the allocator is namespaced on purpose, and the fix is to use
the platform's own `<_solo5/overrides.h>` rather than to write a shim.

`Mirage_crypto_ec.P256k1.Primitive` exposes enough constant-time point
arithmetic to do recovery without the reference backend, which would remove
both a non-constant-time backend from the signing path and one of the three
bignum users. Worth doing on its own merits; no longer a blocker for anything.

## Build switch

This repository builds in the shared **`reuna-5.5`** switch and carries no local
`_opam`. That switch is the opam global default and is shared with nethsm's
confidential unikernel builds, so changes to it must be additive.
**Read `docs/switch.md` before running any opam command here.**

Regenerating the protobuf bindings uses a second, dedicated `web3-protoc`
switch. That separation is the point: `ocaml-protoc-plugin` pulls a 23-package
ppx cone and would recompile `ocamlformat` in `reuna-5.5`.

## Where this repo sits

`~/reuna/web3/ocaml-tron` — the `web3/` group (OCaml/Mirage web3 protocol libraries).

The tree was reorganised into effort groups; peer repositories are **no longer siblings**
at `../`. The full layout:

- `~/reuna/web3/` — OCaml/Mirage web3 protocol libraries
- `~/reuna/ports/` — Solo5 enclave core, language runtime ports and samples
- `~/reuna/ha/` — Reuna HA components
- `~/reuna/trust/` — Reuna trust components and the signed wire contracts
- `~/reuna/platform/` — RTP and the Kubernetes admission/runtime surface
- `~/reuna/research/` — reference checkouts, studied not built
- `~/reuna/vault/Reuna/` — the Obsidian design vault (Strategy, HLD, `SDD/`). Reachable from any group as `../vault/Reuna/` via a symlink.
- root also holds `infra/`, `release/`, `knowledge-bundle/`, `demo-app/`, `drivers/`, `attic/`

## Direct peers

| Repository | Path | Why |
| --- | --- | --- |
| `ocaml-web3-codec` | `../ocaml-web3-codec` | `web3-codec-protobuf` (the vendored ocaml-protoc-plugin runtime and `tools/gen-protobuf.sh`), `web3-codec-base58` (Base58Check addresses) |
| `ocaml-evm` | `../ocaml-evm` | `evm-abi` — the Contract ABI, reused unchanged for TVM calls. `lib/crypto/evm_crypto.ml` is also the template `tron-crypto` follows for the hardened-sign / reference-recover split |
| `ocaml-cardano` | `../ocaml-cardano` | The structural template: package split, `Mirage_flow.S` functor transport, `docs/switch.md`. `lib/rpc_flow/http.ml` is the source of our HTTP/1.1 parser |
| `ocaml-solana` | `../ocaml-solana` | `lib/transaction/intent.ml` is the template for our intent and policy layer; its CI is the template for ours |
| `ocaml-cometbft` | `../ocaml-cometbft` | Where the protobuf runtime was vendored first, before extraction into `ocaml-web3-codec` |
| `mirage-crypto` fork | `../../ports/ocaml/mirage-crypto` | `mirage-crypto-ec`'s `P256k1.Dsa` and `mirage-crypto-blockchain`'s `Secp256k1` / `Keccak256`, neither yet upstream |
| `digestif` fork | `../../ports/ocaml/digestif` | The 1.4.0 series. `KECCAK_256` alone is available in released digestif; the fork is not required by this repository |

In the `reuna-5.5` switch these are already pinned; see `docs/switch.md`.

## Nothing is reimplemented here

Base58Check, Keccak-256, secp256k1, the Contract ABI and the protobuf runtime
all exist elsewhere in the tree and are depended on, not copied. The one
deliberate fork is `lib/rpc_flow/http.ml`, which carries a provenance header
naming its source; when a third copy appears, extract it instead.

## Design docs

- `docs/protocol-pin.md` — the L0 pin: schema commit, node release, and every
  rule that is not in the `.proto` files
- `docs/switch.md` — build-switch discipline
- `docs/unikernel.md` — the Solo5 validation log
- `../vault/Reuna/SDD/` — component design documents
- `../vault/Reuna/Platryx HLD.md` — how the components fit together
- `../vault/Reuna/Attic/OCaml web3 state of the art status.md` — the launch
  gates (L0-L6) this repository is measured against, and the G6 scope

## Helper toolkits — `~/gilbahat`

Peer repositories used as tooling live **outside** `~/reuna`, in `~/gilbahat`. They are not
checked out here and are referenced by absolute path:

- `~/gilbahat/qemu` — patched QEMU (the tree the enclave/emulation scripts invoke)
- `~/gilbahat/qemurb`, `~/gilbahat/vhost-device`, `~/gilbahat/vsock-emulation-layer` — virtio/vsock plumbing for macOS-hosted guests
- `~/gilbahat/confidential-computing.sgx` — patched SGX emulation
- `~/gilbahat/ms-tpm-20-ref` — TPM simulator; `tpm2-tss`, `tpm2-tools`, `tpm2-pkcs11`, `tpm2-abrmd`, `tpm2-pytss` — mac-friendly TPM library builds
- `~/gilbahat/ocaml-tpm2` — OCaml ESAPI bindings (`OCAML_TPM2_DIR`)
- `~/gilbahat/elfuse` — ELF/FUSE tooling
- `~/gilbahat/alloy`, `~/gilbahat/opentelemetry-collector` — telemetry
- `~/gilbahat/aws-nitro-enclaves-cli` — Nitro tooling
- `~/gilbahat/karpenter`, `karpenter-provider-{aws,azure,oci}` — cluster autoscaling
- `~/gilbahat/ding-libs`, `~/gilbahat/libverto` — gssproxy build dependencies

Prefer the existing env-var knobs where a script defines one (`SGX_PATCHED_SOURCE`,
`VSOCK_EMULATION_LAYER`, `OCAML_TPM2_DIR`, `SIM`) rather than hardcoding a new path.
