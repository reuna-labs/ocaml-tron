module P = Tron_proto.Tron.Protocol
module Address = Tron_types.Address

type key = { address : Address.t; weight : int64 }
type kind = Owner | Witness | Active

type t = {
  kind : kind;
  id : int;
  name : string;
  threshold : int64;
  operations : string;
  keys : key list;
}

type error =
  [ `Invalid_operations_length of int
  | `Invalid_kind of int
  | `Invalid_id of int
  | `Invalid_field of string ]

let pp_error ppf = function
  | `Invalid_operations_length n ->
      Format.fprintf ppf "operations bitmap is %d bytes, expected 32" n
  | `Invalid_kind n -> Format.fprintf ppf "unknown permission type %d" n
  | `Invalid_id n -> Format.fprintf ppf "permission id %d out of range" n
  | `Invalid_field f -> Format.fprintf ppf "invalid %s" f

let operations_length = 32
let max_id = 9

let kind_of_proto = function
  | P.Permission.PermissionType.Owner -> Ok Owner
  | P.Permission.PermissionType.Witness -> Ok Witness
  | P.Permission.PermissionType.Active -> Ok Active

let ( let* ) = Result.bind

let of_proto (p : P.Permission.t) =
  let* kind = kind_of_proto p.type' in
  let* () =
    if p.id < 0 || p.id > max_id then Error (`Invalid_id p.id) else Ok ()
  in
  let operations = Bytes.to_string p.operations in
  let* () =
    (* Owner and witness permissions carry no bitmap; an active one must carry
       a full 32 bytes, because a short bitmap would silently read as "this
       contract type is not authorised" for every type past its end. *)
    match kind with
    | Active when String.length operations <> operations_length ->
        Error (`Invalid_operations_length (String.length operations))
    | _ -> Ok ()
  in
  let rec keys acc = function
    | [] -> Ok (List.rev acc)
    | (k : P.Key.t) :: rest -> (
        match Address.of_bytes (Bytes.to_string k.address) with
        | Error _ -> Error (`Invalid_field "key address")
        | Ok address -> keys ({ address; weight = k.weight } :: acc) rest)
  in
  let* keys = keys [] p.keys in
  Ok
    {
      kind;
      id = p.id;
      name = p.permission_name;
      threshold = p.threshold;
      operations;
      keys;
    }

let allows t ct =
  match t.kind with
  | Owner | Witness -> true
  | Active ->
      let n = P.Transaction.Contract.ContractType.to_int ct in
      let byte = n / 8 and bit = n land 7 in
      byte < String.length t.operations
      && Char.code t.operations.[byte] land (1 lsl bit) <> 0

let weight_of t address =
  match List.find_opt (fun k -> Address.equal k.address address) t.keys with
  | Some k -> k.weight
  | None -> 0L

let total_weight t signers =
  (* Deduplicate: the same key signing twice must not count twice, or a
     threshold of 2 would be reachable by one key. *)
  let seen = ref [] in
  List.fold_left
    (fun acc a ->
      if List.exists (Address.equal a) !seen then acc
      else begin
        seen := a :: !seen;
        Int64.add acc (weight_of t a)
      end)
    0L signers

let meets_threshold t signers =
  Int64.compare (total_weight t signers) t.threshold >= 0

let pp_kind ppf = function
  | Owner -> Format.pp_print_string ppf "owner"
  | Witness -> Format.pp_print_string ppf "witness"
  | Active -> Format.pp_print_string ppf "active"

let pp ppf t =
  Format.fprintf ppf "@[<v 2>%a permission %d %S (threshold %Ld)" pp_kind t.kind
    t.id t.name t.threshold;
  List.iter
    (fun k ->
      Format.fprintf ppf "@,%a weight %Ld" Address.pp k.address k.weight)
    t.keys;
  Format.fprintf ppf "@]"
