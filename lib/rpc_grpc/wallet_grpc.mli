(** The Wallet service, decoding into {!Tron_rpc.Wallet}'s types.

    Same values, different wire. Every function here has a counterpart in
    {!Tron_rpc.Wallet} with the same name and the same result type, which is
    what lets [test/test_grpc_parity.ml] compare them rather than merely run
    both.

    {2 Where the two surfaces are not the same shape}

    - HTTP's [getnowblock] maps to gRPC's [GetNowBlock2], which returns a
      [BlockExtention] rather than a [Block]. The extension carries the same
      header and block id; the difference is in how transactions are listed,
      which this client does not read.
    - HTTP's [broadcasthex] has no gRPC counterpart. [BroadcastTransaction]
      takes a [Transaction] message. This library sends the bytes it signed
      rather than a re-encoded model, so the request is framed from
      {!Tron_transaction.Transaction.to_bytes} directly -- see {!broadcast}.
    - gRPC has no [visible] flag and no hex-encoded [bytes], because protobuf
      has types. That is the main reason to prefer it for reads. *)

val now_block : Tron_rpc.Wallet.block_head Method_grpc.t
val block_by_num : int64 -> Tron_rpc.Wallet.block_head Method_grpc.t

val genesis_block : Tron_rpc.Wallet.block_head Method_grpc.t
(** Block 0, whose id identifies the chain. *)

val account :
  Tron_types.Address.t -> Tron_rpc.Wallet.account option Method_grpc.t

val account_resources :
  Tron_types.Address.t -> Tron_rpc.Wallet.resources Method_grpc.t

val chain_parameters : Tron_rpc.Wallet.chain_parameters Method_grpc.t

val estimate_energy :
  owner:Tron_types.Address.t ->
  contract:Tron_types.Address.t ->
  data:string ->
  ?call_value:Tron_types.Sun.t ->
  unit ->
  int64 Method_grpc.t

val trigger_constant_contract :
  owner:Tron_types.Address.t ->
  contract:Tron_types.Address.t ->
  data:string ->
  ?call_value:Tron_types.Sun.t ->
  unit ->
  (int64 * string) Method_grpc.t

val broadcast : string -> Tron_rpc.Wallet.broadcast_result Method_grpc.t
(** [broadcast wire] where [wire] is {!Tron_transaction.Transaction.to_bytes} --
    the already-serialized signed transaction.

    Deliberately a string rather than a decoded transaction. gRPC would
    otherwise re-encode the model, and a [raw_data] that arrived with framing
    this library would not have chosen re-encodes to different bytes and
    therefore a different transaction id than the one that was signed. Passing
    the bytes through is the only way to be sure the node executes what was
    reviewed. *)

val transaction_info :
  Tron_types.Tx_id.t -> Tron_rpc.Wallet.receipt option Method_grpc.t
