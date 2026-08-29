# Conformance fixtures

Golden values produced by two independent Tron implementations, offline, and
committed. Tests compare against these literals; they never compare
`ocaml-tron` against itself.

| Generator | Version | Language | Directory |
| --- | --- | --- | --- |
| TronWeb | 6.5.0 | JavaScript | `tronweb/` |
| trident | 1.0.0 | Java | `trident/` |

Two, not one, because a single oracle only tells you that two implementations
agree — yours and its. Where these two disagree, the disagreement is the
finding, and it is asserted in `test/test_conformance.ml` rather than resolved
by picking a favourite.

trident is the official java-tron client SDK, so it is the stronger evidence
about what a node will accept. TronWeb is what most of the ecosystem actually
uses.

## Everything is offline

Neither generator touches a network. Both SDKs normally build transactions by
asking a node; none of that is used. The transaction is assembled from fixed
inputs and only the pure pieces are called — protobuf serialization, the
transaction id, ABI encoding and signing. That is exactly the boundary
`ocaml-tron` implements, so a mismatch is a real disagreement about the wire
format rather than about who called the node.

The keys are the smallest secp256k1 scalars (1, 2, 3). They control nothing.
The reference block, expiration and timestamp are constants — nothing here may
read a clock, in the generators any more than in `lib/`.

## Regenerating

```sh
# TronWeb
npm ci --prefix conformance/tronweb
npm --prefix conformance/tronweb run generate

# trident (needs a JDK 17+ and gradle)
(cd conformance/trident && gradle run)

# Nothing should have changed.
git diff --exit-code conformance/fixtures/
```

CI runs both and diffs. Any drift fails the build.

## What the two agree on

For all five transaction shapes — TRX transfer, TRC-20 transfer, a transfer
under active permission 2, a two-signature transfer, and a transfer with a memo:

- `raw_data` serializes to **identical bytes**;
- the `txID` is **identical**;
- `r` and `s` of every signature are **identical**;
- hex and Base58Check addresses are **identical**.

## What they disagree on

### The signature's `v` byte

trident writes the raw recovery id, `0x00` or `0x01`. TronWeb writes it plus
27, `0x1b` or `0x1c` — the offset Ethereum's legacy signatures use.

Neither is wrong. java-tron normalises a `v` below 27 by adding 27, so both
verify. A histogram of the signatures in mainnet block 85634951 shows both, and
the split follows client lineage:

```
00: 28   01: 26   1b: 2   1c: 4        (first 60 transactions)
```

The developer documentation says `0`/`1`, which is trident's convention and the
on-chain majority, and does not mention TronWeb's.

`ocaml-tron` therefore:

- **decodes both**, normalising to a recovery id — a decoder that refused
  `0x1b` could not read a large fraction of mainnet history;
- **writes the recovery id by default**, matching the official SDK and the
  majority of the chain, with `~v:`Eth_offset` available to reproduce TronWeb
  byte-for-byte.

See `Tron_crypto.v_encoding` and `docs/protocol-pin.md`.

### The public key's SEC1 prefix

TronWeb reports the 65-byte uncompressed encoding including its leading `0x04`.
trident reports the 64 bytes after it. Same key, different spelling.
`ocaml-tron` emits the 65-byte form; the test asserts the relationship rather
than letting it be rediscovered.

## What is not covered here

Live-network behaviour. These fixtures say what the bytes should be; they say
nothing about whether a node accepts them, how fees are actually charged, or
what happens across a reorganisation. That evidence has to come from a testnet
run and be archived separately — see `SECURITY.md`.
