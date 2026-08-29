(** The reference block a transaction is built against.

    Tron's [raw_data] carries two slices of a recent block:

    - [ref_block_bytes] -- byte interval [\[6, 8)] of the block's {b number},
      big-endian;
    - [ref_block_hash] -- byte interval [\[8, 16)] of the block's {b id}.

    The intervals differ and so do the values they are taken from, which is why
    this is a type rather than two loose strings.

    {2 This is also the chain binding}

    A Tron transaction carries no chain id. Nothing in [raw_data] names mainnet,
    Nile or Shasta. What stops a signed transaction from replaying onto another
    Tron chain is precisely that [ref_block_hash] comes from a block that exists
    only on the chain it was read from.

    The consequence for a signer is direct: the reference block is not a
    performance detail, it is the anti-replay field, and a policy that does not
    know which chain the block came from cannot claim the transaction is bound
    to one. See {!Network}. *)

type t = private { block_bytes : string; block_hash : string }

type error =
  [ `Invalid_length  (** A slice is not its expected width. *)
  | `Mismatch  (** The supplied number and id disagree. *) ]

val pp_error : Format.formatter -> [< error ] -> unit

val of_block_id : Tx_id.t -> t
(** Slices both fields out of the block id alone.

    This works because the first 8 bytes of a Tron block id {i are} the block
    number, big-endian -- so [\[6, 8)] of the number and [\[6, 8)] of the id are
    the same two bytes. Prefer {!of_block} where the number is also to hand: it
    checks that assumption instead of relying on it. *)

val of_block : number:int64 -> id:Tx_id.t -> (t, error) result
(** Slices the fields and verifies that the id's leading 8 bytes are [number]
    big-endian. Returns [`Mismatch] when they are not, which means the node
    returned an inconsistent block and nothing built on it should be signed. *)

val of_slices : block_bytes:string -> block_hash:string -> (t, error) result
(** For decoding a transaction someone else built, where only the slices survive
    and the originating block is unknown. *)

val block_bytes : t -> string
(** 2 bytes. *)

val block_hash : t -> string
(** 8 bytes. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
