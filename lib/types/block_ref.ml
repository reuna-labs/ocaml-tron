type t = { block_bytes : string; block_hash : string }
type error = [ `Invalid_length | `Mismatch ]

let pp_error ppf = function
  | `Invalid_length ->
      Format.pp_print_string ppf "reference block slice has the wrong width"
  | `Mismatch -> Format.pp_print_string ppf "block number and block id disagree"

let bytes_width = 2
let hash_width = 8
let bytes_offset = 6
let hash_offset = 8

let of_block_id id =
  let id = Tx_id.to_bytes id in
  {
    block_bytes = String.sub id bytes_offset bytes_width;
    block_hash = String.sub id hash_offset hash_width;
  }

let number_be n =
  let b = Bytes.create 8 in
  Bytes.set_int64_be b 0 n;
  Bytes.unsafe_to_string b

let of_block ~number ~id =
  let raw = Tx_id.to_bytes id in
  if String.equal (String.sub raw 0 8) (number_be number) then
    Ok (of_block_id id)
  else Error `Mismatch

let of_slices ~block_bytes ~block_hash =
  if
    String.length block_bytes <> bytes_width
    || String.length block_hash <> hash_width
  then Error `Invalid_length
  else Ok { block_bytes; block_hash }

let block_bytes t = t.block_bytes
let block_hash t = t.block_hash

let equal a b =
  String.equal a.block_bytes b.block_bytes
  && String.equal a.block_hash b.block_hash

let pp ppf t =
  Format.fprintf ppf "%s@%s"
    (Hex_string.to_hex t.block_hash)
    (Hex_string.to_hex t.block_bytes)
