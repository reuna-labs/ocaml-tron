# Running as a unikernel

Two claims, both checked. The first runs on every commit; the second needs the
Solo5 toolchain and is run by hand.

## Structural: the offline closure contains no I/O

`validation/solo5/unikernel.exe` links `tron-types`, `tron-crypto`,
`tron-proto`, `tron-transaction` and `tron-rpc`, and **no transport**.
`validation/grpc-flow/` does the same for gRPC over a flow made of two
in-memory buffers.

```sh
OPAMSWITCH=reuna-5.5 opam exec -- ./test/no_io_guard.sh
```

If any offline package acquires a Unix, Lwt or socket dependency -- directly or
through something it depends on -- these stop linking. CI runs them.

## Actual: a Solo5 guest, booted

```sh
OPAMSWITCH=reuna-5.5 ./validation/solo5-image/build.sh
```

Cross-compiles GMP and zarith, builds an `sptmac` image, and runs it. The guest
derives an address, builds a transaction, signs it, recovers the signer,
derives the intent from the signed bytes, runs a policy, and ABI-encodes a
TRC-20 call.

Recorded from a run on 2026-08-24, aarch64 macOS host:

```
==> size
    18229632 bytes                     (unstripped, with debug info)
==> ABI
    { "type": "solo5.abi", "target": "sptmac", ... }
==> gmp is really in there
    270 gmp symbols linked
==> run
Solo5: Memory map: 16777728 MB addressable:
Solo5:       text @ (0x100000100000 - 0x1000003f7fff)
Solo5:       heap >= 0x10000066c000 < stack < 0x100020000000
tron: guest starting

address     TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC
            matches the TronWeb fixture
raw_data    133 bytes
txID        64da11025d168eda5ebe29c6ed5cb3755c9a5cd7e8584b06b5e8f973839a4754
signature   65cbc9d592845f943c5fb93aca0d919a92406473eba63bcd645b148160f40aa2
            02a8393c260912b4570b6954b10e7009a2ab721c9e884da9426141516469fdd801
recovered   matches the signing key
intent      send 1 TRX from TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC
            to TDvSsdrNM5eeXNL3czpa6AxLDHZA9nwe9K
policy      accepted
trc20 data  a9059cbb00000000...
            selector matches

OK: the offline path runs in a Solo5 guest, GMP and all
Solo5: solo5_exit(0) called
```

The address is checked against the TronWeb conformance fixture inside the
guest, not afterwards. If Base58, Keccak-256 or secp256k1 behaved differently
on this target, the guest would say so and exit non-zero.

## Why this was the hard part

`ocaml-cardano` has no zarith and therefore no GMP: Cardano is Ed25519-only, so
its whole signing closure needs no bignum. Tron has no such option. zarith
enters three times:

- `web3-codec-basen` backs Base58, and Base58Check is how a Tron address is
  written;
- `mirage-crypto-blockchain`'s `Secp256k1` is the bignum implementation behind
  public-key recovery, which is how the `v` byte is determined;
- `evm-abi`'s `uint256`, for TRC-20 amounts.

So a Tron guest needs GMP cross-compiled against `ocaml-solo5`. An earlier
version of this document called that "an open question, not a formality". It
turned out to be four obstacles, none of them a GMP bug:

### 1. The Solo5 cc wrapper supplies no libc

`aarch64-solo5-none-static-cc` targets a freestanding environment; ocaml-solo5
ships the libc separately, under `lib/ocaml-solo5/`. GMP's configure runs link
probes and needs both the headers and the archives, so `build.sh` wraps the
wrapper.

### 2. nolibc and openlibm reference each other

nolibc's `vfprintf` wants `__signbit`, `__isfinite` and `frexp` from openlibm.
A static linker only looks forward, so nolibc appears twice on the line.

### 3. The allocator is namespaced, and the fix is the platform's own

This is the one worth reading `lib/ocaml-solo5/include/_solo5/overrides.h`
for. nolibc's dlmalloc is exported as `ocaml_solo5_malloc` and friends, and
ocaml-solo5 force-includes that header into every C compile through its
`ocaml-gcc` wrapper, so a unikernel never exports `malloc` as a strong global
symbol. The reason is sgx-specific and sharp: the Intel SDK defines those six
weakly, so a guest defining any of them strongly captures the allocator for the
whole enclave -- including the SDK's own allocations, which happen before Solo5
has handed the guest its heap and would fail the ECALL outright.

GMP builds through the *plain* Solo5 wrapper, which does not force-include it,
so `build.sh` does. GMP then calls `ocaml_solo5_malloc` like every other C file
in the guest.

An earlier attempt here wrote a shim mapping `malloc` onto `ocaml_solo5_malloc`
instead. It was the wrong answer to a solved problem, and it did not even work:
GCC folds `void *malloc(n) { return ocaml_solo5_malloc(n); }` into its callee
and emits the callee's symbol, which shows up as a multiple definition of
`ocaml_solo5_malloc` together with an undefined reference to `malloc` -- two
symptoms of one optimisation. Using the platform's mechanism removes the shim
and the flags it needed.

### 4. nolibc's ctype is partial, and it has no vsprintf

`islower`, `isascii`, `isxdigit`, `iscntrl`, `isblank`, `isgraph`, `ispunct`,
`toupper` and `vsprintf` are missing or declared-not-defined, and GCC 14 makes
an implicit declaration an error. GMP's printf and scanf modules use them.
zarith calls neither module, but GMP builds both unconditionally and has no
`--disable-printf`, so `nolibc_gaps.c` supplies them. They are real
implementations, not stubs.

Separately, GMP 6.3.0's own configure probes use pre-C23 function semantics
that GCC 14 rejects, so the build runs at `-std=gnu17`. Nothing to do with
Solo5.

### zarith

Not a dune package, and its `configure` detects the host GMP and the host
stdlib regardless of `OCAMLFIND_TOOLCHAIN`. `build.sh` bypasses it and writes a
dune stanza over the four modules and `caml_z.c`.

`ptime` gets the same treatment, minus its clock sub-library -- which reads a
clock, and is exactly what this guest must not link. Nothing needs it: the
protobuf runtime uses `Ptime` only to render `google.protobuf.Timestamp` in
JSON.

## What this does not prove

- **Only `sptmac`.** The confidential targets -- `sgx`, `nitro`, `cca`, `snp`,
  `tdx` -- are not built here. They forbid `NET_BASIC`, which is why the
  transports are functorised over `Mirage_flow.S`, but that reasoning is
  untested on those targets.
- **No network.** The guest runs the offline path. Reaching a node from inside
  a guest means `mirage-vsock-solo5` and `Tron_rpc_flow.Make` over its flow;
  the structural proof says the types line up, and nobody has run it.
- **Not reproducible bit-for-bit.** The image embeds paths from a temporary
  workspace.
- **Not in CI.** The Solo5 toolchain is not on the GitHub-hosted runners, and
  `sptmac` is a Reuna fork target that exists nowhere public. This is a
  by-hand check, and its output belongs in this file when it is re-run.

## A way to make this smaller

`Mirage_crypto_ec.P256k1.Primitive` exposes constant-time point arithmetic --
`point_of_octets` decompresses from a compressed SEC1 encoding, `scalar_inv`,
`scalar_mult`, `scalar_mult_base` and `point_add` are all there. That is enough
to recover a public key without `mirage-crypto-blockchain`, which would remove
both a non-constant-time backend from the signing path and one of the three
reasons this library needs a bignum.

Base58 over a 25-byte payload is the second: it needs repeated division of a
200-bit number, which fits in four 64-bit limbs and does not need arbitrary
precision.

That would leave `evm-abi`'s `uint256`. Removing all three would let a Tron
guest drop GMP entirely and build as simply as a Cardano one. None of it is
required now that GMP works, and the first is worth doing on its own merits --
see `docs/threat-model.md`.
