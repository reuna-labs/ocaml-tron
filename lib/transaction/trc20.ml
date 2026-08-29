module Address = Tron_types.Address

let selector_of s = Evm_abi.selector s
let transfer_sig = "transfer(address,uint256)"
let transfer_from_sig = "transferFrom(address,address,uint256)"
let approve_sig = "approve(address,uint256)"
let balance_of_sig = "balanceOf(address)"
let transfer_selector = selector_of transfer_sig
let transfer_from_selector = selector_of transfer_from_sig
let approve_selector = selector_of approve_sig
let balance_of_selector = selector_of balance_of_sig

(* The one Tron-specific step: the ABI word carries the 20-byte hash, not the
   21-byte address. See the .mli. *)
let word a = Evm_abi.Address (Address.to_hash20 a)

let encode selector args =
  match Evm_abi.encode args with
  | Ok body -> Ok (selector ^ body)
  | Error e -> Error e

let transfer ~to_ ~amount =
  encode transfer_selector [ word to_; Evm_abi.Uint amount ]

let transfer_from ~from ~to_ ~amount =
  encode transfer_from_selector [ word from; word to_; Evm_abi.Uint amount ]

let approve ~spender ~amount =
  encode approve_selector [ word spender; Evm_abi.Uint amount ]

let balance_of ~owner = encode balance_of_selector [ word owner ]

type call =
  | Transfer of { to_ : Address.t; amount : Z.t }
  | Transfer_from of { from : Address.t; to_ : Address.t; amount : Z.t }
  | Approve of { spender : Address.t; amount : Z.t }
  | Balance_of of { owner : Address.t }

let word_size = 32

let address_of_value = function
  | Evm_abi.Address h -> Address.of_hash20 h |> Result.to_option
  | _ -> None

let uint_of_value = function Evm_abi.Uint z -> Some z | _ -> None

let decode data =
  let n = String.length data in
  if n < 4 then None
  else
    let selector = String.sub data 0 4 in
    let args = String.sub data 4 (n - 4) in
    let arity =
      if String.equal selector transfer_selector then Some (2, `Transfer)
      else if String.equal selector transfer_from_selector then
        Some (3, `Transfer_from)
      else if String.equal selector approve_selector then Some (2, `Approve)
      else if String.equal selector balance_of_selector then
        Some (1, `Balance_of)
      else None
    in
    match arity with
    | None -> None
    (* Trailing bytes past the declared arguments decode fine under the ABI's
       head/tail rules but mean the call is not the call it appears to be.
       Refusing here is the difference between describing a transaction and
       guessing at it. *)
    | Some (k, _) when String.length args <> k * word_size -> None
    | Some (_, shape) -> (
        let types =
          match shape with
          | `Transfer -> [ Evm_abi.TAddress; Evm_abi.TUint 256 ]
          | `Transfer_from ->
              [ Evm_abi.TAddress; Evm_abi.TAddress; Evm_abi.TUint 256 ]
          | `Approve -> [ Evm_abi.TAddress; Evm_abi.TUint 256 ]
          | `Balance_of -> [ Evm_abi.TAddress ]
        in
        match Evm_abi.decode types args with
        | Error _ -> None
        | Ok values -> (
            match (shape, values) with
            | `Transfer, [ a; v ] -> (
                match (address_of_value a, uint_of_value v) with
                | Some to_, Some amount -> Some (Transfer { to_; amount })
                | _ -> None)
            | `Transfer_from, [ f; a; v ] -> (
                match
                  (address_of_value f, address_of_value a, uint_of_value v)
                with
                | Some from, Some to_, Some amount ->
                    Some (Transfer_from { from; to_; amount })
                | _ -> None)
            | `Approve, [ a; v ] -> (
                match (address_of_value a, uint_of_value v) with
                | Some spender, Some amount ->
                    Some (Approve { spender; amount })
                | _ -> None)
            | `Balance_of, [ a ] -> (
                match address_of_value a with
                | Some owner -> Some (Balance_of { owner })
                | None -> None)
            | _ -> None))

let call_to_ = function
  | Transfer { to_; _ } -> Some to_
  | Transfer_from { to_; _ } -> Some to_
  | Approve { spender; _ } -> Some spender
  | Balance_of _ -> None

let call_amount = function
  | Transfer { amount; _ } | Transfer_from { amount; _ } | Approve { amount; _ }
    ->
      Some amount
  | Balance_of _ -> None

let pp_call ppf = function
  | Transfer { to_; amount } ->
      Format.fprintf ppf "transfer %s to %a" (Z.to_string amount) Address.pp to_
  | Transfer_from { from; to_; amount } ->
      Format.fprintf ppf "transferFrom %s from %a to %a" (Z.to_string amount)
        Address.pp from Address.pp to_
  | Approve { spender; amount } ->
      Format.fprintf ppf "approve %a to spend %s" Address.pp spender
        (Z.to_string amount)
  | Balance_of { owner } -> Format.fprintf ppf "balanceOf %a" Address.pp owner
