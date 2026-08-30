# Release

What has to be true before a version of this library is published, and what
currently is not. L6 in the vault document's gate table is "release and
assurance"; this is that gate, itemised.

## Where it stands

| Item | State |
| --- | --- |
| Public source dependency closure | **Done.** All immutable tags are public |
| Reuna opam overlay | **In validation.** No upstream acceptance required |
| Clean-environment install | **In progress** against the overlay |
| README, CHANGES, SECURITY | Done |
| Threat model | Done — `docs/threat-model.md` |
| Parser fuzzing | Targets exist and run in CI; **no sustained campaign** — `docs/fuzzing.md` |
| Independent review | **Not started.** Scope is written, in the threat model |
| Alpha release | Public; alpha2 includes verified TLS and 97 tests |
| Launch manifest | Not written |

This is publishable as explicitly unaudited alpha software once the overlay's
clean install passes. It is not production-ready.

## Dependency strategy: no upstream gate

G0 in the vault document is "no opam file points to a private repository".
Every source and tag in the closure is now public:

| Package | Repository | Why |
| --- | --- | --- |
| `mirage-crypto{,-ec,-rng,-blockchain}` | `reuna-labs/mirage-crypto` | `Secp256k1`, `Keccak256` and `P256k1.Dsa` are fork additions |
| `digestif` | `reuna-labs/digestif` | The 1.4.0 series; `KECCAK_256` alone is in released digestif, so this one may be droppable |
| `web3-codec-{basen,base58,protobuf}` | `reuna-labs/ocaml-web3-codec` | Base58Check and the protobuf runtime |
| `evm-types`, `evm-abi` | `reuna-labs/ocaml-evm` | The Contract ABI |
| `grpc`, `grpc-lwt` | `reuna-labs/ocaml-grpc` `v0.2.1-alpha1` | Carries the h2 0.13 compatibility needed by `tron-rpc-grpc` |

The first alpha train is published through
`reuna-labs/opam-repository`. That repository imports the immutable archives,
records SHA-256 and SHA-512 checksums, and removes development-only
`pin-depends`. Upstream releases and central-opam acceptance can happen later
as small independent changes; neither blocks Reuna's alpha publication.

## What a clean install would have to show

On a machine with nothing but opam and a compiler:

```sh
opam switch create tron-clean 5.2.1
opam repository add --switch tron-clean reuna https://github.com/reuna-labs/opam-repository.git
opam install --switch tron-clean tron-rpc-unix
```

The release gate records this clean install separately from repository lint and
the source tree's full 97-test matrix.

## Fuzzing

`docs/fuzzing.md` has the targets and how to run them. For a release the bar is
a **sustained campaign** — hours of `afl-fuzz` per target with no new crashes —
not the bounded randomised runs CI does. That needs an AFL-instrumented switch,
which `reuna-5.5` must not become: it is shared with nethsm's confidential
unikernel builds.

## Independent review

Scope is in `docs/threat-model.md`, ordered by what a mistake would cost. The
two things a reviewer should be handed alongside the code:

1. `docs/protocol-pin.md`, because most of what could be wrong here is a
   protocol rule transcribed incorrectly, and that document is where every such
   rule is supposed to be traceable to.
2. `conformance/README.md`, because the strongest existing evidence is that two
   independent implementations produce the same bytes, and a reviewer should
   know exactly what that does and does not cover.

## Versioning

`0.1.0~alpha2`, and it should stay an alpha until independent review and the
sustained fuzz campaign have happened. The version is set once in
`dune-project` and flows into every generated `.opam`.

`docs/protocol-pin.md` pins the schema commit and node release separately from
the library version, deliberately: a schema bump is a compatibility event that
deserves its own release note, and folding it into a patch version would hide
it.

## Before tagging

- [ ] `dune build @all` and `dune runtest` clean on the CI matrix
- [ ] `./test/no_io_guard.sh` clean
- [ ] Both conformance generators reproduce the committed fixtures
- [ ] `validation/solo5/unikernel.exe` and `validation/grpc-flow/` link
- [ ] `validation/solo5-image/build.sh` produces a running guest
- [ ] Live testnet evidence archived, with the genesis hash recorded
- [ ] `CHANGES.md` describes the release, including anything found
- [ ] `docs/protocol-pin.md` matches the vendored schema's checksums
- [ ] Fuzz campaign run, duration and result recorded
- [ ] Independent review complete, or a written risk acceptance in its place
