(** secp256k1 signing for Tron.

    Tron signs the 32-byte SHA-256 digest of a serialized [raw_data] and puts
    the result on the wire as 65 bytes: [r] (32) then [s] (32) then [v] (1).

    {2 That last byte has two conventions, and both are on chain}

    The developer documentation says [v] is the raw recovery id, [0] or [1].
    TronWeb 6.5.0 emits [recid + 27], the same offset Ethereum's legacy
    signatures use -- see [ECKeySign] in its [utils/crypto].

    Neither source is wrong. A histogram of the signatures in mainnet block
    85634951 shows both, with [0x00]/[0x01] the majority and [0x1b]/[0x1c] a
    steady minority: java-tron normalises a [v] below 27 by adding 27, so it
    accepts either. The split follows client lineage -- java-tron-derived
    clients such as trident emit the recovery id, TronWeb emits the offset.

    The consequence is asymmetric, and this module treats it that way:

    - {!signature_of_bytes} accepts both and normalises to a recovery id. A
      decoder that rejected [0x1b] could not read a large fraction of mainnet
      history.
    - {!signature_to_bytes} has to pick one, and defaults to the recovery id --
      what the official java-tron SDK produces and what most of the chain
      carries. Pass [~v:`Eth_offset] to reproduce TronWeb byte-for-byte.

    What is {i not} accepted anywhere is EIP-155's [recid + 35 + 2 * chain_id].
    Tron has no chain id; see {!Tron_types.Block_ref} for what binds a
    transaction to a chain instead.

    {2 Hashing is the caller's job, and there are two hashes}

    Nothing here hashes a message. {!sign_digest} takes 32 bytes already
    computed, because the two hashes in this protocol are not interchangeable
    and the choice must be visible at the call site:

    - the transaction digest is {b SHA-256} of the serialized [raw_data];
    - {!address_of_public_key} uses {b Keccak-256}, and it is the only place
      Keccak appears in signing.

    Both produce 32 bytes, so a swap is not a type error and not a runtime
    failure. See [docs/protocol-pin.md].

    {2 Timing}

    Signing goes through [mirage-crypto-ec]'s fiat-crypto backend and is
    constant time. Recovery goes through [mirage-crypto-blockchain]'s reference
    backend, which is documented as {b not} constant time and is given only
    public data: a signature, a digest, and a recovery id, all of which are
    about to be broadcast. No private key reaches it.

    {2 Randomness}

    None is drawn. Nonces are RFC 6979 deterministic, which is what keeps
    [mirage-crypto-rng] initialisation off a unikernel's critical path. *)

type private_key
type public_key

type signature
(** [(r, s, recid)], with [s] low-S normalised. *)

type error =
  [ `Invalid_key of string
  | `Invalid_digest  (** Not 32 bytes. *)
  | `Invalid_signature
  | `Recovery_failed ]

val pp_error : Format.formatter -> [< error ] -> unit

(** {1 Keys} *)

val private_key_of_bytes : string -> (private_key, error) result
(** A 32-byte big-endian scalar. Rejects zero and anything at or above the curve
    order. *)

val public_key_of_bytes : string -> (public_key, error) result
(** SEC1, compressed (33 bytes) or uncompressed (65). *)

val public_key_to_bytes : ?compress:bool -> public_key -> string
(** Defaults to uncompressed, because that is the form {!address_of_public_key}
    hashes and the form java-tron exposes. *)

val public_key_of_private_key : private_key -> public_key

val address_of_public_key : public_key -> Tron_types.Address.t
(** [0x41] prefixed to the last 20 bytes of [Keccak-256] over the 64 bytes of
    the uncompressed public key with its [0x04] SEC1 prefix removed. *)

val address_of_private_key : private_key -> Tron_types.Address.t

(** {1 Signing} *)

val sign_digest : private_key -> string -> (signature, error) result
(** [sign_digest key digest] signs a 32-byte digest with an RFC 6979
    deterministic nonce, normalises [s] to the lower half of the curve order,
    and determines the recovery id by recovering with each candidate and
    comparing against the signer's own public key.

    Deriving the recovery id rather than computing it from the ephemeral point
    is what [ocaml-evm] does, and it is deliberate: the constant-time backend
    does not expose the nonce, and asking the non-constant-time one to sign in
    order to learn it would defeat the whole arrangement. *)

val verify : public_key -> string -> signature -> bool

val recover : msg:string -> signature -> (public_key, error) result
(** The public key that produced this signature over this digest. This is how a
    node authorises a transaction: it recovers each signer and looks the
    resulting address up in the named permission. *)

val address_of_signature :
  msg:string -> signature -> (Tron_types.Address.t, error) result
(** {!recover} composed with {!address_of_public_key} -- the question a
    permission check actually asks. *)

(** {1 Wire form} *)

type v_encoding =
  [ `Recovery_id
    (** [v] is [0] or [1]. java-tron, trident, most of the chain. *)
  | `Eth_offset  (** [v] is [27] or [28]. TronWeb. *) ]

val signature_to_bytes : ?v:v_encoding -> signature -> string
(** 65 bytes: [r ‖ s ‖ v]. [v] defaults to [`Recovery_id]. *)

val signature_of_bytes : string -> (signature, error) result
(** Accepts [v] in [\{0, 1, 27, 28\}] and normalises it to a recovery id.
    Rejects anything else, including EIP-155's chain-id-bearing form, which
    would otherwise be read as an out-of-range recovery id much later.

    Does {b not} reject a high [s]. Malleated signatures exist on chain and a
    decoder that refused them could not read history; {!is_canonical} is the
    separate question, and policy is where it belongs. *)

val v_byte : signature -> int
(** The recovery id, i.e. what {!signature_to_bytes} writes under
    [`Recovery_id]. Equal to {!recovery_id}; named separately because "the v
    byte" is how the wire format talks about it. *)

val is_canonical : signature -> bool
(** Whether [s] is in the lower half of the curve order. Everything
    {!sign_digest} produces is; something arriving from elsewhere may not be. *)

val r : signature -> string
val s : signature -> string
val recovery_id : signature -> int
