(** What a transaction will cost, from values the node supplied.

    Pure arithmetic. Nothing here contacts a node or invents a rate: every
    parameter is governance-controlled and read from {!Wallet.chain_parameters},
    because a compiled-in rate is a wrong rate the day it changes. *)

type bandwidth_charge =
  | Free of { points : int64 }  (** Covered by the daily free quota. *)
  | Staked of { points : int64 }  (** Covered by staked bandwidth. *)
  | Burned of { sun : Tron_types.Sun.t }
      (** Neither covered it, so TRX is burned at [getTransactionFee] per byte.
      *)

val bandwidth_charge :
  params:Wallet.chain_parameters ->
  resources:Wallet.resources ->
  size:int ->
  bandwidth_charge
(** [size] is the transaction's on-chain byte count --
    {!Tron_transaction.Intent.bandwidth_cost} of the {i signed} transaction, not
    of its [raw_data].

    The order matters and is java-tron's: free quota first, then staked
    bandwidth, then burning. A caller that checked staked bandwidth first would
    report a burn for a transaction that costs nothing. *)

val fee_limit_for_energy :
  params:Wallet.chain_parameters -> energy:int64 -> Tron_types.Sun.t
(** [energy * getEnergyFee], the cap to put on a contract call.

    This is the figure a reviewer is shown as [fee_limit], and it is a ceiling
    on what can be burned, not a prediction of what will be. Energy the account
    has staked is consumed first and costs nothing. *)

val suggested_fee_limit :
  params:Wallet.chain_parameters ->
  energy:int64 ->
  ?headroom_percent:int ->
  unit ->
  Tron_types.Sun.t
(** {!fee_limit_for_energy} plus headroom, default 20%.

    Headroom exists because an estimate is taken against state that will have
    moved by the time the transaction lands, and a call that exceeds its
    [fee_limit] does not fail cheaply -- it consumes the energy it used and
    reverts. Too little headroom wastes the fee; too much raises the ceiling on
    what a mistake can cost. Neither default is safe in general, which is why
    this is a suggestion and the reviewer still sees the number. *)
