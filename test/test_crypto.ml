(* Every expected value here comes from conformance/fixtures/tronweb-6.5.0.json,
   generated offline by a locked TronWeb. Nothing is compared against
   ocaml-tron's own output. *)

open Tron_types

let fixture = lazy (Fixture.load "../conformance/fixtures/tronweb-6.5.0.json")
let accounts () = Fixture.get_list (Lazy.force fixture) "accounts"
let transactions () = Fixture.get_list (Lazy.force fixture) "transactions"

let unhex h =
  String.init
    (String.length h / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2)))

let hex s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let ok name = function
  | Ok v -> v
  | Error _ -> Alcotest.failf "%s: expected Ok" name

let priv_of acc =
  ok "private key"
    (Tron_crypto.private_key_of_bytes
       (unhex (Fixture.get_str acc "private_key")))

(* Address derivation: private key -> public key -> 21-byte address -> Base58Check.
   TronWeb computed all three. *)
let test_address_derivation () =
  List.iteri
    (fun i acc ->
      let sk = priv_of acc in
      let pk = Tron_crypto.public_key_of_private_key sk in
      Alcotest.(check string)
        (Printf.sprintf "account %d public key" i)
        (Fixture.get_str acc "public_key")
        (hex (Tron_crypto.public_key_to_bytes pk));
      let addr = Tron_crypto.address_of_public_key pk in
      Alcotest.(check string)
        (Printf.sprintf "account %d hex address" i)
        (Fixture.get_str acc "address_hex")
        (Address.to_hex addr);
      Alcotest.(check string)
        (Printf.sprintf "account %d base58check address" i)
        (Fixture.get_str acc "address_base58")
        (Address.to_base58check addr);
      Alcotest.(check bool)
        (Printf.sprintf "account %d address_of_private_key agrees" i)
        true
        (Address.equal addr (Tron_crypto.address_of_private_key sk)))
    (accounts ())

(* TronWeb's signatures must verify and must recover to the signing address. *)
let test_verify_oracle_signatures () =
  let accs = accounts () in
  List.iter
    (fun tx ->
      let name = Fixture.get_str tx "name" in
      let digest = unhex (Fixture.get_str tx "txID") in
      List.iteri
        (fun i sig_hex ->
          let sg =
            ok (name ^ " signature")
              (Tron_crypto.signature_of_bytes (unhex sig_hex))
          in
          let signer = List.nth accs i in
          let pk =
            ok "public key"
              (Tron_crypto.public_key_of_bytes
                 (unhex (Fixture.get_str signer "public_key")))
          in
          Alcotest.(check bool)
            (Printf.sprintf "%s signature %d verifies" name i)
            true
            (Tron_crypto.verify pk digest sg);
          let recovered =
            ok "recover" (Tron_crypto.address_of_signature ~msg:digest sg)
          in
          Alcotest.(check string)
            (Printf.sprintf "%s signature %d recovers to signer" name i)
            (Fixture.get_str signer "address_hex")
            (Address.to_hex recovered))
        (Fixture.strings (Fixture.field tx "signatures")))
    (transactions ())

(* And our own signatures must equal TronWeb's byte for byte. RFC 6979 makes
   ECDSA deterministic, so "equal" is a meaningful claim rather than a
   coincidence -- but only once the v-byte convention matches, which is why
   `Eth_offset is named explicitly here. *)
let test_sign_matches_oracle () =
  let accs = accounts () in
  List.iter
    (fun tx ->
      let name = Fixture.get_str tx "name" in
      let digest = unhex (Fixture.get_str tx "txID") in
      List.iteri
        (fun i expected ->
          let sk = priv_of (List.nth accs i) in
          let sg = ok (name ^ " sign") (Tron_crypto.sign_digest sk digest) in
          Alcotest.(check string)
            (Printf.sprintf "%s signature %d is byte-identical to TronWeb" name
               i)
            (String.lowercase_ascii expected)
            (hex (Tron_crypto.signature_to_bytes ~v:`Eth_offset sg));
          Alcotest.(check bool)
            (Printf.sprintf "%s signature %d is low-S" name i)
            true
            (Tron_crypto.is_canonical sg))
        (Fixture.strings (Fixture.field tx "signatures")))
    (transactions ())

(* TronWeb writes recid + 27; trident and most of mainnet write the recid.
   Decoding must be indifferent, and the two spellings must be the same
   signature. *)
let test_v_byte_conventions () =
  let tx = List.hd (transactions ()) in
  let digest = unhex (Fixture.get_str tx "txID") in
  let eth_form =
    unhex (List.hd (Fixture.strings (Fixture.field tx "signatures")))
  in
  let sg = ok "decode eth form" (Tron_crypto.signature_of_bytes eth_form) in
  Alcotest.(check int)
    "normalised to a recovery id" 0
    (if Tron_crypto.recovery_id sg <= 1 then 0 else 1);
  let recid_form = Tron_crypto.signature_to_bytes ~v:`Recovery_id sg in
  Alcotest.(check int) "still 65 bytes" 65 (String.length recid_form);
  Alcotest.(check int)
    "v is now the raw recovery id"
    (Tron_crypto.recovery_id sg)
    (Char.code recid_form.[64]);
  let sg' =
    ok "decode recid form" (Tron_crypto.signature_of_bytes recid_form)
  in
  Alcotest.(check string) "same r" (Tron_crypto.r sg) (Tron_crypto.r sg');
  Alcotest.(check string) "same s" (Tron_crypto.s sg) (Tron_crypto.s sg');
  Alcotest.(check int)
    "same recid"
    (Tron_crypto.recovery_id sg)
    (Tron_crypto.recovery_id sg');
  (* Default is the recovery id, not the offset. *)
  Alcotest.(check string)
    "default encoding is `Recovery_id" recid_form
    (Tron_crypto.signature_to_bytes sg);
  (* Both spellings recover to the same key. *)
  let a = ok "a" (Tron_crypto.address_of_signature ~msg:digest sg)
  and b = ok "b" (Tron_crypto.address_of_signature ~msg:digest sg') in
  Alcotest.(check bool) "same signer" true (Address.equal a b)

let test_signature_rejections () =
  let tx = List.hd (transactions ()) in
  let good =
    unhex (List.hd (Fixture.strings (Fixture.field tx "signatures")))
  in
  let with_v v = String.sub good 0 64 ^ String.make 1 (Char.chr v) in
  List.iter
    (fun v ->
      Alcotest.(check bool)
        (Printf.sprintf "v = %d rejected" v)
        true
        (Result.is_error (Tron_crypto.signature_of_bytes (with_v v))))
    [ 2; 3; 26; 29; 37; 45; 255 ];
  List.iter
    (fun v ->
      Alcotest.(check bool)
        (Printf.sprintf "v = %d accepted" v)
        true
        (Result.is_ok (Tron_crypto.signature_of_bytes (with_v v))))
    [ 0; 1; 27; 28 ];
  Alcotest.(check bool)
    "64 bytes rejected" true
    (Result.is_error (Tron_crypto.signature_of_bytes (String.sub good 0 64)));
  Alcotest.(check bool)
    "66 bytes rejected" true
    (Result.is_error (Tron_crypto.signature_of_bytes (good ^ "\x00")));
  (* r = 0 is not a valid scalar and must not decode. *)
  Alcotest.(check bool)
    "zero r rejected" true
    (Result.is_error
       (Tron_crypto.signature_of_bytes
          (String.make 32 '\x00' ^ String.sub good 32 33)))

let test_digest_length_enforced () =
  let sk = priv_of (List.hd (accounts ())) in
  List.iter
    (fun len ->
      Alcotest.(check bool)
        (Printf.sprintf "%d-byte digest refused" len)
        true
        (Result.is_error (Tron_crypto.sign_digest sk (String.make len '\x00'))))
    [ 0; 20; 31; 33; 64 ]

let test_key_rejections () =
  Alcotest.(check bool)
    "zero scalar rejected" true
    (Result.is_error (Tron_crypto.private_key_of_bytes (String.make 32 '\x00')));
  Alcotest.(check bool)
    "all-ones scalar (above n) rejected" true
    (Result.is_error (Tron_crypto.private_key_of_bytes (String.make 32 '\xff')));
  Alcotest.(check bool)
    "31-byte key rejected" true
    (Result.is_error (Tron_crypto.private_key_of_bytes (String.make 31 '\x01')))

let () =
  Alcotest.run "tron-crypto"
    [
      ( "address",
        [
          Alcotest.test_case "derivation matches TronWeb" `Quick
            test_address_derivation;
        ] );
      ( "signing",
        [
          Alcotest.test_case "TronWeb signatures verify and recover" `Quick
            test_verify_oracle_signatures;
          Alcotest.test_case "our signatures equal TronWeb's" `Quick
            test_sign_matches_oracle;
          Alcotest.test_case "digest length enforced" `Quick
            test_digest_length_enforced;
        ] );
      ( "wire",
        [
          Alcotest.test_case "both v conventions" `Quick test_v_byte_conventions;
          Alcotest.test_case "rejections" `Quick test_signature_rejections;
        ] );
      ("keys", [ Alcotest.test_case "rejections" `Quick test_key_rejections ]);
    ]
