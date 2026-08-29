(** Which Tron chain a client is talking to.

    Tron transactions carry no chain id. A signed transaction is bound to a
    chain only through {!Block_ref}, whose [ref_block_hash] came from a block
    that exists on one chain. So "which chain is this" is a question about the
    node, answered before a reference block is fetched, not a field to check
    inside [raw_data].

    {2 No hardcoded genesis ids}

    This module deliberately ships no genesis constants. A signer that trusts a
    compiled-in hash learns nothing it did not already assume; the useful check
    is against the node actually being used, with the expected value supplied by
    whoever deployed the signer and is in a position to know. {!expected} takes
    that value; {!verify} compares it with what the node returned.

    Fill in a named constant here only with a citation to the block-0 response
    it was read from, in [docs/protocol-pin.md]. *)

type t = private { name : string; genesis_block_id : Tx_id.t }

val make : name:string -> genesis_block_id:Tx_id.t -> t

val expected : name:string -> string -> (t, [> `Invalid_format ]) result
(** [expected ~name hex] builds the identity a deployment expects, from the
    genesis block id it was configured with. *)

val verify :
  expect:t ->
  observed:Tx_id.t ->
  (unit, [> `Wrong_chain of t * Tx_id.t ]) result
(** Compares the node's block-0 id with the expected one. A mismatch means the
    client is pointed at a different chain than it was configured for, and no
    reference block from it may be used. *)

val name : t -> string
val genesis_block_id : t -> Tx_id.t
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
