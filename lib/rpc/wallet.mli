(** The [/wallet/*] methods this library uses.

    Pinned to java-tron [GreatVoyage-v4.8.2.1]; see [docs/protocol-pin.md].

    {2 What is deliberately absent}

    [/wallet/createtransaction] and its siblings. They build a transaction
    server-side and hand it back to be signed, which means signing bytes chosen
    by the node. This library builds its own; see
    {!Tron_transaction.Transaction}. The endpoint is used in the conformance
    tests as a differential oracle and nowhere else.

    [/wallet/broadcasttransaction] likewise: it takes the JSON form, which means
    re-serializing through the node's shape and trusting it to reproduce the
    signed bytes. {!broadcast_hex} sends the bytes themselves. *)

type block_head = {
  number : int64;
  id : Tron_types.Tx_id.t;
  block_ref : Tron_types.Block_ref.t;
  timestamp : int64;
}

type account = {
  address : Tron_types.Address.t;
  balance : Tron_types.Sun.t;
  create_time : int64;
}

type resources = {
  free_net_used : int64;
  free_net_limit : int64;  (** 600 for an ordinary account. *)
  net_used : int64;
  net_limit : int64;
  energy_used : int64;
  energy_limit : int64;
}

type chain_parameters = {
  energy_fee : int64;  (** sun per unit of energy. *)
  transaction_fee : int64;  (** sun per byte, when bandwidth runs out. *)
  raw : (string * int64) list;
}

type broadcast_result = {
  accepted : bool;
  code : string option;
  message : string option;
  tx_id : Tron_types.Tx_id.t option;
}

type receipt = {
  tx_id : Tron_types.Tx_id.t;
  block_number : int64;
  block_timestamp : int64;
  fee : int64;
  net_usage : int64;
  energy_usage_total : int64;
  succeeded : bool;
  result_message : string;
}

val now_block : block_head Method.t
(** [/wallet/getnowblock]. The head, and therefore the reference block a new
    transaction should be built against. *)

val block_by_num : int64 -> block_head Method.t

val genesis_block : block_head Method.t
(** Block 0. Its id identifies the chain -- the check {!Tron_types.Network}
    exists for. Worth doing before anything is signed, because a Tron
    transaction carries no chain id and the only thing binding it to a chain is
    a reference block taken from this node. *)

val account : Tron_types.Address.t -> account option Method.t
(** [None] for an address the chain has never seen. Tron accounts are created by
    being funded, so "no such account" is an ordinary answer, not an error. *)

val account_resources : Tron_types.Address.t -> resources Method.t
val chain_parameters : chain_parameters Method.t

val estimate_energy :
  owner:Tron_types.Address.t ->
  contract:Tron_types.Address.t ->
  data:string ->
  ?call_value:Tron_types.Sun.t ->
  unit ->
  int64 Method.t
(** [/wallet/estimateenergy].

    Requires [vm.estimateEnergy] {b and} [vm.supportConstant] in the node's
    configuration. A node with either off returns an error rather than an
    estimate, and the caller should fall back to {!trigger_constant_contract},
    whose [energy_used] is a slightly looser bound. *)

val trigger_constant_contract :
  owner:Tron_types.Address.t ->
  contract:Tron_types.Address.t ->
  data:string ->
  ?call_value:Tron_types.Sun.t ->
  unit ->
  (int64 * string) Method.t
(** Simulates a call. Returns the energy used and the raw return data.

    This does not commit anything, but it does run the contract against current
    state -- an estimate taken now can be wrong by the time the transaction
    lands. *)

val broadcast_hex : string -> broadcast_result Method.t
(** [/wallet/broadcasthex]. The argument is
    {!Tron_transaction.Transaction.to_broadcast_hex}: the exact signed bytes. *)

val transaction_info : Tron_types.Tx_id.t -> receipt option Method.t
(** [/wallet/gettransactioninfobyid]. [None] while the transaction is still
    unconfirmed -- java-tron answers with an empty object, which is not an error
    and must not be read as failure. *)
