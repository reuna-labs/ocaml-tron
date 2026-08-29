type t = string

type error =
  [ `Invalid_length | `Invalid_prefix | `Invalid_checksum | `Invalid_format ]

let pp_error ppf = function
  | `Invalid_length -> Format.pp_print_string ppf "wrong length for an address"
  | `Invalid_prefix -> Format.pp_print_string ppf "address prefix is not 0x41"
  | `Invalid_checksum ->
      Format.pp_print_string ppf "base58check checksum mismatch"
  | `Invalid_format -> Format.pp_print_string ppf "undecodable address"

let prefix = '\x41'
let length = 21
let hash_length = 20
let abi_word_length = 32

let of_bytes s =
  if String.length s <> length then Error `Invalid_length
  else if s.[0] <> prefix then Error `Invalid_prefix
  else Ok s

let to_bytes t = t

let of_bytes_exn s =
  match of_bytes s with
  | Ok t -> t
  | Error e ->
      Format.kasprintf invalid_arg "Address.of_bytes_exn: %a" pp_error e

let of_hash20 s =
  if String.length s <> hash_length then Error `Invalid_length
  else Ok (String.make 1 prefix ^ s)

let to_hash20 t = String.sub t 1 hash_length

(* Base58Check *)

let of_base58check s =
  match Web3_codec_base58.decode_check s with
  | Error _ -> (
      (* decode_check folds "bad checksum" and "not base58 at all" into one
         string. Separating them costs a second decode and tells an attacker
         nothing useful, so both report as a checksum failure unless the
         payload decoded and was simply the wrong shape. *)
      match Web3_codec_base58.decode s with
      | Ok _ -> Error `Invalid_checksum
      | Error _ -> Error `Invalid_format)
  | Ok payload -> of_bytes payload

let to_base58check t = Web3_codec_base58.encode_check t

(* Hex *)

let of_hex s =
  match Hex_string.of_hex s with
  | None -> Error `Invalid_format
  | Some b -> of_bytes b

let to_hex t = Hex_string.to_hex t

(* Contract ABI *)

let to_abi_word t =
  String.make (abi_word_length - hash_length) '\x00' ^ to_hash20 t

let of_abi_word w =
  if String.length w <> abi_word_length then Error `Invalid_length
  else of_hash20 (String.sub w (abi_word_length - hash_length) hash_length)

(* Comparison *)

let equal = String.equal
let compare = String.compare
let pp ppf t = Format.pp_print_string ppf (to_base58check t)
