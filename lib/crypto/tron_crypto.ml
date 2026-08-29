(* Hardened: fiat-crypto, constant time. The only backend a private key is
   handed to. Reference: plain double-and-add, documented NOT CONSTANT TIME in
   its own .mli, used only on public data. See dune. *)
module Hardened = Mirage_crypto_ec.P256k1.Dsa
module Reference = Mirage_crypto_blockchain.Secp256k1

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

let public_key_of_private_key = Hardened.pub_of_priv

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

let curve_order = Reference.n
let half_curve_order = Z.div Reference.n (Z.of_int 2)

let z_of_be s =
  Z.of_bits
    (String.init (String.length s) (fun i -> s.[String.length s - 1 - i]))

let be_of_z z =
  let bits = Z.to_bits z in
  let n = String.length bits in
  String.init scalar_length (fun i ->
      let j = scalar_length - 1 - i in
      if j < n then bits.[j] else '\x00')

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
        | Ok point ->
            public_key_of_bytes
              (Reference.point_to_octets ~compress:false point))

let public_key_equal a b =
  String.equal (public_key_to_bytes a) (public_key_to_bytes b)

let sign_digest key digest =
  if String.length digest <> digest_length then Error `Invalid_digest
  else
    (* No ~k: the hardened backend derives it deterministically per RFC 6979. *)
    let r_raw, s_raw = Hardened.sign ~key digest in
    let s0 = z_of_be s_raw in
    (* Low-S normalisation. java-tron's ECKey rejects the high-S form, and a
       signature that differs only in this is a different 65 bytes over the
       same transaction -- malleability. *)
    let s = if Z.gt s0 half_curve_order then Z.sub curve_order s0 else s0 in
    let candidate = { r = r_raw; s = be_of_z s; recid = 0 } in
    let expected = public_key_of_private_key key in
    (* The constant-time backend does not expose the ephemeral nonce, so the
       recovery id is found by trying both and keeping the one that recovers to
       the key that signed. Only 0 and 1 are tried: 2 and 3 require the
       ephemeral point's x-coordinate to have exceeded the curve order, which
       has probability around 2^-128. *)
    let rec find = function
      | [] -> Error `Recovery_failed
      | recid :: rest -> (
          let sg = { candidate with recid } in
          match recover ~msg:digest sg with
          | Ok recovered when public_key_equal recovered expected -> Ok sg
          | _ -> find rest)
    in
    find [ 0; 1 ]

let verify key digest { r; s; _ } =
  String.length digest = digest_length
  && try Hardened.verify ~key (r, s) digest with _ -> false

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

let is_canonical { s; _ } = Z.leq (z_of_be s) half_curve_order
let v_byte { recid; _ } = recid
let r { r; _ } = r
let s { s; _ } = s
let recovery_id { recid; _ } = recid
