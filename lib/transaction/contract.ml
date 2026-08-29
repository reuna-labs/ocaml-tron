module P = Tron_proto.Tron.Protocol
module Balance = Tron_proto.Balance_contract.Protocol
module Asset = Tron_proto.Asset_issue_contract.Protocol
module Smart = Tron_proto.Smart_contract.Protocol
module Common = Tron_proto.Common.Protocol
module Any = Tron_proto.Any.Google.Protobuf.Any
module Ct = P.Transaction.Contract.ContractType
module Writer = Ocaml_protoc_plugin.Writer
module Reader = Ocaml_protoc_plugin.Reader
module Address = Tron_types.Address
module Sun = Tron_types.Sun

type resource = Bandwidth | Energy

type t =
  | Transfer of { owner : Address.t; to_ : Address.t; amount : Sun.t }
  | Transfer_asset of {
      asset_name : string;
      owner : Address.t;
      to_ : Address.t;
      amount : int64;
    }
  | Trigger_smart_contract of {
      owner : Address.t;
      contract : Address.t;
      call_value : Sun.t;
      data : string;
      call_token_value : int64;
      token_id : int64;
    }
  | Freeze_balance_v2 of {
      owner : Address.t;
      frozen_balance : Sun.t;
      resource : resource;
    }
  | Delegate_resource of {
      owner : Address.t;
      receiver : Address.t;
      balance : Sun.t;
      resource : resource;
      lock : bool;
      lock_period : int64;
    }
  | Unknown of { type_url : string; value : string }

type error =
  [ `Unknown_type_url of string
  | `Malformed of string
  | `Invalid_field of string ]

let pp_error ppf = function
  | `Unknown_type_url u -> Format.fprintf ppf "unrecognised contract type %s" u
  | `Malformed m -> Format.fprintf ppf "malformed %s payload" m
  | `Invalid_field f -> Format.fprintf ppf "invalid %s" f

let prefix = "type.googleapis.com/protocol."
let url name = prefix ^ name

let type_url = function
  | Transfer _ -> url "TransferContract"
  | Transfer_asset _ -> url "TransferAssetContract"
  | Trigger_smart_contract _ -> url "TriggerSmartContract"
  | Freeze_balance_v2 _ -> url "FreezeBalanceV2Contract"
  | Delegate_resource _ -> url "DelegateResourceContract"
  | Unknown { type_url; _ } -> type_url

let contract_type = function
  | Transfer _ -> Ct.TransferContract
  | Transfer_asset _ -> Ct.TransferAssetContract
  | Trigger_smart_contract _ -> Ct.TriggerSmartContract
  | Freeze_balance_v2 _ -> Ct.FreezeBalanceV2Contract
  | Delegate_resource _ -> Ct.DelegateResourceContract
  (* An Unknown round-trips its bytes but not its enum: the enum is not
     recoverable from the type_url without the mapping this library is
     precisely admitting it does not have. Re-encoding an Unknown is therefore
     not supported, and Raw_data refuses it rather than writing a contract
     whose type and payload disagree. *)
  | Unknown _ -> Ct.CustomContract

let resource_to_proto = function
  | Bandwidth -> Common.ResourceCode.BANDWIDTH
  | Energy -> Common.ResourceCode.ENERGY

let resource_of_proto = function
  | Common.ResourceCode.BANDWIDTH -> Ok Bandwidth
  | Common.ResourceCode.ENERGY -> Ok Energy
  (* TRON_POWER is a staking-weight resource, not something a transfer or a
     contract call consumes. It is not in the launch set. *)
  | Common.ResourceCode.TRON_POWER ->
      Error (`Invalid_field "resource: TRON_POWER")

let bytes = Bytes.of_string
let unbytes = Bytes.to_string
let addr a = bytes (Address.to_bytes a)

let payload = function
  | Transfer { owner; to_; amount } ->
      Writer.contents
        (Balance.TransferContract.to_proto
           (Balance.TransferContract.make ~owner_address:(addr owner)
              ~to_address:(addr to_) ~amount:(Sun.to_sun amount) ()))
  | Transfer_asset { asset_name; owner; to_; amount } ->
      Writer.contents
        (Asset.TransferAssetContract.to_proto
           (Asset.TransferAssetContract.make ~asset_name:(bytes asset_name)
              ~owner_address:(addr owner) ~to_address:(addr to_) ~amount ()))
  | Trigger_smart_contract
      { owner; contract; call_value; data; call_token_value; token_id } ->
      Writer.contents
        (Smart.TriggerSmartContract.to_proto
           (Smart.TriggerSmartContract.make ~owner_address:(addr owner)
              ~contract_address:(addr contract)
              ~call_value:(Sun.to_sun call_value) ~data:(bytes data)
              ~call_token_value ~token_id ()))
  | Freeze_balance_v2 { owner; frozen_balance; resource } ->
      Writer.contents
        (Balance.FreezeBalanceV2Contract.to_proto
           (Balance.FreezeBalanceV2Contract.make ~owner_address:(addr owner)
              ~frozen_balance:(Sun.to_sun frozen_balance)
              ~resource:(resource_to_proto resource)
              ()))
  | Delegate_resource { owner; receiver; balance; resource; lock; lock_period }
    ->
      Writer.contents
        (Balance.DelegateResourceContract.to_proto
           (Balance.DelegateResourceContract.make ~owner_address:(addr owner)
              ~receiver_address:(addr receiver) ~balance:(Sun.to_sun balance)
              ~resource:(resource_to_proto resource)
              ~lock ~lock_period ()))
  | Unknown { value; _ } -> value

let to_proto ?(permission_id = 0) t =
  P.Transaction.Contract.make ~type':(contract_type t)
    ~parameter:(Any.make ~type_url:(type_url t) ~value:(bytes (payload t)) ())
    ~permission_id ()

(* Decoding *)

let reader s = Reader.create s

(* Through Proto_decode.protect, not straight to from_proto: the generated
   reader raises on some malformed input despite its result type. See that
   module. *)
let decode name f s =
  match Proto_decode.protect (fun () -> f (reader s)) name with
  | Ok v -> Ok v
  | Error _ -> Error (`Malformed name)

let address field b =
  match Address.of_bytes (unbytes b) with
  | Ok a -> Ok a
  | Error _ -> Error (`Invalid_field field)

let sun field n =
  match Sun.of_sun n with
  | Ok v -> Ok v
  | Error _ -> Error (`Invalid_field field)

let ( let* ) = Result.bind

let of_proto (c : P.Transaction.Contract.t) =
  match c.parameter with
  | None ->
      (* A contract with no parameter is not a contract this library can
         describe, and it is not "empty" either -- it is malformed. *)
      Error (`Malformed "contract with no parameter")
  | Some any -> (
      let v = unbytes any.value in
      match any.type_url with
      | u when u = url "TransferContract" ->
          let* p =
            decode "TransferContract" Balance.TransferContract.from_proto v
          in
          let* owner = address "owner_address" p.owner_address in
          let* to_ = address "to_address" p.to_address in
          let* amount = sun "amount" p.amount in
          Ok (Transfer { owner; to_; amount })
      | u when u = url "TransferAssetContract" ->
          let* p =
            decode "TransferAssetContract"
              Asset.TransferAssetContract.from_proto v
          in
          let* owner = address "owner_address" p.owner_address in
          let* to_ = address "to_address" p.to_address in
          Ok
            (Transfer_asset
               {
                 asset_name = unbytes p.asset_name;
                 owner;
                 to_;
                 amount = p.amount;
               })
      | u when u = url "TriggerSmartContract" ->
          let* p =
            decode "TriggerSmartContract" Smart.TriggerSmartContract.from_proto
              v
          in
          let* owner = address "owner_address" p.owner_address in
          let* contract = address "contract_address" p.contract_address in
          let* call_value = sun "call_value" p.call_value in
          Ok
            (Trigger_smart_contract
               {
                 owner;
                 contract;
                 call_value;
                 data = unbytes p.data;
                 call_token_value = p.call_token_value;
                 token_id = p.token_id;
               })
      | u when u = url "FreezeBalanceV2Contract" ->
          let* p =
            decode "FreezeBalanceV2Contract"
              Balance.FreezeBalanceV2Contract.from_proto v
          in
          let* owner = address "owner_address" p.owner_address in
          let* frozen_balance = sun "frozen_balance" p.frozen_balance in
          let* resource = resource_of_proto p.resource in
          Ok (Freeze_balance_v2 { owner; frozen_balance; resource })
      | u when u = url "DelegateResourceContract" ->
          let* p =
            decode "DelegateResourceContract"
              Balance.DelegateResourceContract.from_proto v
          in
          let* owner = address "owner_address" p.owner_address in
          let* receiver = address "receiver_address" p.receiver_address in
          let* balance = sun "balance" p.balance in
          let* resource = resource_of_proto p.resource in
          Ok
            (Delegate_resource
               {
                 owner;
                 receiver;
                 balance;
                 resource;
                 lock = p.lock;
                 lock_period = p.lock_period;
               })
      | type_url -> Ok (Unknown { type_url; value = v }))

let pp_resource ppf = function
  | Bandwidth -> Format.pp_print_string ppf "bandwidth"
  | Energy -> Format.pp_print_string ppf "energy"

let hex s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let pp ppf = function
  | Transfer { owner; to_; amount } ->
      Format.fprintf ppf "transfer %a from %a to %a" Sun.pp amount Address.pp
        owner Address.pp to_
  | Transfer_asset { asset_name; owner; to_; amount } ->
      Format.fprintf ppf "transfer %Ld of asset %s from %a to %a" amount
        asset_name Address.pp owner Address.pp to_
  | Trigger_smart_contract { owner; contract; call_value; data; _ } ->
      Format.fprintf ppf "call %a on %a (selector %s, value %a)" Address.pp
        owner Address.pp contract
        (if String.length data >= 4 then hex (String.sub data 0 4) else "<none>")
        Sun.pp call_value
  | Freeze_balance_v2 { owner; frozen_balance; resource } ->
      Format.fprintf ppf "stake %a of %a for %a" Sun.pp frozen_balance
        Address.pp owner pp_resource resource
  | Delegate_resource { owner; receiver; balance; resource; _ } ->
      Format.fprintf ppf "delegate %a of %a from %a to %a" pp_resource resource
        Sun.pp balance Address.pp owner Address.pp receiver
  | Unknown { type_url; value } ->
      Format.fprintf ppf "UNRECOGNISED %s (%d bytes, sha256 %s)" type_url
        (String.length value)
        (hex Digestif.SHA256.(to_raw_string (digest_string value)))
