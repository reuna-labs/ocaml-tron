(** Finality, as a tagged state rather than a boolean.

    A caller has to choose which state its product accepts, and the choice is
    not the same for a coffee payment and a settlement. Collapsing this to
    [confirmed : bool] takes the choice away and picks one silently. *)

type t =
  | Unknown
      (** The node has not seen it. Early on this is ordinary propagation delay;
          past {!expiry}, it means the transaction can never land. *)
  | In_block of { number : int64; depth : int64 }
      (** Included. [depth] is the head's number minus this block's -- how much
          would have to be reorganised to undo it. *)
  | Failed of { message : string }
      (** Included and reverted. The fee was still charged. *)

val of_receipt : head:int64 -> Wallet.receipt option -> t

val is_final : depth:int64 -> t -> bool
(** [is_final ~depth t] is whether [t] is included at least [depth] blocks back.

    Tron blocks are ~3 seconds apart and the SR schedule makes deep
    reorganisations rare, but "rare" is a probability, not a guarantee, and the
    right depth depends on what is at stake. There is no default here for that
    reason. A [Failed] transaction is never final in this sense: it is finished,
    but it did not do what was asked. *)

val pp : Format.formatter -> t -> unit
