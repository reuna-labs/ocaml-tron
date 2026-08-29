module P = Tron_proto.Tron.Protocol
module Writer = Ocaml_protoc_plugin.Writer
module Reader = Ocaml_protoc_plugin.Reader
module Block_ref = Tron_types.Block_ref
module Sun = Tron_types.Sun

(* The decoded contract, plus the bytes this came from when it came from
   somewhere. See of_bytes in the .mli for why the source bytes are kept. *)
type t = {
  contract : Contract.t;
  block_ref : Block_ref.t;
  expiration : int64;
  timestamp : int64;
  permission_id : int;
  fee_limit : Sun.t option;
  memo : string;
  source : string option;
}

type error =
  [ `No_contract
  | `Too_many_contracts
  | `Unencodable_contract
  | `Invalid_permission_id of int
  | Contract.error ]

let pp_error ppf = function
  | `No_contract -> Format.pp_print_string ppf "transaction carries no contract"
  | `Too_many_contracts ->
      Format.pp_print_string ppf "transaction carries more than one contract"
  | `Unencodable_contract ->
      Format.pp_print_string ppf "an unrecognised contract cannot be re-encoded"
  | `Invalid_permission_id n ->
      Format.fprintf ppf "permission id %d is not usable here" n
  | #Contract.error as e -> Contract.pp_error ppf e

let witness_permission_id = 1
let max_permission_id = 9

let encode t =
  let raw =
    P.Transaction.Raw.make
      ~ref_block_bytes:(Bytes.of_string (Block_ref.block_bytes t.block_ref))
      ~ref_block_hash:(Bytes.of_string (Block_ref.block_hash t.block_ref))
      ~expiration:t.expiration ~timestamp:t.timestamp
      ~data:(Bytes.of_string t.memo)
      ~fee_limit:(match t.fee_limit with None -> 0L | Some f -> Sun.to_sun f)
      ~contract:[ Contract.to_proto ~permission_id:t.permission_id t.contract ]
      ()
  in
  Writer.contents (P.Transaction.Raw.to_proto raw)

let make ~block_ref ~expiration ~timestamp ?(permission_id = 0) ?fee_limit
    ?(memo = "") contract =
  match contract with
  | Contract.Unknown _ -> Error `Unencodable_contract
  | _ ->
      if
        permission_id = witness_permission_id
        || permission_id < 0
        || permission_id > max_permission_id
      then Error (`Invalid_permission_id permission_id)
      else
        Ok
          {
            contract;
            block_ref;
            expiration;
            timestamp;
            permission_id;
            fee_limit;
            memo;
            source = None;
          }

let to_bytes t = match t.source with Some s -> s | None -> encode t
let ( let* ) = Result.bind

let of_bytes s =
  match
    Proto_decode.protect
      (fun () -> P.Transaction.Raw.from_proto (Reader.create s))
      "Transaction.raw"
  with
  | Error _ -> Error (`Malformed "Transaction.raw")
  | Ok (raw : P.Transaction.Raw.t) -> (
      match raw.contract with
      | [] -> Error `No_contract
      (* java-tron's own comment on the field says "only support size = 1,
         repeated list here for extension". A transaction with two contracts is
         not something the chain will accept, and guessing which one a policy
         should describe is worse than refusing. *)
      | _ :: _ :: _ -> Error `Too_many_contracts
      | [ c ] ->
          (* Widen Contract.error into ours; the tags are disjoint. *)
          let* contract = (Contract.of_proto c :> (Contract.t, error) result) in
          let* block_ref =
            match
              Block_ref.of_slices
                ~block_bytes:(Bytes.to_string raw.ref_block_bytes)
                ~block_hash:(Bytes.to_string raw.ref_block_hash)
            with
            | Ok r -> Ok r
            | Error _ -> Error (`Invalid_field "reference block")
          in
          let* fee_limit =
            if Int64.equal raw.fee_limit 0L then Ok None
            else
              match Sun.of_sun raw.fee_limit with
              | Ok f -> Ok (Some f)
              | Error _ -> Error (`Invalid_field "fee_limit")
          in
          Ok
            {
              contract;
              block_ref;
              expiration = raw.expiration;
              timestamp = raw.timestamp;
              permission_id = c.permission_id;
              fee_limit;
              memo = Bytes.to_string raw.data;
              source = Some s;
            })

let contract t = t.contract
let block_ref t = t.block_ref
let expiration t = t.expiration
let timestamp t = t.timestamp
let permission_id t = t.permission_id
let fee_limit t = t.fee_limit
let memo t = t.memo

let tx_id t =
  (* SHA-256, not Keccak-256. See the .mli. *)
  Result.get_ok
    (Tron_types.Tx_id.of_bytes
       Digestif.SHA256.(to_raw_string (digest_string (to_bytes t))))
