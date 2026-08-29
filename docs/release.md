# Release

What has to be true before a version of this library is published, and what
currently is not. L6 in the vault document's gate table is "release and
assurance"; this is that gate, itemised.

## Where it stands

| Item | State |
| --- | --- |
| Public dependency closure | **Blocked.** See below |
| Clean-environment install | **Blocked** by the above |
| README, CHANGES, SECURITY | Done |
| Threat model | Done — `docs/threat-model.md` |
| Parser fuzzing | Targets exist and run in CI; **no sustained campaign** — `docs/fuzzing.md` |
| Independent review | **Not started.** Scope is written, in the threat model |
| Alpha release | Not made |
| Launch manifest | Not written |

Nothing here is close to publishable, and the first item is why.

## The blocker: a private dependency closure

G0 in the vault document is "no opam file points to a private repository", and
this repository points at six:

| Package | Repository | Why |
| --- | --- | --- |
| `mirage-crypto{,-ec,-rng,-blockchain}` | `reuna-labs/mirage-crypto` | `Secp256k1`, `Keccak256` and `P256k1.Dsa` are fork additions |
| `digestif` | `reuna-labs/digestif` | The 1.4.0 series; `KECCAK_256` alone is in released digestif, so this one may be droppable |
| `web3-codec-{basen,base58,protobuf}` | `reuna-labs/ocaml-web3-codec` | Base58Check and the protobuf runtime |
| `evm-types`, `evm-abi` | `reuna-labs/ocaml-evm` | The Contract ABI |
| `grpc`, `grpc-lwt` | `dialohq/ocaml-grpc` at `b629b55f` | Public, but unreleased: `grpc.0.2.0` caps `h2 < 0.13.0` |

Five of the six are Reuna's own and are a decision rather than an obstacle:
publish them, or vendor them with provenance. The sixth is upstream's to
release, and until it does, `tron-rpc-grpc` cannot install from a clean
environment even if everything else could.

**This cannot be worked around from inside this repository**, which is why it
is stated here rather than tracked as a task. `tron.opam.template` records the
pins so that the gap is visible in the package metadata rather than only in
prose.

## What a clean install would have to show

Once the closure is public, on a machine with nothing but opam and a compiler:

```sh
opam switch create tron-clean 5.2.1
opam install ./tron.opam
opam exec --switch tron-clean -- dune runtest
```

Currently this fails at the first step. Running it and recording the failure is
more useful than not running it, so it belongs in the release job when there is
one — a check that is expected to fail, and whose failure message names the
missing packages, is a live record of the gap. A check that is simply absent
becomes a gap nobody remembers.

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

`0.1.0~alpha1`, and it should stay an alpha until the closure is public and a
review has happened. The version is set once in `dune-project` and flows into
every generated `.opam`.

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
