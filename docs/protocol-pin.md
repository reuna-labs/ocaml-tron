# Specification pin (L0)

Every wire format this library implements is pinned to an exact upstream
revision here. Nothing in `lib/` may encode a rule that is not traceable to a
line in this document.

Tron has two sources of truth and they are not the same thing. The **schema**
defines the bytes that get signed. The **node** defines the HTTP API and its
JSON shape, which is not canonical protobuf JSON. Both are pinned.

## Schema

| | |
| --- | --- |
| Source | `tronprotocol/protocol` |
| Commit | `8432beca98c52ba04c82aea0b48ae9f9f882c82a` (2026-07-17) |
| Local copy | `proto/` |

| File | sha256 |
| --- | --- |
| `core/Tron.proto` | `6982f5177850db3c5048005f8f222827d925052fbb8c93b0d041b20ed774aed3` |
| `core/Discover.proto` | `87fd67a605956f8308fa88b3d97101d03ad55616b15a55b5f9253fe279205f78` |
| `core/contract/common.proto` | `cc3dfa352f15761129f52a082ef49f3635b5f19fac62c114f4f5cfbb29a86d88` |
| `core/contract/account_contract.proto` | `8b185d719f250052768a341c00bb15c6ba280bbac73b99d9af5c218b960eecfe` |
| `core/contract/asset_issue_contract.proto` | `3df981582ae1f5852b7c22b5ae99363c2b1be6427ee7c83df211cbde3b38bcb3` |
| `core/contract/balance_contract.proto` | `e2275249dbe115d8e90d48a4b11c54ba2027cb635e9bedbf7aadfaa328db4cc4` |
| `core/contract/smart_contract.proto` | `a838490e394db56e4945f1c327201aebdccd1762b5ec8f5a9cac7eb3d4e84f8b` |
| `google/protobuf/any.proto` | `8e56f61e3078e9232d39ce1b1bab28613783af8191f93a910c3617933f87a179` |
| `api/api.proto` | `5dec5d12ee2e88fda559523e074e454ebda562415b908557ffcb422523224b81` |
| `api/zksnark.proto` | `f3be595eb40aff190b3c1d1b79e9ee07cb1fbbc668fca8b69cb566d0a75e819e` |
| `core/contract/exchange_contract.proto` | `d0ce0e6e5d97cfe8ef19c1b47e32e79413feb8a5408bda0258e592947035e032` |
| `core/contract/market_contract.proto` | `bac327d448dff9681f52446b93ff95dad66a6f2b35aecfc8e4565cc432244cc4` |
| `core/contract/proposal_contract.proto` | `ccdbebd95b9874ba9a14f6554649723d92e7d71e337312bae90c80f57372e0c4` |
| `core/contract/shield_contract.proto` | `cdd6be885d2b2781735bb60117ecefc912ce2cc7bbc693a482452bee36ce2443` |
| `core/contract/storage_contract.proto` | `5e27e9094e314115d1d0001ccadef3c357ac012b5b399eda9f619cd9e4e5b9ff` |
| `core/contract/witness_contract.proto` | `44171f6055460f3a86aabbcce554b1aa13d2db7e9b7d049d707408e9f7e30467` |
| `core/contract/vote_asset_contract.proto` | `98da89b3b1f21ce71e640a964414522b190667d05cf609be6bb455fae96a35fc` |

`core/Discover.proto` carries the p2p discovery messages, which this library
does not implement. It is vendored, and generated, because `core/Tron.proto`
does not merely import it -- `Transaction.raw` reaches into it for
`Endpoint`, so omitting it from the generation list produces bindings that do
not compile.

`google/protobuf/any.proto` is vendored rather than taken from `protoc`'s
builtin include path, so that the generated output does not silently depend on
which `protoc` happened to be installed. Generated with `libprotoc 36.0`.

`api/api.proto` defines the `Wallet` service and is what `tron-rpc-grpc` is
generated from. The contract protos beyond the launch set --- exchange, market,
proposal, shield, storage, witness, vote-asset --- are vendored because
`api/api.proto` imports them, not because this library models them. Their
messages still decode to {!Tron_transaction.Contract.Unknown} and remain
unapprovable.

To refresh:

```sh
PIN=<new commit>
for f in core/Tron.proto core/Discover.proto core/contract/common.proto \
         core/contract/account_contract.proto \
         core/contract/asset_issue_contract.proto \
         core/contract/balance_contract.proto \
         core/contract/smart_contract.proto; do
  curl -sfo "proto/$f" \
    "https://raw.githubusercontent.com/tronprotocol/protocol/$PIN/$f"
done
```

Then regenerate (see below), update the table above, and re-run the conformance
fixtures. A schema change that does not move a fixture is either cosmetic or a
gap in our coverage, and which one it is must be recorded here.

## Generating the bindings

The runtime and the `protoc` invocation are shared, and live in
`ocaml-web3-codec` as `web3-codec-protobuf`. The generated sources are
committed here, so an ordinary build of this repository needs neither `protoc`
nor `ocaml-protoc-plugin`.

```sh
PATH="$HOME/.opam/web3-protoc/bin:$PATH" \
  ../ocaml-web3-codec/tools/gen-protobuf.sh -I ./proto -o ./lib/proto/gen \
    core/Tron.proto \
    core/Discover.proto \
    core/contract/common.proto \
    core/contract/account_contract.proto \
    core/contract/asset_issue_contract.proto \
    core/contract/balance_contract.proto \
    core/contract/smart_contract.proto \
    core/contract/exchange_contract.proto \
    core/contract/market_contract.proto \
    core/contract/proposal_contract.proto \
    core/contract/shield_contract.proto \
    core/contract/storage_contract.proto \
    core/contract/witness_contract.proto \
    core/contract/vote_asset_contract.proto \
    api/api.proto \
    api/zksnark.proto \
    -- google/protobuf/any.proto
```

`web3-protoc` is a dedicated tooling switch holding `ocaml-protoc-plugin`
6.2.0. It is deliberately **not** `reuna-5.5`: installing the plugin there
would pull a 23-package ppx cone and recompile `ocamlformat`, and `reuna-5.5`
is shared with nethsm's confidential unikernel builds. See `docs/switch.md`.

## Node

| | |
| --- | --- |
| Source | `tronprotocol/java-tron` |
| Release | `GreatVoyage-v4.8.2.1` (2026-07-31) |

The HTTP API shape is the node's, not the schema's. Two consequences that the
JSON decoders in `lib/rpc/` depend on:

- `bytes` fields are **hex**, not base64. This is not canonical protobuf JSON
  and generated JSON codecs must not be used for it.
- `visible=true` renders addresses as Base58Check instead of hex. The flag is
  set per request and changes the shape of the response.

The gRPC surface is the same node's, on port 50051 by default rather than
8090. It is not a second protocol so much as a second encoding: protobuf in,
protobuf out, with none of the hex-versus-base64 or `visible` questions the
JSON shape raises. `test/test_grpc_parity.ml` asserts that the two decode to
the same values.

Two places the surfaces are not shaped alike, both handled in
`lib/rpc_grpc/wallet_grpc.mli`: HTTP's `getnowblock` is gRPC's `GetNowBlock2`
returning a `BlockExtention`, and gRPC's `BroadcastTransaction` takes a
`Transaction` message where HTTP takes hex.

`/wallet/estimateenergy` requires `vm.estimateEnergy` **and**
`vm.supportConstant` in the node configuration. A node with them off returns an
error rather than an estimate, and the client falls back to
`/wallet/triggerconstantcontract`.

## Networks

| Network | Full node | Role |
| --- | --- | --- |
| Nile | `https://nile.trongrid.io` | Launch target; the only network the smoke workflow touches |
| Shasta | `https://api.shasta.trongrid.io` | Secondary testnet |
| Mainnet | `https://api.trongrid.io` | Out of scope for the alpha; see `SECURITY.md` |

Chain parameters (`getEnergyFee`, `getTransactionFee`, and the rest of
`/wallet/getchainparameters`) are governance-controlled and change without a
release. They are read from the node, never hardcoded.

## Rules that are not in the schema

The `.proto` files give field names and types but not the rules below. Each is
read out of java-tron or the official documentation, with the citation, because
each is a plausible-but-wrong guess away from a rejected transaction or a lost
key.

### Address

`0x41 ‖ keccak256(uncompressed_pubkey[1:])[12:]` -- 21 bytes. The uncompressed
SEC1 encoding is 65 bytes with a `0x04` prefix; the prefix is dropped and the
remaining 64 bytes are hashed.

The user-facing form is Base58Check over those 21 bytes: `SHA-256` twice, first
4 bytes of the second digest appended, then Base58. Every such address is 34
characters and starts with `T`, because `0x41` maps there.

The 21-byte form is the type in this library and the Base58Check form is a
rendering. Confusing the two is named as a Tron risk in
`vault/Reuna/Attic/OCaml web3 state of the art status.md`.

### Transaction id and signing digest

`txID = SHA-256(protobuf_serialize(raw_data))`.

**SHA-256, not Keccak.** Keccak-256 appears in this protocol only in address
derivation and in ABI function selectors. Swapping the two is the single most
dangerous error available in this repository, and it fails silently: both
produce 32 bytes.

The signature covers that same digest. No domain-separation prefix, no
`\x19TRON Signed Message` wrapper -- that prefix belongs to `sign_message`,
which is a different operation and is not implemented here.

### Signature

65 bytes on the wire: `r` (32) ‖ `s` (32) ‖ `v` (1).

`v` is the raw recovery id, `0` or `1`. It is **not** `recid + 27` (Ethereum's
legacy `eth_sign`) and carries no EIP-155 chain-id term. `s` is low-S
normalised.

### Reference block

- `ref_block_bytes` -- byte interval `[6, 8)` of the reference block's *number*,
  big-endian.
- `ref_block_hash` -- byte interval `[8, 16)` of the reference block's *ID*.

The number and the ID are different values and the intervals are different.

### Permissions

`Permission_id` on `Transaction.Contract`: `0` owner (the default), `1` witness
(super representatives only, exactly one key, cannot authorise ordinary
contracts), `2`-`9` active.

`Permission.operations` is a **32-byte little-endian bitmap** over
`ContractType`. For contract type `n` the bit is at byte `n / 8`, position
`n & 7`.

Signatures accumulate on one transaction. The node recovers each signer,
looks it up in the named permission's `keys`, and sums the weights against
`threshold`. A transaction carrying two or more signatures pays an extra 1 TRX.

`AccountPermissionUpdateContract` replaces all three slots at once: updating one
requires resubmitting the other two unchanged, or they are cleared.

### Contract parameter

`Transaction.Contract.parameter` is a `google.protobuf.Any` -- a `type_url` and
opaque `value` bytes. The generated code cannot narrow it, so unpacking is where
hand-written validation goes. A `type_url` this library does not recognise must
reach the intent layer as opaque and must never be approved by a policy.

### TVM ABI

Standard Ethereum head/tail encoding with a 4-byte Keccak-256 selector, reused
from `evm-abi`.

The `address` type is the **20-byte** form left-padded to 32 bytes: the `0x41`
prefix is stripped. Tron also accepts a variant with `0x41` at byte 11, since
the EVM reads only the last 20 bytes of the word, but TronWeb and Trident emit
the canonical form and so does this library. Writing a 21-byte address into an
ABI word shifts every byte and is a silent fund-loss bug.

### Resources

Bandwidth is consumed equal to the transaction's on-chain byte count. Each
account has a free 600-bandwidth daily quota; beyond it, staked bandwidth is
used, and beyond that TRX is burned at the rate in `getTransactionFee`.

Energy has no free quota. Each TVM instruction has a fixed cost.
`fee_limit`, in sun, caps the TRX burned when staked energy is insufficient:

```
fee_limit_sun = energy_required * getEnergyFee
```

`fee_limit` is absent from `raw_data` unless set, and a `TriggerSmartContract`
submitted without one will fail once staked energy runs out. The intent layer
therefore reports `fee_limit` as a first-class field rather than an optional
detail.
