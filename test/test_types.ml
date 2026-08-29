(* Vectors are literals taken from the official documentation and the two
   conformance oracles, never from this library's own output. Where a value is
   derived rather than quoted, the derivation is stated. *)

open Tron_types

let check_ok name = function
  | Ok v -> v
  | Error _ -> Alcotest.failf "%s: expected Ok" name

(* From developers.tron.network's ABI encoding page, which gives the hex
   address 412ed5dd8a98aea00ae32517742ea5289761b2710e alongside the ABI word it
   encodes to. *)
let doc_hex = "412ed5dd8a98aea00ae32517742ea5289761b2710e"

let doc_abi_word_hex =
  "0000000000000000000000002ed5dd8a98aea00ae32517742ea5289761b2710e"

let addr_of_hex_exn h = check_ok "of_hex" (Address.of_hex h)

let hex_of_string s =
  String.concat ""
    (List.map
       (fun c -> Printf.sprintf "%02x" (Char.code c))
       (List.init (String.length s) (String.get s)))

let test_address_shape () =
  let a = addr_of_hex_exn doc_hex in
  Alcotest.(check int) "21 bytes" 21 (String.length (Address.to_bytes a));
  Alcotest.(check char) "0x41 prefix" '\x41' (Address.to_bytes a).[0];
  Alcotest.(check string) "hex round trip" doc_hex (Address.to_hex a);
  Alcotest.(check int)
    "hash is 20 bytes" 20
    (String.length (Address.to_hash20 a))

let test_address_abi_word () =
  let a = addr_of_hex_exn doc_hex in
  Alcotest.(check string)
    "ABI word drops 0x41 and left-pads to 32" doc_abi_word_hex
    (hex_of_string (Address.to_abi_word a));
  Alcotest.(check int)
    "word is 32 bytes" 32
    (String.length (Address.to_abi_word a));
  let back =
    check_ok "of_abi_word" (Address.of_abi_word (Address.to_abi_word a))
  in
  Alcotest.(check bool) "round trips" true (Address.equal a back)

let test_address_abi_word_tron_flavoured () =
  (* Tron also accepts a word carrying 0x41 at byte 11. The EVM reads only the
     last 20 bytes, so both name the same account and both must decode. *)
  let a = addr_of_hex_exn doc_hex in
  let flavoured = String.make 11 '\x00' ^ Address.to_bytes a in
  Alcotest.(check int) "still 32 bytes" 32 (String.length flavoured);
  let back = check_ok "of_abi_word" (Address.of_abi_word flavoured) in
  Alcotest.(check bool) "same address" true (Address.equal a back)

let test_address_base58check () =
  let a = addr_of_hex_exn doc_hex in
  let b58 = Address.to_base58check a in
  Alcotest.(check int) "34 characters" 34 (String.length b58);
  Alcotest.(check char) "starts with T" 'T' b58.[0];
  let back = check_ok "of_base58check" (Address.of_base58check b58) in
  Alcotest.(check bool) "round trips" true (Address.equal a back)

let test_address_rejects () =
  let bad_prefix = "40" ^ String.sub doc_hex 2 40 in
  Alcotest.(check bool)
    "non-0x41 prefix rejected" true
    (Result.is_error (Address.of_hex bad_prefix));
  Alcotest.(check bool)
    "20-byte input rejected" true
    (Result.is_error (Address.of_hex (String.sub doc_hex 2 40)));
  Alcotest.(check bool)
    "odd-length hex rejected" true
    (Result.is_error (Address.of_hex (doc_hex ^ "0")));
  Alcotest.(check bool)
    "non-hex rejected" true
    (Result.is_error (Address.of_hex (String.sub doc_hex 0 40 ^ "zz")));
  (* A Base58Check string with one character altered must fail the checksum,
     not decode to a neighbouring account. *)
  let b58 = Address.to_base58check (addr_of_hex_exn doc_hex) in
  let mangled = Bytes.of_string b58 in
  Bytes.set mangled 10 (if Bytes.get mangled 10 = 'a' then 'b' else 'a');
  Alcotest.(check bool)
    "mangled base58check rejected" true
    (Result.is_error (Address.of_base58check (Bytes.to_string mangled)))

let test_address_hash20_roundtrip () =
  let a = addr_of_hex_exn doc_hex in
  let back = check_ok "of_hash20" (Address.of_hash20 (Address.to_hash20 a)) in
  Alcotest.(check bool) "round trips" true (Address.equal a back);
  Alcotest.(check bool)
    "19 bytes rejected" true
    (Result.is_error (Address.of_hash20 (String.make 19 '\x00')))

(* Sun *)

let test_sun_decimal () =
  let cases =
    [
      ("1", 1_000_000L);
      ("1.5", 1_500_000L);
      ("0.000001", 1L);
      ("0", 0L);
      ("1.234567", 1_234_567L);
      ("100", 100_000_000L);
    ]
  in
  List.iter
    (fun (s, expect) ->
      let v = check_ok s (Sun.of_trx_string s) in
      Alcotest.(check int64) ("of_trx_string " ^ s) expect (Sun.to_sun v);
      let back =
        check_ok "round trip" (Sun.of_trx_string (Sun.to_trx_string v))
      in
      Alcotest.(check int64) ("round trip " ^ s) expect (Sun.to_sun back))
    cases

let test_sun_rejects_inexact () =
  (* Seven decimal places cannot be represented; rounding it would be a wrong
     amount, so it is refused. *)
  List.iter
    (fun s ->
      Alcotest.(check bool)
        (Printf.sprintf "%S rejected" s)
        true
        (Result.is_error (Sun.of_trx_string s)))
    [ "1.2345678"; "-1"; ""; "1.2.3"; "abc"; "1e6"; "." ]

let test_sun_arithmetic () =
  let a = Sun.of_sun_exn 1_000_000L in
  Alcotest.(check int64)
    "add" 2_000_000L
    (Sun.to_sun (check_ok "add" (Sun.add a a)));
  Alcotest.(check bool)
    "sub below zero rejected" true
    (Result.is_error (Sun.sub a (Sun.of_sun_exn 2_000_000L)));
  Alcotest.(check bool)
    "negative rejected" true
    (Result.is_error (Sun.of_sun (-1L)));
  let big = Sun.of_sun_exn Int64.max_int in
  Alcotest.(check bool)
    "add overflow caught" true
    (Result.is_error (Sun.add big a));
  Alcotest.(check bool)
    "mul overflow caught" true
    (Result.is_error (Sun.mul big 2));
  Alcotest.(check int64)
    "sum" 3_000_000L
    (Sun.to_sun (check_ok "sum" (Sun.sum [ a; a; a ])))

(* Block reference *)

let block_id_of number tail =
  let b = Bytes.create 32 in
  Bytes.fill b 0 32 '\x00';
  Bytes.set_int64_be b 0 number;
  String.iteri (fun i c -> Bytes.set b (8 + i) c) tail;
  check_ok "block id" (Tx_id.of_bytes (Bytes.to_string b))

let test_block_ref_slices () =
  let number = 0x0000_0000_0102_0304L in
  let id = block_id_of number "\xaa\xbb\xcc\xdd\xee\xff\x11\x22" in
  let r = check_ok "of_block" (Block_ref.of_block ~number ~id) in
  (* [6,8) of the number, big-endian: 0x0304. *)
  Alcotest.(check string)
    "ref_block_bytes" "0304"
    (hex_of_string (Block_ref.block_bytes r));
  (* [8,16) of the id. *)
  Alcotest.(check string)
    "ref_block_hash" "aabbccddeeff1122"
    (hex_of_string (Block_ref.block_hash r));
  Alcotest.(check bool)
    "of_block_id agrees" true
    (Block_ref.equal r (Block_ref.of_block_id id))

let test_block_ref_mismatch () =
  let id = block_id_of 5L "\x00\x00\x00\x00\x00\x00\x00\x00" in
  Alcotest.(check bool)
    "inconsistent node response rejected" true
    (Result.is_error (Block_ref.of_block ~number:6L ~id))

let test_block_ref_slice_widths () =
  Alcotest.(check bool)
    "3-byte block_bytes rejected" true
    (Result.is_error
       (Block_ref.of_slices ~block_bytes:"\x00\x00\x00"
          ~block_hash:(String.make 8 '\x00')));
  Alcotest.(check bool)
    "7-byte block_hash rejected" true
    (Result.is_error
       (Block_ref.of_slices ~block_bytes:"\x00\x00"
          ~block_hash:(String.make 7 '\x00')))

(* Network *)

let test_network_verify () =
  let genesis = String.make 32 '\x01' in
  let expect =
    Network.make ~name:"nile"
      ~genesis_block_id:(check_ok "genesis" (Tx_id.of_bytes genesis))
  in
  Alcotest.(check bool)
    "matching genesis accepted" true
    (Result.is_ok
       (Network.verify ~expect
          ~observed:(check_ok "g" (Tx_id.of_bytes genesis))));
  Alcotest.(check bool)
    "different chain rejected" true
    (Result.is_error
       (Network.verify ~expect
          ~observed:(check_ok "g" (Tx_id.of_bytes (String.make 32 '\x02')))))

(* Properties *)

let prop_address_roundtrip =
  QCheck2.Test.make ~count:2000 ~name:"address round-trips through every form"
    (QCheck2.Gen.string_size ~gen:QCheck2.Gen.char (QCheck2.Gen.return 20))
    (fun hash20 ->
      let a = Result.get_ok (Address.of_hash20 hash20) in
      Address.equal a
        (Result.get_ok (Address.of_base58check (Address.to_base58check a)))
      && Address.equal a (Result.get_ok (Address.of_hex (Address.to_hex a)))
      && Address.equal a
           (Result.get_ok (Address.of_abi_word (Address.to_abi_word a))))

let prop_sun_roundtrip =
  QCheck2.Test.make ~count:2000 ~name:"sun round-trips through its TRX figure"
    QCheck2.Gen.(map Int64.abs int64)
    (fun n ->
      match Sun.of_sun n with
      | Error _ -> true
      | Ok v -> (
          match Sun.of_trx_string (Sun.to_trx_string v) with
          | Ok back -> Sun.equal v back
          | Error _ -> false))

let () =
  Alcotest.run "tron-types"
    [
      ( "address",
        [
          Alcotest.test_case "shape" `Quick test_address_shape;
          Alcotest.test_case "abi word" `Quick test_address_abi_word;
          Alcotest.test_case "abi word, tron-flavoured" `Quick
            test_address_abi_word_tron_flavoured;
          Alcotest.test_case "base58check" `Quick test_address_base58check;
          Alcotest.test_case "hash20 round trip" `Quick
            test_address_hash20_roundtrip;
          Alcotest.test_case "rejections" `Quick test_address_rejects;
        ] );
      ( "sun",
        [
          Alcotest.test_case "decimal" `Quick test_sun_decimal;
          Alcotest.test_case "rejects inexact" `Quick test_sun_rejects_inexact;
          Alcotest.test_case "arithmetic" `Quick test_sun_arithmetic;
        ] );
      ( "block_ref",
        [
          Alcotest.test_case "slices" `Quick test_block_ref_slices;
          Alcotest.test_case "number/id mismatch" `Quick test_block_ref_mismatch;
          Alcotest.test_case "slice widths" `Quick test_block_ref_slice_widths;
        ] );
      ("network", [ Alcotest.test_case "verify" `Quick test_network_verify ]);
      ( "properties",
        List.map QCheck_alcotest.to_alcotest
          [ prop_address_roundtrip; prop_sun_roundtrip ] );
    ]
