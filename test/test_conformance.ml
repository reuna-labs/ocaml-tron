(* Where the two oracles agree, ocaml-tron must match both. Where they
   disagree, the disagreement is recorded here as an assertion rather than
   resolved silently by picking a favourite.

   This is the discipline ocaml-solana adopted for the Kit/Agave legacy
   account-ordering split: a divergence hidden behind one self-generated
   fixture is a divergence nobody will notice changing. *)

open Tron_types
open Tron_transaction
module F = Fixture_conf

let tronweb = lazy (F.load "../conformance/fixtures/tronweb-6.5.0.json")
let trident = lazy (F.load "../conformance/fixtures/trident-1.0.0.json")
let txs f = F.get_list (Lazy.force f) "transactions"
let accounts f = F.get_list (Lazy.force f) "accounts"

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

let lower = String.lowercase_ascii
let names () = List.map (fun t -> F.get_str t "name") (txs tronweb)
let paired name = (F.find (txs tronweb) ~name, F.find (txs trident) ~name)

(* Both oracles must cover the same ground, or "they agree" is a weaker claim
   than it sounds. *)
let test_same_cases () =
  let a = List.sort compare (names ()) in
  let b =
    List.sort compare (List.map (fun t -> F.get_str t "name") (txs trident))
  in
  Alcotest.(check (list string)) "both oracles cover the same cases" a b;
  Alcotest.(check bool) "and there are some" true (List.length a >= 5)

(* The signed bytes. This is the claim that matters: two independent
   implementations, one JavaScript and one Java, and ocaml-tron, all produce
   the same protobuf serialization and the same SHA-256 over it. *)
let test_raw_data_and_txid_agree () =
  List.iter
    (fun name ->
      let a, b = paired name in
      Alcotest.(check string)
        (name ^ ": raw_data agrees across oracles")
        (lower (F.get_str a "raw_data_hex"))
        (lower (F.get_str b "raw_data_hex"));
      Alcotest.(check string)
        (name ^ ": txID agrees across oracles")
        (lower (F.get_str a "txID"))
        (lower (F.get_str b "txID"));
      (* And ocaml-tron decodes those bytes to the same id, which is the only
         way the agreement is worth anything to this library. *)
      let raw =
        ok "decode" (Raw_data.of_bytes (unhex (F.get_str a "raw_data_hex")))
      in
      Alcotest.(check string)
        (name ^ ": ocaml-tron agrees too")
        (lower (F.get_str a "txID"))
        (Tx_id.to_hex (Raw_data.tx_id raw)))
    (names ())

(* Addresses agree. Public keys differ only in the SEC1 prefix: TronWeb emits
   the 65-byte uncompressed form with its leading 0x04, trident emits the
   64 bytes after it. That is a representational difference, not a
   disagreement, and saying so here stops it being rediscovered. *)
let test_accounts_agree () =
  List.iter2
    (fun a b ->
      Alcotest.(check string)
        "hex address"
        (lower (F.get_str a "address_hex"))
        (lower (F.get_str b "address_hex"));
      Alcotest.(check string)
        "base58check address"
        (F.get_str a "address_base58")
        (F.get_str b "address_base58");
      let tw_pub = lower (F.get_str a "public_key") in
      let td_pub = lower (F.get_str b "public_key") in
      Alcotest.(check int) "tronweb emits 65 bytes" 130 (String.length tw_pub);
      Alcotest.(check int) "trident emits 64" 128 (String.length td_pub);
      Alcotest.(check string)
        "tronweb's is trident's with the SEC1 0x04 prefix" tw_pub ("04" ^ td_pub);
      (* ocaml-tron emits the 65-byte form, matching TronWeb. *)
      let sk =
        ok "key"
          (Tron_crypto.private_key_of_bytes (unhex (F.get_str a "private_key")))
      in
      Alcotest.(check string)
        "ocaml-tron matches tronweb's spelling" tw_pub
        (hex
           (Tron_crypto.public_key_to_bytes
              (Tron_crypto.public_key_of_private_key sk))))
    (accounts tronweb) (accounts trident)

(* The recorded divergence.

   Both oracles sign the same digest with the same deterministic nonce, so r
   and s are identical. Only v differs: trident writes the raw recovery id,
   TronWeb writes it plus 27. java-tron normalises a v below 27 by adding it,
   so both verify -- and a histogram of mainnet block 85634951 shows both, with
   00/01 the majority.

   ocaml-tron therefore decodes both and, when writing, defaults to the
   recovery id: what the official SDK produces and what most of the chain
   carries. *)
let test_signature_v_divergence () =
  List.iter
    (fun name ->
      let a, b = paired name in
      let tw = F.strings (F.field a "signatures") in
      let td = F.strings (F.field b "signatures") in
      Alcotest.(check int)
        (name ^ ": same number of signatures")
        (List.length tw) (List.length td);
      List.iteri
        (fun i (x, y) ->
          let x = lower x and y = lower y in
          let label = Printf.sprintf "%s signature %d" name i in
          Alcotest.(check string)
            (label ^ ": r and s are identical")
            (String.sub x 0 128) (String.sub y 0 128);
          let tw_v = int_of_string ("0x" ^ String.sub x 128 2) in
          let td_v = int_of_string ("0x" ^ String.sub y 128 2) in
          Alcotest.(check bool)
            (label ^ ": trident writes a raw recovery id")
            true
            (td_v = 0 || td_v = 1);
          Alcotest.(check int)
            (label ^ ": tronweb writes it plus 27")
            (td_v + 27) tw_v)
        (List.combine tw td))
    (names ())

(* Both spellings must decode, and to the same signature. A decoder that took
   only one could not read a large fraction of mainnet history. *)
let test_both_spellings_decode_identically () =
  List.iter
    (fun name ->
      let a, b = paired name in
      List.iter2
        (fun x y ->
          let sx =
            ok "tronweb form" (Tron_crypto.signature_of_bytes (unhex x))
          in
          let sy =
            ok "trident form" (Tron_crypto.signature_of_bytes (unhex y))
          in
          Alcotest.(check string)
            (name ^ ": same r") (Tron_crypto.r sx) (Tron_crypto.r sy);
          Alcotest.(check string)
            (name ^ ": same s") (Tron_crypto.s sx) (Tron_crypto.s sy);
          Alcotest.(check int)
            (name ^ ": same recovery id")
            (Tron_crypto.recovery_id sx)
            (Tron_crypto.recovery_id sy))
        (F.strings (F.field a "signatures"))
        (F.strings (F.field b "signatures")))
    (names ())

(* And ocaml-tron reproduces each oracle exactly, under the encoding that
   oracle uses. Deterministic nonces make "exactly" a meaningful claim. *)
let test_ocaml_tron_reproduces_both () =
  let accs = accounts tronweb in
  List.iter
    (fun name ->
      let a, b = paired name in
      let digest = unhex (F.get_str a "txID") in
      List.iteri
        (fun i (x, y) ->
          let sk =
            ok "key"
              (Tron_crypto.private_key_of_bytes
                 (unhex (F.get_str (List.nth accs i) "private_key")))
          in
          let sg = ok "sign" (Tron_crypto.sign_digest sk digest) in
          Alcotest.(check string)
            (Printf.sprintf "%s signature %d matches trident" name i)
            (lower y)
            (hex (Tron_crypto.signature_to_bytes ~v:`Recovery_id sg));
          Alcotest.(check string)
            (Printf.sprintf "%s signature %d matches tronweb" name i)
            (lower x)
            (hex (Tron_crypto.signature_to_bytes ~v:`Eth_offset sg));
          (* The default is trident's, not TronWeb's. *)
          Alcotest.(check string)
            (Printf.sprintf "%s signature %d default encoding" name i)
            (hex (Tron_crypto.signature_to_bytes ~v:`Recovery_id sg))
            (hex (Tron_crypto.signature_to_bytes sg)))
        (List.combine
           (F.strings (F.field a "signatures"))
           (F.strings (F.field b "signatures"))))
    (names ())

let () =
  Alcotest.run "tron-conformance"
    [
      ( "coverage",
        [
          Alcotest.test_case "both oracles cover the same cases" `Quick
            test_same_cases;
        ] );
      ( "agreement",
        [
          Alcotest.test_case "raw_data and txID agree" `Quick
            test_raw_data_and_txid_agree;
          Alcotest.test_case "addresses agree" `Quick test_accounts_agree;
        ] );
      ( "divergence",
        [
          Alcotest.test_case "the v byte, recorded" `Quick
            test_signature_v_divergence;
          Alcotest.test_case "both spellings decode identically" `Quick
            test_both_spellings_decode_identically;
          Alcotest.test_case "ocaml-tron reproduces both" `Quick
            test_ocaml_tron_reproduces_both;
        ] );
    ]
