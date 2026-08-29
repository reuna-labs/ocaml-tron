type t = string
type error = [ `Invalid_length | `Invalid_format ]

let pp_error ppf = function
  | `Invalid_length -> Format.pp_print_string ppf "digest must be 32 bytes"
  | `Invalid_format -> Format.pp_print_string ppf "not hex"

let length = 32

let of_bytes s =
  if String.length s <> length then Error `Invalid_length else Ok s

let to_bytes t = t

let of_bytes_exn s =
  match of_bytes s with
  | Ok t -> t
  | Error e -> Format.kasprintf invalid_arg "Tx_id.of_bytes_exn: %a" pp_error e

let of_hex s =
  match Hex_string.of_hex s with
  | None -> Error `Invalid_format
  | Some b -> of_bytes b

let to_hex t = Hex_string.to_hex t
let equal = String.equal
let compare = String.compare
let pp ppf t = Format.pp_print_string ppf (to_hex t)
