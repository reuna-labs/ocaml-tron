(** The signed part of a transaction.

    Everything a signature covers is here. {!Transaction} adds only the
    signatures themselves, which are not covered by anything.

    {2 Nothing here reads a clock}

    [expiration] and [timestamp] are wall-clock milliseconds and both are
    arguments. A signer that could read a clock could be walked into widening
    its own validity window, so the current time enters from the caller, who is
    also the one who knows which node's clock the reference block came from. *)

type t

type error =
  [ `No_contract  (** The contract list is empty. *)
  | `Too_many_contracts  (** java-tron supports exactly one. *)
  | `Unencodable_contract
    (** An {!Contract.Unknown} cannot be re-encoded; see {!make}. *)
  | `Invalid_permission_id of int
  | Contract.error ]

val pp_error : Format.formatter -> [< error ] -> unit

val make :
  block_ref:Tron_types.Block_ref.t ->
  expiration:int64 ->
  timestamp:int64 ->
  ?permission_id:int ->
  ?fee_limit:Tron_types.Sun.t ->
  ?memo:string ->
  Contract.t ->
  (t, error) result
(** [permission_id] defaults to [0] (owner). [2]-[9] name active permissions;
    [1] is the witness permission, which cannot authorise ordinary contracts and
    is rejected here.

    [fee_limit] caps the TRX burned when staked energy runs short. It is
    meaningless on a plain transfer and mandatory in practice on a contract
    call; this function does not enforce that, because "mandatory in practice"
    is a policy question -- see {!Intent}.

    Rejects a {!Contract.Unknown}: re-encoding one would write a [type] enum
    that does not follow from its [type_url], producing a transaction whose two
    descriptions of itself disagree. Unknown contracts can be decoded and
    displayed, never built. *)

val to_bytes : t -> string
(** The canonical protobuf serialization -- the exact bytes the transaction id
    is taken over, and therefore the exact bytes being signed. *)

val of_bytes : string -> (t, error) result
(** Decodes bytes someone else produced.

    The source bytes are retained: {!to_bytes} on the result returns what came
    in, not a re-encode. Protobuf permits encodings that differ in field order
    and varint padding while decoding to the same message, so a re-encode can
    have a different transaction id than the thing it was decoded from. When the
    question is "what does this transaction that already exists say", the answer
    has to be about the bytes it actually has. *)

val contract : t -> Contract.t
val block_ref : t -> Tron_types.Block_ref.t
val expiration : t -> int64
val timestamp : t -> int64
val permission_id : t -> int
val fee_limit : t -> Tron_types.Sun.t option
val memo : t -> string

val tx_id : t -> Tron_types.Tx_id.t
(** [SHA-256] of {!to_bytes}. This is the transaction id, and it is also the
    digest that gets signed.

    Not Keccak-256. Keccak appears in this protocol only in address derivation
    and ABI selectors. Both produce 32 bytes. *)
