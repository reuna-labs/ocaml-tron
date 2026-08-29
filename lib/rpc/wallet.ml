module Address = Tron_types.Address
module Sun = Tron_types.Sun
module Tx_id = Tron_types.Tx_id
module Block_ref = Tron_types.Block_ref

type block_head = {
  number : int64;
  id : Tx_id.t;
  block_ref : Block_ref.t;
  timestamp : int64;
}

type account = { address : Address.t; balance : Sun.t; create_time : int64 }

type resources = {
  free_net_used : int64;
  free_net_limit : int64;
  net_used : int64;
  net_limit : int64;
  energy_used : int64;
  energy_limit : int64;
}

type chain_parameters = {
  energy_fee : int64;
  transaction_fee : int64;
  raw : (string * int64) list;
}

type broadcast_result = {
  accepted : bool;
  code : string option;
  message : string option;
  tx_id : Tx_id.t option;
}

type receipt = {
  tx_id : Tx_id.t;
  block_number : int64;
  block_timestamp : int64;
  fee : int64;
  net_usage : int64;
  energy_usage_total : int64;
  succeeded : bool;
  result_message : string;
}

let ( let* ) = Result.bind

(* Addresses go out as hex, and `visible` is left at its default false, so the
   node answers in hex too. Json.address_field accepts either regardless. *)
let addr a = `String (Address.to_hex a)

let hex s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let decode_block j =
  let* id = Json.tx_id_field "blockID" j in
  let header =
    match Json.field "block_header" j with Some h -> h | None -> `Assoc []
  in
  let raw =
    match Json.field "raw_data" header with Some r -> r | None -> `Assoc []
  in
  let number = Json.opt_int64_field "number" raw in
  let timestamp = Json.opt_int64_field "timestamp" raw in
  (* Cross-check the number against the id rather than trusting the pair: a
     reference block whose two halves disagree is one nothing may be built on. *)
  let* block_ref =
    match Block_ref.of_block ~number ~id with
    | Ok r -> Ok r
    | Error _ -> Error "block number and blockID disagree"
  in
  Ok { number; id; block_ref; timestamp }

let now_block = Method.make ~path:"/wallet/getnowblock" decode_block

let block_by_num n =
  Method.make ~path:"/wallet/getblockbynum"
    ~body:[ ("num", `Intlit (Int64.to_string n)) ]
    decode_block

let genesis_block = block_by_num 0L

let account address =
  Method.make ~path:"/wallet/getaccount"
    ~body:[ ("address", addr address) ]
    (fun j ->
      (* An address the chain has never seen comes back as {}. That is an
         answer, not a failure: Tron accounts are created by being funded. *)
      match Json.field "address" j with
      | None -> Ok None
      | Some _ ->
          let* address = Json.address_field "address" j in
          let balance =
            match Json.sun_field "balance" j with
            | Ok b -> b
            | Error _ -> Sun.zero
          in
          Ok
            (Some
               {
                 address;
                 balance;
                 create_time = Json.opt_int64_field "create_time" j;
               }))

let account_resources address =
  Method.make ~path:"/wallet/getaccountresource"
    ~body:[ ("address", addr address) ]
    (fun j ->
      Ok
        {
          free_net_used = Json.opt_int64_field "freeNetUsed" j;
          free_net_limit = Json.opt_int64_field "freeNetLimit" j;
          net_used = Json.opt_int64_field "NetUsed" j;
          net_limit = Json.opt_int64_field "NetLimit" j;
          energy_used = Json.opt_int64_field "EnergyUsed" j;
          energy_limit = Json.opt_int64_field "EnergyLimit" j;
        })

let chain_parameters =
  Method.make ~path:"/wallet/getchainparameters" (fun j ->
      let* entries = Json.list_field "chainParameter" j in
      let raw =
        List.filter_map
          (fun e ->
            match Json.string_field "key" e with
            | Error _ -> None
            | Ok k -> Some (k, Json.opt_int64_field "value" e))
          entries
      in
      let get k = match List.assoc_opt k raw with Some v -> v | None -> 0L in
      Ok
        {
          energy_fee = get "getEnergyFee";
          transaction_fee = get "getTransactionFee";
          raw;
        })

let call_body ~owner ~contract ~data ?call_value () =
  [
    ("owner_address", addr owner);
    ("contract_address", addr contract);
    ("data", `String (hex data));
  ]
  @
  match call_value with
  | None -> []
  | Some v -> [ ("call_value", `Intlit (Int64.to_string (Sun.to_sun v))) ]

let estimate_energy ~owner ~contract ~data ?call_value () =
  Method.make ~path:"/wallet/estimateenergy"
    ~body:(call_body ~owner ~contract ~data ?call_value ()) (fun j ->
      (* The node reports a failed simulation inside `result`, with a 200 and no
         top-level Error member, so the provider's error check does not catch
         it. Reading energy_required without looking here would turn a reverting
         call into a confident estimate. *)
      let ok =
        match Json.field "result" j with
        | Some r -> Json.bool_field "result" r
        | None -> false
      in
      if not ok then
        Error
          (match Json.field "result" j with
          | Some r -> (
              match Json.hex_field "message" r with
              | Ok m -> "simulation failed: " ^ m
              | Error _ -> "simulation failed")
          | None -> "no result member")
      else Ok (Json.opt_int64_field "energy_required" j))

let trigger_constant_contract ~owner ~contract ~data ?call_value () =
  Method.make ~path:"/wallet/triggerconstantcontract"
    ~body:(call_body ~owner ~contract ~data ?call_value ()) (fun j ->
      let ok =
        match Json.field "result" j with
        | Some r -> Json.bool_field "result" r
        | None -> false
      in
      if not ok then Error "constant call failed"
      else
        let energy = Json.opt_int64_field "energy_used" j in
        let ret =
          match Json.list_field "constant_result" j with
          | Ok (`String s :: _) -> s
          | _ -> ""
        in
        Ok (energy, ret))

let broadcast_hex signed =
  Method.make ~path:"/wallet/broadcasthex"
    ~body:[ ("transaction", `String signed) ]
    (fun j ->
      let accepted = Json.bool_field "result" j in
      let code = Result.to_option (Json.string_field "code" j) in
      let message =
        match Json.hex_field "message" j with
        | Ok m -> Some m
        | Error _ -> Result.to_option (Json.string_field "message" j)
      in
      let tx_id = Result.to_option (Json.tx_id_field "txid" j) in
      Ok { accepted; code; message; tx_id })

let transaction_info id =
  Method.make ~path:"/wallet/gettransactioninfobyid"
    ~body:[ ("value", `String (Tx_id.to_hex id)) ]
    (fun j ->
      (* An unconfirmed transaction comes back as {}. Not an error, and not a
         failure -- reading it as either would report a pending transfer as
         rejected. *)
      match Json.field "id" j with
      | None -> Ok None
      | Some _ ->
          let* tx_id = Json.tx_id_field "id" j in
          let receipt =
            match Json.field "receipt" j with Some r -> r | None -> `Assoc []
          in
          let result_message =
            match Json.hex_field "resMessage" j with Ok m -> m | Error _ -> ""
          in
          (* java-tron omits `result` entirely on success and sets it to FAILED
             on failure, so absence means success here. That asymmetry is the
             node's, not ours. *)
          let succeeded =
            match Json.string_field "result" j with
            | Ok "FAILED" -> false
            | Ok _ -> false
            | Error _ -> true
          in
          Ok
            (Some
               {
                 tx_id;
                 block_number = Json.opt_int64_field "blockNumber" j;
                 block_timestamp = Json.opt_int64_field "blockTimeStamp" j;
                 fee = Json.opt_int64_field "fee" j;
                 net_usage = Json.opt_int64_field "net_usage" receipt;
                 energy_usage_total =
                   Json.opt_int64_field "energy_usage_total" receipt;
                 succeeded;
                 result_message;
               }))
