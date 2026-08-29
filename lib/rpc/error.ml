type t =
  | Transport of string
  | Http of int * string
  | Malformed_json of string
  | Invalid_response of string
  | Node of { code : string; message : string }

let pp ppf = function
  | Transport s -> Format.fprintf ppf "transport failure: %s" s
  | Http (code, s) -> Format.fprintf ppf "HTTP %d: %s" code s
  | Malformed_json s -> Format.fprintf ppf "malformed JSON: %s" s
  | Invalid_response s -> Format.fprintf ppf "unusable response: %s" s
  | Node { code; message } ->
      Format.fprintf ppf "node error %s: %s" code message

let to_string t = Format.asprintf "%a" pp t
