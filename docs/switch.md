# The build switch

This repository builds in the shared opam switch **`reuna-5.5`**. It does not
carry a local `_opam`. `ocaml-cardano/docs/switch.md` is where that switch was
first written down; this file records what `ocaml-tron` adds to it, and the one
place where this repository needs a second switch.

## What it is

```
$ opam switch show
reuna-5.5
```

`ocaml-base-compiler.5.5.0`, holding the coordinated Reuna fork set. Every fork
is pinned to its `toolchain/ocaml-5.5` branch:

| Package | Pinned to |
| --- | --- |
| `digestif.dev` | `reuna-labs/digestif#toolchain/ocaml-5.5` |
| `mirage-crypto{,-ec,-rng,-pk,-kw,-kerberos*}` | `reuna-labs/mirage-crypto#toolchain/ocaml-5.5` |
| `mirage.4.11.2`, `mirage-runtime.4.11.2` | `reuna-labs/mirage#toolchain/ocaml-5.5` |
| `ocaml-solo5.1.3.4` | `reuna-labs/ocaml-solo5#toolchain/ocaml-5.5` |
| `solo5.0.12.0` | `reuna-labs/solo5#toolchain/ocaml-5.5` |
| `mirage-vsock-solo5.0.1.0` | `reuna-labs/mirage-vsock-solo5#toolchain/ocaml-5.5` |
| `cohttp*`, `conduit*`, `http`, `tls*`, `x509`, `gmp.dev` | Nitrokey nethsm forks |
| `web3-codec-*` | `~/reuna/web3/ocaml-web3-codec` |

## Why 5.5.0

Not a preference. `ocaml-solo5` 1.3.4 declares `"ocaml" {>= "5.5" & < "5.6"}`,
so it is the only compiler that can cross-compile a unikernel against these
forks.

## The hazard

`reuna-5.5` is the opam **global default**. An `opam install` run from this
directory without an explicit `--switch` mutates the switch that builds
nethsm's confidential unikernels.

So, in this repository:

1. **Name the switch explicitly, always** — `--switch reuna-5.5`, or export
   `OPAMSWITCH=reuna-5.5`.
2. **Additive only.** Before installing anything, look:

   ```sh
   opam install --switch reuna-5.5 --deps-only --with-test --show-actions .
   ```

   The plan must contain **only `install` lines**. An upgrade, downgrade,
   removal *or recompile* of an existing root means stop: that root has
   consumers elsewhere in the tree.
3. **Never `opam upgrade`** here. Ever.

## What this repository needs

Already present: `digestif.dev` (the fork), `mirage-crypto{,-ec,-rng}.dev`,
`zarith`, `base64`, `yojson`, `uri`, `lwt` 6.1.2, `cstruct`, `mirage-flow`,
`mirage-flow-unix`, `fmt`, `alcotest`, `qcheck-core`, `qcheck-alcotest`,
`ocamlformat`, `mirage`, `solo5`, `ocaml-solo5`.

Added by this repository, all new installs rather than version moves:

| Package | Where from | Why |
| --- | --- | --- |
| `ptime` | opam | The protobuf runtime's other dependency, alongside `base64` |
| `web3-codec-protobuf` | `../ocaml-web3-codec` | The vendored `ocaml-protoc-plugin` runtime |
| `web3-codec-basen`, `web3-codec-base58` | `../ocaml-web3-codec` | Base58Check addresses |
| `mirage-crypto-blockchain` | the same already-pinned fork | `Secp256k1` recovery and `Keccak256`. `mirage-crypto-blockchain-core` is already installed; this is its zarith-carrying sibling |
| `evm-types`, `evm-abi` | `../ocaml-evm` | The Contract ABI, for TVM calls |
| `h2`, `h2-lwt`, `gluten-lwt`, `faraday`, `hpack`, `httpun-types`, `psq` | opam | HTTP/2, for gRPC |
| `grpc`, `grpc-lwt` | the `dialohq/ocaml-grpc` fork already pinned here | Released `grpc` caps `h2 < 0.13.0`; the Mirage-capable `h2` is `0.13.0`, and the fix is unreleased. `ocaml-cometbft` vetted commit `b629b55f` for the same reason |
| `ppx_deriving`, `ppxlib`, `ocaml-compiler-libs`, `ppx_derivers` | opam | Build-time only, pulled in by `grpc` |

Deliberately **not** `h2-mirage`. It would functorise the gRPC client over a
flow for us, and pull 48 packages doing it -- `conduit-mirage`, `tcpip`,
`tls-mirage`, `x509`, `dns-client`, `vchan`, `xenstore` -- because it assumes a
network stack. The confidential Solo5 targets have a vsock instead. What h2
needs from a transport is `Gluten_lwt.IO`, four functions, so
`lib/rpc_grpc/io_of_flow.ml` implements those directly.

`mirage-crypto-blockchain` pulls no new pin: it is built from the
`reuna-labs/mirage-crypto` fork already pinned in this switch, and its only
dependency not already present is `zarith`, which is.

## The second switch: `web3-protoc`

Regenerating the protobuf bindings needs `ocaml-protoc-plugin` and a `protoc`.
Installing the plugin into `reuna-5.5` is **not** additive — the plan is:

```
=== recompile 4 packages
  ↻ ocamlformat  ↻ ocamlformat-lib  ↻ uucp  ↻ uuseg
=== install 23 packages
  ∗ conf-protoc  ∗ omd  ∗ ppx_expect  ∗ ppx_inline_test  ∗ ppxlib  ...
```

Four recompiled roots and a 23-package ppx cone, in the switch nethsm's
confidential unikernels are built from. That is exactly the cone the vendored
runtime exists to avoid, so it goes in its own switch instead:

```sh
opam switch create web3-protoc ocaml-base-compiler.5.5.0 --no-switch
opam install --switch web3-protoc ocaml-protoc-plugin.6.2.0
```

Generated sources are committed, so this switch is needed only when the schema
pin moves. An ordinary build, and CI, never touch it. The regeneration command
is in `docs/protocol-pin.md`.
