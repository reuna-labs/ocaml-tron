module Api = Tron_proto.Api.Protocol
module Tron = Tron_proto.Tron.Protocol
module Smart = Tron_proto.Smart_contract.Protocol
module Address = Tron_types.Address
module Sun = Tron_types.Sun
module Tx_id = Tron_types.Tx_id
module Block_ref = Tron_types.Block_ref
module W = Tron_rpc.Wallet

let ( let* ) = Result.bind
let bytes = Bytes.of_string
let unbytes = Bytes.to_string
let addr_bytes a = bytes (Address.to_bytes a)

let address field b =
  match Address.of_bytes (unbytes b) with
  | Ok a -> Ok a
  | Error _ -> Error (Printf.sprintf "%s is not a valid address" field)

let tx_id field b =
  match Tx_id.of_bytes (unbytes b) with
  | Ok h -> Ok h
  | Error _ -> Error (Printf.sprintf "%s is not a 32-byte digest" field)

let sun field n =
  match Sun.of_sun n with
  | Ok v -> Ok v
  | Error _ -> Error (Printf.sprintf "%s is not a valid amount" field)

(* Blocks *)

let decode_block (b : Api.BlockExtention.t) =
  let* id = tx_id "blockid" b.blockid in
  let header =
    match b.block_header with
    | Some (h : Tron.BlockHeader.t) -> h.raw_data
    | None -> None
  in
  let number, timestamp =
    match header with
    | Some (r : Tron.BlockHeader.Raw.t) -> (r.number, r.timestamp)
    | None -> (0L, 0L)
  in
  (* The same cross-check the HTTP client does: a block whose number and id
     disagree is one nothing may be built on, whichever transport delivered
     it. *)
  let* block_ref =
    match Block_ref.of_block ~number ~id with
    | Ok r -> Ok r
    | Error _ -> Error "block number and blockid disagree"
  in
  Ok { W.number; id; block_ref; timestamp }

let now_block =
  Method_grpc.of_rpc (module Api.Wallet.GetNowBlock2) () decode_block

let block_by_num n =
  Method_grpc.of_rpc (module Api.Wallet.GetBlockByNum2) n decode_block

let genesis_block = block_by_num 0L

(* Accounts *)

let account a =
  Method_grpc.of_rpc
    (module Api.Wallet.GetAccount)
    (Tron.Account.make ~address:(addr_bytes a) ())
    (fun (acc : Tron.Account.t) ->
      (* An account the chain has never seen comes back with an empty address
         rather than as an error -- the protobuf analogue of HTTP's {}. Tron
         accounts are created by being funded, so this is an answer. *)
      if Bytes.length acc.address = 0 then Ok None
      else
        let* address = address "address" acc.address in
        let* balance = sun "balance" acc.balance in
        Ok (Some { W.address; balance; create_time = acc.create_time }))

let account_resources a =
  Method_grpc.of_rpc
    (module Api.Wallet.GetAccountResource)
    (Tron.Account.make ~address:(addr_bytes a) ())
    (fun (r : Api.AccountResourceMessage.t) ->
      Ok
        {
          W.free_net_used = r.freeNetUsed;
          free_net_limit = r.freeNetLimit;
          net_used = r.netUsed;
          net_limit = r.netLimit;
          energy_used = r.energyUsed;
          energy_limit = r.energyLimit;
        })

let chain_parameters =
  Method_grpc.of_rpc
    (module Api.Wallet.GetChainParameters)
    ()
    (fun (p : Tron.ChainParameters.t) ->
      let raw =
        List.map
          (fun (c : Tron.ChainParameters.ChainParameter.t) -> (c.key, c.value))
          p
      in
      let get k = match List.assoc_opt k raw with Some v -> v | None -> 0L in
      Ok
        {
          W.energy_fee = get "getEnergyFee";
          transaction_fee = get "getTransactionFee";
          raw;
        })

(* Contract calls *)

let trigger owner contract data call_value =
  Smart.TriggerSmartContract.make ~owner_address:(addr_bytes owner)
    ~contract_address:(addr_bytes contract) ~data:(bytes data)
    ~call_value:(match call_value with None -> 0L | Some v -> Sun.to_sun v)
    ()

let return_failed (r : Api.Return.t option) =
  (* A reverting simulation is reported inside `result`, not as a gRPC status,
     so a caller reading energy_required without looking here would turn a
     revert into a confident estimate. Same trap as the HTTP path. *)
  match r with
  | None -> Some "no result member"
  | Some ret -> if ret.result then None else Some (unbytes ret.message)

let estimate_energy ~owner ~contract ~data ?call_value () =
  Method_grpc.of_rpc
    (module Api.Wallet.EstimateEnergy)
    (trigger owner contract data call_value)
    (fun (m : Api.EstimateEnergyMessage.t) ->
      match return_failed m.result with
      | Some why -> Error ("simulation failed: " ^ why)
      | None -> Ok m.energy_required)

let trigger_constant_contract ~owner ~contract ~data ?call_value () =
  Method_grpc.of_rpc
    (module Api.Wallet.TriggerConstantContract)
    (trigger owner contract data call_value)
    (fun (t : Api.TransactionExtention.t) ->
      match return_failed t.result with
      | Some why -> Error ("constant call failed: " ^ why)
      | None ->
          let ret =
            match t.constant_result with b :: _ -> unbytes b | [] -> ""
          in
          Ok (t.energy_used, ret))

(* Broadcast *)

let broadcast wire =
  (* The request is the bytes that were signed, framed by hand rather than
     re-encoded from a decoded model. Handing the model to the generated
     encoder would change the raw_data -- and therefore the transaction id --
     for any transaction that arrived with framing this library would not have
     chosen. See Tron_transaction.Transaction.to_bytes. *)
  Method_grpc.make ~service:"protocol.Wallet" ~rpc:"BroadcastTransaction"
    ~request:wire (fun body ->
      match
        Tron_transaction.Proto_decode.protect
          (fun () ->
            Api.Return.from_proto (Ocaml_protoc_plugin.Reader.create body))
          "BroadcastTransaction"
      with
      | Error _ -> Error "BroadcastTransaction: response did not decode"
      | Ok (r : Api.Return.t) ->
          Ok
            {
              W.accepted = r.result;
              code = Some (Api.Return.Response_code.to_string r.code);
              message =
                (match unbytes r.message with "" -> None | m -> Some m);
              (* gRPC's Return carries no txid; the caller already knows it,
                 having computed it before signing. *)
              tx_id = None;
            })

(* Receipts *)

let transaction_info id =
  Method_grpc.of_rpc
    (module Api.Wallet.GetTransactionInfoById)
    (bytes (Tx_id.to_bytes id))
    (fun (info : Tron.TransactionInfo.t) ->
      (* An unconfirmed transaction comes back with an empty id, the analogue
         of HTTP's {}. Not an error, and not a failure. *)
      if Bytes.length info.id = 0 then Ok None
      else
        let* tx_id = tx_id "id" info.id in
        let net_usage, energy_usage_total =
          match info.receipt with
          | Some (r : Tron.ResourceReceipt.t) ->
              (r.net_usage, r.energy_usage_total)
          | None -> (0L, 0L)
        in
        let succeeded =
          match info.result with
          | Tron.TransactionInfo.Code.SUCESS -> true
          | Tron.TransactionInfo.Code.FAILED -> false
        in
        Ok
          (Some
             {
               W.tx_id;
               block_number = info.blockNumber;
               block_timestamp = info.blockTimeStamp;
               fee = info.fee;
               net_usage;
               energy_usage_total;
               succeeded;
               result_message = unbytes info.resMessage;
             }))
