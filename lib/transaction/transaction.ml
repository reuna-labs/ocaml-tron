module P = Tron_proto.Tron.Protocol
module Writer = Ocaml_protoc_plugin.Writer
module Reader = Ocaml_protoc_plugin.Reader

type t = { raw_data : Raw_data.t; signatures : Tron_crypto.signature list }

type error =
  [ `Not_signed | `Too_many_signatures | `Signature of Tron_crypto.error ]

let pp_error ppf = function
  | `Not_signed -> Format.pp_print_string ppf "transaction carries no signature"
  | `Too_many_signatures ->
      Format.pp_print_string ppf "more signatures than any permission can hold"
  | `Signature e -> Tron_crypto.pp_error ppf e

(* A Permission holds at most 5 keys, so a transaction needing more than that
   cannot satisfy any threshold and is not worth carrying. The bound exists so
   that decoding an untrusted transaction cannot make us allocate without
   limit. *)
let max_signatures = 5
let of_raw_data raw_data = { raw_data; signatures = [] }
let raw_data t = t.raw_data
let signatures t = t.signatures
let tx_id t = Raw_data.tx_id t.raw_data
let signing_bytes t = Tron_types.Tx_id.to_bytes (tx_id t)

let add_signature t sg =
  if List.length t.signatures >= max_signatures then Error `Too_many_signatures
  else Ok { t with signatures = t.signatures @ [ sg ] }

let sign t key =
  match Tron_crypto.sign_digest key (signing_bytes t) with
  | Error e -> Error (`Signature e)
  | Ok sg -> add_signature t sg

let recover_signers t =
  if t.signatures = [] then Error `Not_signed
  else
    let msg = signing_bytes t in
    Ok
      (List.map
         (fun sg -> Tron_crypto.address_of_signature ~msg sg)
         t.signatures)

(* Wire form *)

let raw_to_proto t =
  match
    P.Transaction.Raw.from_proto (Reader.create (Raw_data.to_bytes t.raw_data))
  with
  | Ok raw -> raw
  (* to_bytes is either bytes we encoded from a validated value or bytes
     of_bytes already decoded once, so this cannot fail. *)
  | Error _ -> assert false

let to_proto t =
  P.Transaction.make ~raw_data:(raw_to_proto t)
    ~signature:
      (List.map
         (fun sg -> Bytes.of_string (Tron_crypto.signature_to_bytes sg))
         t.signatures)
    ()

(* The wire form is assembled by hand, not by re-encoding the model.

   Protobuf permits encodings that decode alike but re-encode differently -- a
   non-repeated scalar appearing twice, a varint with redundant continuation
   bytes, fields out of tag order. Raw_data.of_bytes retains the bytes it
   decoded for exactly that reason, and handing the decoded model back to the
   generated encoder would throw that away: the transaction on the wire would
   have a different raw_data, and therefore a different id, from the one that
   was signed and reviewed. The node would then reject the signature -- or, if
   it did not, would execute something nobody approved.

   Two fields, both length-delimited: raw_data is 1, signature is 2. `ret` is
   deliberately not written; it is the node's field, not the sender's. *)
let varint n =
  let b = Buffer.create 4 in
  let rec go n =
    if n < 0x80 then Buffer.add_char b (Char.chr n)
    else begin
      Buffer.add_char b (Char.chr (n land 0x7f lor 0x80));
      go (n lsr 7)
    end
  in
  go n;
  Buffer.contents b

let delimited tag payload =
  String.make 1 (Char.chr ((tag lsl 3) lor 2))
  ^ varint (String.length payload)
  ^ payload

let to_bytes ?v t =
  let b = Buffer.create 256 in
  Buffer.add_string b (delimited 1 (Raw_data.to_bytes t.raw_data));
  List.iter
    (fun sg ->
      Buffer.add_string b (delimited 2 (Tron_crypto.signature_to_bytes ?v sg)))
    t.signatures;
  Buffer.contents b

let hex_digits = "0123456789abcdef"

let hex s =
  let b = Bytes.create (String.length s * 2) in
  String.iteri
    (fun i c ->
      let c = Char.code c in
      Bytes.set b (i * 2) hex_digits.[c lsr 4];
      Bytes.set b ((i * 2) + 1) hex_digits.[c land 0xf])
    s;
  Bytes.unsafe_to_string b

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

let to_broadcast_hex ?v t = hex (to_bytes ?v t)

type decode_error = [ Raw_data.error | error ]

let pp_decode_error ppf = function
  | #Raw_data.error as e -> Raw_data.pp_error ppf e
  | #error as e -> pp_error ppf e

let ( let* ) = Result.bind

let of_bytes s =
  match
    Proto_decode.protect
      (fun () -> P.Transaction.from_proto (Reader.create s))
      "Transaction"
  with
  | Error _ -> Error (`Malformed "Transaction")
  | Ok (tx : P.Transaction.t) -> (
      match tx.raw_data with
      | None -> Error `No_contract
      | Some raw ->
          (* Re-serialize the raw_data submessage to recover the exact bytes the
             signatures cover. Protobuf allows encodings that differ while
             decoding alike, so this is not guaranteed to reproduce the original
             framing -- but the framing of the submessage is what the sender's
             own txID was taken over, and Raw_data.of_bytes then retains it. *)
          let raw_bytes = Writer.contents (P.Transaction.Raw.to_proto raw) in
          (* Widen Raw_data.error to include ours; the tags are disjoint. *)
          let* raw_data =
            (Raw_data.of_bytes raw_bytes :> (Raw_data.t, decode_error) result)
          in
          if List.length tx.signature > max_signatures then
            Error `Too_many_signatures
          else
            let rec sigs acc = function
              | [] -> Ok (List.rev acc)
              | b :: rest -> (
                  match Tron_crypto.signature_of_bytes (Bytes.to_string b) with
                  | Error e -> Error (`Signature e)
                  | Ok sg -> sigs (sg :: acc) rest)
            in
            let* signatures = sigs [] tx.signature in
            Ok { raw_data; signatures })

let of_broadcast_hex s =
  match unhex s with
  | None -> Error `Invalid_format
  | Some b -> (of_bytes b :> (t, [ decode_error | `Invalid_format ]) result)
