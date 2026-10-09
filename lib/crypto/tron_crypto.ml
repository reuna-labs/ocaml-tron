module Hardened = Mirage_crypto_secp256k1
module Reference = Mirage_crypto_secp256k1

type private_key = Hardened.priv
type public_key = Hardened.pub
type signature = { r : string; s : string; recid : int }

type error =
  [ `Invalid_key of string
  | `Invalid_digest
  | `Invalid_signature
  | `Recovery_failed ]

let pp_error ppf = function
  | `Invalid_key s -> Format.fprintf ppf "invalid secp256k1 %s" s
  | `Invalid_digest -> Format.pp_print_string ppf "digest must be 32 bytes"
  | `Invalid_signature -> Format.pp_print_string ppf "malformed signature"
  | `Recovery_failed -> Format.pp_print_string ppf "public-key recovery failed"

let digest_length = 32
let scalar_length = 32
let wire_length = 65

(* Keys *)

let private_key_of_bytes b =
  match Hardened.priv_of_octets b with
  | Ok k -> Ok k
  | Error _ -> Error (`Invalid_key "private key")
  | exception _ -> Error (`Invalid_key "private key")

let public_key_of_bytes b =
  (* pub_of_octets returns a result and also raises: a short buffer whose first
     byte announces a compressed point sends decompress past the end, and
     String.sub raises Invalid_argument. Public keys arrive from the wire, and
     this function's type says it returns a result, so the promise is kept here
     rather than assumed. Found by fuzz/fuzz_signature.ml. *)
  match Hardened.pub_of_octets b with
  | Ok k -> Ok k
  | Error _ -> Error (`Invalid_key "public key")
  | exception _ -> Error (`Invalid_key "public key")

let public_key_to_bytes ?(compress = false) k =
  Hardened.pub_to_octets ~compress k

let public_key_of_private_key key = Hardened.pub_of_priv key

let address_of_public_key k =
  (* The uncompressed SEC1 encoding is 0x04 ‖ x ‖ y. Tron hashes x ‖ y, so the
     prefix comes off first -- keeping it would shift every byte of the
     digest. *)
  let xy = String.sub (public_key_to_bytes ~compress:false k) 1 64 in
  let h = Digestif.KECCAK_256.(to_raw_string (digest_string xy)) in
  (* of_hash20 cannot fail on a 32-byte digest's last 20 bytes. *)
  Result.get_ok (Tron_types.Address.of_hash20 (String.sub h 12 20))

let address_of_private_key k =
  address_of_public_key (public_key_of_private_key k)

(* Signing *)

let half_curve_order =
  "\x7f\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x5d\x57\x6e\x73\x57\xa4\x50\x1d\xdf\xe9\x2f\x46\x68\x1b\x20\xa0"

let reference_signature { r; s; _ } =
  match Reference.signature_of_octets (r ^ s) with
  | Ok sg -> Ok sg
  | Error _ -> Error `Invalid_signature
  | exception _ -> Error `Invalid_signature

let recover ~msg sg =
  if String.length msg <> digest_length then Error `Invalid_digest
  else
    match reference_signature sg with
    | Error _ -> Error `Recovery_failed
    | Ok reference -> (
        match Reference.recover ~msg reference ~recid:sg.recid with
        | Error _ -> Error `Recovery_failed
        | exception _ -> Error `Recovery_failed
        | Ok point -> Ok point)

let sign_digest key digest =
  if String.length digest <> digest_length then Error `Invalid_digest
  else
    let signature, recid = Hardened.sign_recoverable ~key digest in
    if recid > 1 then Error `Recovery_failed
    else
      let bytes = Hardened.signature_to_octets signature in
      Ok { r = String.sub bytes 0 32; s = String.sub bytes 32 32; recid }

let verify key digest { r; s; _ } =
  match Hardened.signature_of_octets (r ^ s) with
  | Error _ -> false
  | Ok signature -> Hardened.verify ~key signature digest

let address_of_signature ~msg sg =
  Result.map address_of_public_key (recover ~msg sg)

(* Wire form *)

type v_encoding = [ `Recovery_id | `Eth_offset ]

(* java-tron adds 27 to any v below it before recovering, so both forms verify.
   See tron_crypto.mli for the on-chain evidence. *)
let eth_v_offset = 27

let signature_to_bytes ?(v = `Recovery_id) { r; s; recid } =
  let byte =
    match v with `Recovery_id -> recid | `Eth_offset -> recid + eth_v_offset
  in
  r ^ s ^ String.make 1 (Char.chr byte)

let signature_of_bytes b =
  if String.length b <> wire_length then Error `Invalid_signature
  else
    let raw_v = Char.code b.[wire_length - 1] in
    let recid =
      if raw_v <= 1 then raw_v
      else if raw_v = eth_v_offset || raw_v = eth_v_offset + 1 then
        raw_v - eth_v_offset
      else -1
    in
    (* EIP-155's recid + 35 + 2 * chain_id lands here. Accepting it would defer
       the failure to recovery, which reports it as an unrelated curve error. *)
    if recid < 0 then Error `Invalid_signature
    else
      let r = String.sub b 0 scalar_length in
      let s = String.sub b scalar_length scalar_length in
      let sg = { r; s; recid } in
      (* Reject scalars out of range now, while the caller still has context. *)
      match reference_signature sg with
      | Error e -> Error e
      | Ok _ -> Ok sg

let is_canonical { s; _ } = String.compare s half_curve_order <= 0
let v_byte { recid; _ } = recid
let r { r; _ } = r
let s { s; _ } = s
let recovery_id { recid; _ } = recid
