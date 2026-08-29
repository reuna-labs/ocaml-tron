(** Getting a transaction onto the chain, as a pure state machine.

    The interpreter is a transport; this is the decision-making, so it can be
    tested against every ordering without a network -- including the ones that
    matter, which are the failures.

    {2 Expiry forces a rebuild, never a replay}

    A Tron transaction is valid until its [expiration]. When that passes, the
    signed bytes are dead: the reference block they name is old and the node
    will refuse them. The machine's answer is {!Rebuild} -- go back, take a new
    reference block,
    {b re-derive the intent, have it reviewed again, and re-sign}.

    It deliberately cannot resubmit the bytes it already has, because that is
    the shape of the mistake: a signer that re-signs a stale payload without
    re-reviewing it has approved something once and used it twice. This is the
    same conclusion [ocaml-solana] reached for blockhash expiry. *)

type config = {
  max_broadcast_attempts : int;
  max_polls : int;
  required_depth : int64;
      (** How deep is deep enough. No default: see {!Confirmation.is_final}. *)
}

val default_config : config
(** Three broadcast attempts, twenty polls, depth [19].

    Depth 19 is the SR round: Tron's 27 super representatives produce in a
    rotation, and a transaction that many blocks back has been built on by a
    majority of them. It is a convention, not a protocol guarantee, and a
    product moving real value should choose its own. *)

type state

type step =
  | Need_reference_block
  | Need_broadcast of { hex : string }
  | Need_receipt of { tx_id : Tron_types.Tx_id.t }
  | Need_head
  | Rebuild of { reason : string }
      (** Start over from a fresh reference block, re-deriving and re-reviewing
          the intent. Never a resubmission of the bytes already signed. *)
  | Done of { tx_id : Tron_types.Tx_id.t; confirmation : Confirmation.t }
  | Give_up of { reason : string }

val start : ?config:config -> unit -> state
val step : state -> step

(** {1 Events} *)

val got_reference_block : state -> Wallet.block_head -> state

val got_signed :
  state -> tx_id:Tron_types.Tx_id.t -> hex:string -> expiration:int64 -> state
(** The caller built, reviewed and signed. The machine is told the expiration so
    it can tell "not yet seen" from "can no longer land" without a clock of its
    own. *)

val got_broadcast : state -> Wallet.broadcast_result -> state
val got_head : state -> int64 -> state
val got_receipt : state -> Wallet.receipt option -> state

val failed : state -> Error.t -> state
(** A transport or node failure. Whether this is retried depends on where it
    happened: a failed broadcast may or may not have been accepted, so the
    machine polls for the receipt rather than broadcasting again. *)

val expired : state -> state
(** The caller observed, from its own clock, that [expiration] has passed. Time
    enters here and nowhere else. *)

val tx_id : state -> Tron_types.Tx_id.t option
val confirmation : state -> Confirmation.t

val head : state -> int64
(** The chain head as last reported. Depth is measured against it, so a caller
    rendering progress needs it as much as the machine does. *)
