type t = Yojson.Safe.t
type 'a decoder = t -> ('a, string) result

let field name = function `Assoc kvs -> List.assoc_opt name kvs | _ -> None
let missing name = Error (Printf.sprintf "missing or malformed field %S" name)

let string_field name j =
  match field name j with Some (`String s) -> Ok s | _ -> missing name

let int64_field name j =
  match field name j with
  | Some (`Int n) -> Ok (Int64.of_int n)
  | Some (`Intlit s) -> (
      match Int64.of_string_opt s with Some n -> Ok n | None -> missing name)
  | _ -> missing name

let opt_int64_field name j =
  match int64_field name j with Ok n -> n | Error _ -> 0L

let bool_field name j =
  match field name j with Some (`Bool b) -> b | _ -> false

let list_field name j =
  match field name j with Some (`List l) -> Ok l | _ -> missing name

let unhex s =
  let nibble = function
    | '0' .. '9' as c -> Some (Char.code c - 48)
    | 'a' .. 'f' as c -> Some (Char.code c - 87)
    | 'A' .. 'F' as c -> Some (Char.code c - 55)
    | _ -> None
  in
  let n = String.length s in
  if n land 1 <> 0 then None
  else
    let b = Bytes.create (n / 2) in
    let rec go i =
      if i * 2 >= n then Some (Bytes.unsafe_to_string b)
      else
        match (nibble s.[i * 2], nibble s.[(i * 2) + 1]) with
        | Some hi, Some lo ->
            Bytes.set b i (Char.chr ((hi lsl 4) lor lo));
            go (i + 1)
        | _ -> None
    in
    go 0

let hex_field name j =
  match string_field name j with
  | Error e -> Error e
  | Ok s -> (
      match unhex s with
      | Some b -> Ok b
      | None -> Error (Printf.sprintf "field %S is not hex" name))

let error_of j =
  match field "Error" j with
  | None -> None
  | Some (`String raw) ->
      let message = match unhex raw with Some m -> m | None -> raw in
      let code =
        match string_field "code" j with Ok c -> c | Error _ -> "ERROR"
      in
      Some (code, message)
  | Some other -> Some ("ERROR", Yojson.Safe.to_string other)

let address_field name j =
  match string_field name j with
  | Error e -> Error e
  | Ok s -> (
      (* Either rendering: which one arrives depends on the request's `visible`
         flag. Hex is tried first because it is the default. *)
      match Tron_types.Address.of_hex s with
      | Ok a -> Ok a
      | Error _ -> (
          match Tron_types.Address.of_base58check s with
          | Ok a -> Ok a
          | Error _ -> Error (Printf.sprintf "field %S is not an address" name))
      )

let tx_id_field name j =
  match string_field name j with
  | Error e -> Error e
  | Ok s -> (
      match Tron_types.Tx_id.of_hex s with
      | Ok h -> Ok h
      | Error _ ->
          Error (Printf.sprintf "field %S is not a 32-byte digest" name))

let sun_field name j =
  match int64_field name j with
  | Error e -> Error e
  | Ok n -> (
      match Tron_types.Sun.of_sun n with
      | Ok v -> Ok v
      | Error _ -> Error (Printf.sprintf "field %S is not a valid amount" name))
