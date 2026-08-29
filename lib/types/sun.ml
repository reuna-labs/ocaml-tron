type t = int64
type error = [ `Overflow of string | `Invalid_range | `Invalid_format ]

let pp_error ppf = function
  | `Overflow op -> Format.fprintf ppf "%s overflowed the sun range" op
  | `Invalid_range -> Format.pp_print_string ppf "negative amount"
  | `Invalid_format -> Format.pp_print_string ppf "not an exact TRX figure"

let zero = 0L
let sun_per_trx = 1_000_000L
let decimals = 6
let of_sun n = if Int64.compare n 0L < 0 then Error `Invalid_range else Ok n
let to_sun t = t

let of_sun_exn n =
  match of_sun n with
  | Ok t -> t
  | Error e -> Format.kasprintf invalid_arg "Sun.of_sun_exn: %a" pp_error e

(* Decimal conversion, integer-only. The fractional part is parsed as its own
   integer and scaled, so no value ever passes through a float. *)

let of_trx_string s =
  let whole, frac =
    match String.index_opt s '.' with
    | None -> (s, "")
    | Some i ->
        (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
  in
  let all_digits str =
    str <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) str
  in
  if not (all_digits whole) then Error `Invalid_format
  else if frac <> "" && not (all_digits frac) then Error `Invalid_format
  else if String.length frac > decimals then Error `Invalid_format
  else
    let padded = frac ^ String.make (decimals - String.length frac) '0' in
    match (Int64.of_string_opt whole, Int64.of_string_opt ("0" ^ padded)) with
    | Some w, Some f ->
        let scaled = Int64.mul w sun_per_trx in
        if
          Int64.compare w 0L < 0
          || Int64.compare scaled 0L < 0
          || Int64.compare (Int64.div scaled sun_per_trx) w <> 0
        then Error (`Overflow "of_trx_string")
        else
          let total = Int64.add scaled f in
          if Int64.compare total scaled < 0 then
            Error (`Overflow "of_trx_string")
          else Ok total
    | _ -> Error `Invalid_format

let to_trx_string t =
  let whole = Int64.div t sun_per_trx and frac = Int64.rem t sun_per_trx in
  if Int64.equal frac 0L then Int64.to_string whole
  else begin
    let f = Printf.sprintf "%06Ld" frac in
    let last = ref (String.length f) in
    while !last > 1 && f.[!last - 1] = '0' do
      decr last
    done;
    Printf.sprintf "%Ld.%s" whole (String.sub f 0 !last)
  end

(* Arithmetic. Int64 wraps silently, so every operation checks after the fact
   using a property the wrapped result cannot satisfy. *)

let add a b =
  let s = Int64.add a b in
  if Int64.compare s a < 0 then Error (`Overflow "add") else Ok s

let sub a b =
  if Int64.compare a b < 0 then Error `Invalid_range else Ok (Int64.sub a b)

let mul a n =
  if n < 0 then Error `Invalid_range
  else if Int64.equal a 0L || n = 0 then Ok 0L
  else
    let n64 = Int64.of_int n in
    let p = Int64.mul a n64 in
    if Int64.compare p 0L < 0 || not (Int64.equal (Int64.div p n64) a) then
      Error (`Overflow "mul")
    else Ok p

let sum l =
  List.fold_left (fun acc x -> Result.bind acc (fun a -> add a x)) (Ok zero) l

let compare = Int64.compare
let equal = Int64.equal
let min a b = if compare a b <= 0 then a else b
let max a b = if compare a b >= 0 then a else b
let pp ppf t = Format.fprintf ppf "%s TRX" (to_trx_string t)
