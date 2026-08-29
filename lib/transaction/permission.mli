(** Account permissions: who may authorise what.

    Tron accounts have three permission slots. [owner] (id [0]) can do anything,
    including rewriting the permissions themselves. [witness] (id [1]) exists
    only for super representatives, holds exactly one key, and cannot authorise
    ordinary contracts. Up to eight [active] permissions (ids [2]-[9]) delegate
    a restricted set of contract types.

    A transaction names one of them in its [Permission_id]. The node recovers
    each signature, finds the signer in that permission's key list, sums the
    weights, and requires the total to reach [threshold].

    {2 This module does not decide anything}

    A permission lives on chain. Nothing here can fetch one, and nothing here
    should be trusted to say whether a transaction {i will} be accepted -- the
    account state may have changed since it was read. What this module does is
    make a permission that the caller fetched legible, so that a policy can ask
    the questions that matter: does this permission even allow this contract
    type, and do the signatures present reach the threshold. *)

type key = { address : Tron_types.Address.t; weight : int64 }
type kind = Owner | Witness | Active

type t = {
  kind : kind;
  id : int;
  name : string;
  threshold : int64;
  operations : string;
      (** The 32-byte contract-type bitmap. Empty on owner and witness
          permissions, which are not restricted by contract type. *)
  keys : key list;
}

type error =
  [ `Invalid_operations_length of int
  | `Invalid_kind of int
  | `Invalid_id of int
  | `Invalid_field of string ]

val pp_error : Format.formatter -> [< error ] -> unit
val of_proto : Tron_proto.Tron.Protocol.Permission.t -> (t, error) result

val allows :
  t -> Tron_proto.Tron.Protocol.Transaction.Contract.ContractType.t -> bool
(** Whether the [operations] bitmap authorises this contract type.

    The bitmap is 32 bytes, little-endian: for contract type [n] the bit is at
    byte [n / 8], position [n land 7]. Owner and witness permissions carry no
    bitmap and are not restricted this way, so this returns [true] for them --
    with the caveat that a witness permission cannot authorise ordinary
    contracts at all, which is {!kind}'s business, not the bitmap's. *)

val weight_of : t -> Tron_types.Address.t -> int64
(** [0] if the address is not in the key list. *)

val total_weight : t -> Tron_types.Address.t list -> int64
(** The summed weight of a set of signers, counting each address once. A
    duplicate signature does not raise the total, which is the property that
    stops one key reaching a threshold of two. *)

val meets_threshold : t -> Tron_types.Address.t list -> bool
val pp : Format.formatter -> t -> unit
