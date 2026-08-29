module Address = Tron_types.Address
module Sun = Tron_types.Sun

type instruction =
  | Trx_transfer of { from : Address.t; to_ : Address.t; amount : Sun.t }
  | Trc10_transfer of {
      from : Address.t;
      to_ : Address.t;
      asset : string;
      amount : int64;
    }
  | Trc20_call of {
      owner : Address.t;
      contract : Address.t;
      call : Trc20.call;
      call_value : Sun.t;
    }
  | Contract_call of {
      owner : Address.t;
      contract : Address.t;
      selector : string;
      call_value : Sun.t;
      data_sha256 : string;
    }
  | Stake of { owner : Address.t; amount : Sun.t; resource : Contract.resource }
  | Delegate of {
      owner : Address.t;
      receiver : Address.t;
      amount : Sun.t;
      resource : Contract.resource;
      lock_period : int64;
    }
  | Opaque of { type_url : string; value_sha256 : string }

type t = {
  instruction : instruction;
  permission_id : int;
  fee_limit : Sun.t option;
  expiration : int64;
  timestamp : int64;
  memo : string;
  block_ref : Tron_types.Block_ref.t;
  tx_id : Tron_types.Tx_id.t;
  size : int;
}

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))

let instruction_of_contract : Contract.t -> instruction = function
  | Contract.Transfer { owner; to_; amount } ->
      Trx_transfer { from = owner; to_; amount }
  | Contract.Transfer_asset { asset_name; owner; to_; amount } ->
      Trc10_transfer { from = owner; to_; asset = asset_name; amount }
  | Contract.Trigger_smart_contract { owner; contract; call_value; data; _ }
    -> (
      match Trc20.decode data with
      | Some call -> Trc20_call { owner; contract; call; call_value }
      | None ->
          Contract_call
            {
              owner;
              contract;
              selector =
                (if String.length data >= 4 then String.sub data 0 4 else "");
              call_value;
              data_sha256 = sha256 data;
            })
  | Contract.Freeze_balance_v2 { owner; frozen_balance; resource } ->
      Stake { owner; amount = frozen_balance; resource }
  | Contract.Delegate_resource
      { owner; receiver; balance; resource; lock_period; _ } ->
      Delegate { owner; receiver; amount = balance; resource; lock_period }
  | Contract.Unknown { type_url; value } ->
      Opaque { type_url; value_sha256 = sha256 value }

let of_raw_data raw =
  let bytes = Raw_data.to_bytes raw in
  {
    instruction = instruction_of_contract (Raw_data.contract raw);
    permission_id = Raw_data.permission_id raw;
    fee_limit = Raw_data.fee_limit raw;
    expiration = Raw_data.expiration raw;
    timestamp = Raw_data.timestamp raw;
    memo = Raw_data.memo raw;
    block_ref = Raw_data.block_ref raw;
    tx_id = Raw_data.tx_id raw;
    size = String.length bytes;
  }

let derive bytes = Result.map of_raw_data (Raw_data.of_bytes bytes)

let of_transaction tx =
  let t = of_raw_data (Transaction.raw_data tx) in
  { t with size = String.length (Transaction.to_bytes tx) }

let bandwidth_cost t = t.size

(* Policies *)

type policy_error =
  [ `Unexpected_instruction of string
  | `Wrong_signer of Address.t
  | `Wrong_destination of Address.t
  | `Amount_exceeds_limit of Sun.t
  | `Token_amount_exceeds_limit of Z.t
  | `Unexpected_call_value of Sun.t
  | `Fee_limit_missing
  | `Fee_limit_exceeds of Sun.t
  | `Untrusted_contract of Address.t
  | `Non_owner_permission of int
  | `Expired of int64 ]

let pp_policy_error ppf = function
  | `Unexpected_instruction s ->
      Format.fprintf ppf "not the expected operation: %s" s
  | `Wrong_signer a -> Format.fprintf ppf "unexpected sender %a" Address.pp a
  | `Wrong_destination a ->
      Format.fprintf ppf "unexpected destination %a" Address.pp a
  | `Amount_exceeds_limit v ->
      Format.fprintf ppf "amount %a is over the limit" Sun.pp v
  | `Token_amount_exceeds_limit z ->
      Format.fprintf ppf "token amount %s is over the limit" (Z.to_string z)
  | `Unexpected_call_value v ->
      Format.fprintf ppf "call also sends %a, which this policy does not allow"
        Sun.pp v
  | `Fee_limit_missing ->
      Format.pp_print_string ppf "no fee limit on a contract call"
  | `Fee_limit_exceeds v ->
      Format.fprintf ppf "fee limit %a is over the limit" Sun.pp v
  | `Untrusted_contract a ->
      Format.fprintf ppf "contract %a is not trusted" Address.pp a
  | `Non_owner_permission n ->
      Format.fprintf ppf "signed under permission %d, not owner" n
  | `Expired e -> Format.fprintf ppf "expired at %Ld" e

let ( let* ) = Result.bind

let describe = function
  | Trx_transfer _ -> "TRX transfer"
  | Trc10_transfer _ -> "TRC-10 transfer"
  | Trc20_call _ -> "TRC-20 call"
  | Contract_call _ -> "contract call"
  | Stake _ -> "stake"
  | Delegate _ -> "resource delegation"
  | Opaque { type_url; _ } -> "unrecognised contract " ^ type_url

let check_owner_permission t =
  if t.permission_id = 0 then Ok ()
  else Error (`Non_owner_permission t.permission_id)

let check_freshness ?now t =
  match now with
  | None -> Ok ()
  | Some now ->
      if Int64.compare now t.expiration >= 0 then Error (`Expired t.expiration)
      else Ok ()

let check_addr expect actual err =
  match expect with
  | None -> Ok ()
  | Some e -> if Address.equal e actual then Ok () else Error (err actual)

let validate_trx_transfer ?from ?to_ ?max_amount ?now t =
  let* () = check_owner_permission t in
  let* () = check_freshness ?now t in
  match t.instruction with
  | Trx_transfer { from = f; to_ = d; amount } ->
      let* () = check_addr from f (fun a -> `Wrong_signer a) in
      let* () = check_addr to_ d (fun a -> `Wrong_destination a) in
      let* () =
        match max_amount with
        | Some m when Sun.compare amount m > 0 ->
            Error (`Amount_exceeds_limit amount)
        | _ -> Ok ()
      in
      Ok ()
  | other -> Error (`Unexpected_instruction (describe other))

let validate_trc20_transfer ?from ?to_ ?max_amount ?max_fee_limit
    ~trusted_contracts ?now t =
  let* () = check_owner_permission t in
  let* () = check_freshness ?now t in
  match t.instruction with
  | Trc20_call
      { owner; contract; call = Trc20.Transfer { to_ = d; amount }; call_value }
    ->
      let* () = check_addr from owner (fun a -> `Wrong_signer a) in
      let* () = check_addr to_ d (fun a -> `Wrong_destination a) in
      let* () =
        if List.exists (Address.equal contract) trusted_contracts then Ok ()
        else Error (`Untrusted_contract contract)
      in
      (* TRX riding along with a token transfer moves funds the reviewer was
         shown a token amount for. Not part of this shape. *)
      let* () =
        if Sun.compare call_value Sun.zero = 0 then Ok ()
        else Error (`Unexpected_call_value call_value)
      in
      let* () =
        match t.fee_limit with
        | None -> Error `Fee_limit_missing
        | Some f -> (
            match max_fee_limit with
            | Some m when Sun.compare f m > 0 -> Error (`Fee_limit_exceeds f)
            | _ -> Ok ())
      in
      let* () =
        match max_amount with
        (* A token quantity, not sun: its own constructor, because the number
           a reviewer needs to see here is the token amount. *)
        | Some m when Z.gt amount m ->
            Error (`Token_amount_exceeds_limit amount)
        | _ -> Ok ()
      in
      Ok ()
  | Trc20_call { call; _ } ->
      Error (`Unexpected_instruction (Format.asprintf "%a" Trc20.pp_call call))
  | other -> Error (`Unexpected_instruction (describe other))

(* Rendering *)

let hex s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let pp_resource ppf = function
  | Contract.Bandwidth -> Format.pp_print_string ppf "bandwidth"
  | Contract.Energy -> Format.pp_print_string ppf "energy"

let pp_instruction ppf = function
  | Trx_transfer { from; to_; amount } ->
      Format.fprintf ppf "send %a@ from %a@ to %a" Sun.pp amount Address.pp from
        Address.pp to_
  | Trc10_transfer { from; to_; asset; amount } ->
      Format.fprintf ppf "send %Ld of TRC-10 asset %s@ from %a@ to %a" amount
        asset Address.pp from Address.pp to_
  | Trc20_call { owner; contract; call; call_value } ->
      Format.fprintf ppf "%a@ on token contract %a@ as %a" Trc20.pp_call call
        Address.pp contract Address.pp owner;
      if Sun.compare call_value Sun.zero <> 0 then
        Format.fprintf ppf "@ ALSO SENDING %a" Sun.pp call_value
  | Contract_call { owner; contract; selector; call_value; data_sha256 } ->
      Format.fprintf ppf
        "UNEXPLAINED call to %a@ as %a@ (selector %s, value %a, data sha256 %s)"
        Address.pp contract Address.pp owner
        (if selector = "" then "<none>" else hex selector)
        Sun.pp call_value (hex data_sha256)
  | Stake { owner; amount; resource } ->
      Format.fprintf ppf "stake %a of %a for %a" Sun.pp amount Address.pp owner
        pp_resource resource
  | Delegate { owner; receiver; amount; resource; lock_period } ->
      Format.fprintf ppf "delegate %a worth %a@ from %a@ to %a (lock %Ld)"
        pp_resource resource Sun.pp amount Address.pp owner Address.pp receiver
        lock_period
  | Opaque { type_url; value_sha256 } ->
      Format.fprintf ppf "UNRECOGNISED contract %s (payload sha256 %s)" type_url
        (hex value_sha256)

let pp ppf t =
  Format.fprintf ppf "@[<v>%a" pp_instruction t.instruction;
  Format.fprintf ppf "@,permission: %d%s" t.permission_id
    (if t.permission_id = 0 then " (owner)" else " (active)");
  Format.fprintf ppf "@,fee limit: %s"
    (match t.fee_limit with
    | None -> "none"
    | Some f -> Format.asprintf "%a" Sun.pp f);
  Format.fprintf ppf "@,expires: %Ld" t.expiration;
  Format.fprintf ppf "@,bandwidth: %d bytes" t.size;
  if t.memo <> "" then Format.fprintf ppf "@,memo: %s" (String.escaped t.memo);
  Format.fprintf ppf "@,reference block: %a" Tron_types.Block_ref.pp t.block_ref;
  Format.fprintf ppf "@,transaction id: %a@]" Tron_types.Tx_id.pp t.tx_id
