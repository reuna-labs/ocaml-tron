(** A transaction: the signed part, plus signatures.

    {2 The node never builds these}

    java-tron offers [/wallet/createtransaction], which assembles a transaction
    server-side and hands it back for signing. This library does not use it on
    the product path, and neither should a caller. A transaction built somewhere
    else is a transaction whose bytes you did not choose; signing it means
    trusting the node about the destination and the amount. It is useful as a
    differential oracle in tests and nowhere else.

    {2 External signers}

    {!signing_bytes} and {!add_signature} exist so that the private key can live
    somewhere this library does not run -- an enclave, an HSM, a threshold
    group. The signer is handed a digest and returns 65 bytes; it never sees a
    key belonging to this process. {!Intent.derive} is what makes that safe: the
    signer can reconstruct what it is approving from the same bytes it is about
    to sign. *)

type t

type error =
  [ `Not_signed
  | `Too_many_signatures  (** Beyond what any permission's key list can hold. *)
  | `Signature of Tron_crypto.error ]

val pp_error : Format.formatter -> [< error ] -> unit

val of_raw_data : Raw_data.t -> t
(** Unsigned. *)

val raw_data : t -> Raw_data.t
val signatures : t -> Tron_crypto.signature list

val tx_id : t -> Tron_types.Tx_id.t
(** Independent of the signatures: they are not covered by it. Two transactions
    differing only in who signed them have the same id, which is what makes
    accumulating signatures for a multisig permission possible at all. *)

val signing_bytes : t -> string
(** The 32 bytes to sign: {!tx_id}. Named for what it is used for, because "sign
    the transaction id" reads like a category error until you know that Tron's
    id is the digest of the signed structure. *)

val sign : t -> Tron_crypto.private_key -> (t, error) result
(** Appends a signature. For a local key; prefer {!signing_bytes} and
    {!add_signature} where the key is held elsewhere. *)

val add_signature : t -> Tron_crypto.signature -> (t, error) result
(** Appends a signature produced elsewhere over {!signing_bytes}.

    Deliberately does {b not} verify it. Which key is allowed to sign is a
    property of the account's permissions, which live on chain and are not
    available here; a check against "some key" would be theatre. Use
    {!recover_signers} and compare against a {!Permission} the caller fetched.
*)

val recover_signers :
  t -> ((Tron_types.Address.t, Tron_crypto.error) result list, error) result
(** The address behind each signature, in order. One [Error] does not spoil the
    others: a transaction can carry a signature this library cannot recover
    alongside ones it can, and a permission check needs to see exactly that. *)

(** {1 Wire form} *)

val to_proto : t -> Tron_proto.Tron.Protocol.Transaction.t
(** The model, {b for inspection only}.

    Re-encoding this is not the same as {!to_bytes}: a [raw_data] that arrived
    with non-canonical framing decodes into a model that re-encodes to different
    bytes, and therefore to a different transaction id than the one that was
    signed. Anything going onto a wire must use {!to_bytes}, which carries the
    retained bytes through unchanged. *)

val to_bytes : ?v:Tron_crypto.v_encoding -> t -> string
(** The full serialized transaction, signatures included.

    The [raw_data] on the wire is byte-for-byte the [raw_data] that was signed,
    including when it arrived with framing this library would not have chosen.
    Round-tripping it through the generated encoder instead would change the
    transaction id, and with it what the node is being asked to execute. *)

val to_broadcast_hex : ?v:Tron_crypto.v_encoding -> t -> string
(** {!to_bytes} in hex -- the body of [/wallet/broadcasthex].

    This is the submission path. [/wallet/broadcasttransaction] takes the JSON
    form instead, which means re-serializing through the node's JSON shape and
    trusting it to reproduce the bytes that were signed. Sending the bytes
    themselves removes that step. *)

type decode_error = [ Raw_data.error | error ]
(** Closed, like every error type in this library: a caller matching on it is
    told by the compiler when a new failure becomes possible. *)

val pp_decode_error : Format.formatter -> [< decode_error ] -> unit
val of_bytes : string -> (t, decode_error) result
val of_broadcast_hex : string -> (t, [ decode_error | `Invalid_format ]) result
