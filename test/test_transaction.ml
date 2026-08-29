(* The decisive test for the offline path: every byte here -- raw_data, the
   transaction id, the signatures -- is TronWeb 6.5.0's, generated offline and
   committed. Nothing is compared against ocaml-tron's own output. *)

open Tron_types
open Tron_transaction
module F = Fixture_tx

let fixture = lazy (F.load "../conformance/fixtures/tronweb-6.5.0.json")
let accounts () = F.get_list (Lazy.force fixture) "accounts"
let transactions () = F.get_list (Lazy.force fixture) "transactions"

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

let addr h = ok "address" (Address.of_hex h)
let sun n = ok "sun" (Sun.of_sun n)

let block_ref () =
  let rb = F.field (Lazy.force fixture) "reference_block" in
  ok "block ref"
    (Block_ref.of_slices
       ~block_bytes:(unhex (F.get_str rb "ref_block_bytes"))
       ~block_hash:(unhex (F.get_str rb "ref_block_hash")))

let account n = List.nth (accounts ()) n
let alice () = account 0
let bob () = account 1
let carol () = account 2

(* The expiration and timestamp the generator baked in. They are inputs to
   Raw_data.make -- nothing in lib/ reads a clock -- so the test supplies the
   same values the oracle did. *)
let expiration = 1755000000000L
let timestamp = 1754999940000L

let build ?permission_id ?fee_limit ?memo contract =
  ok "raw_data"
    (Raw_data.make ~block_ref:(block_ref ()) ~expiration ~timestamp
       ?permission_id ?fee_limit ?memo contract)

let trx_transfer ~to_ ~amount =
  Contract.Transfer
    {
      owner = addr (F.get_str (alice ()) "address_hex");
      to_ = addr to_;
      amount = sun amount;
    }

(* Each case rebuilds the transaction from first principles and asserts the
   serialized raw_data equals TronWeb's byte for byte. Getting this right means
   field numbers, varint framing, the Any type_url, the contract enum and the
   reference-block slicing all agree. *)
let case name raw =
  let tx = F.find (transactions ()) ~name in
  Alcotest.(check string)
    (name ^ ": raw_data is byte-identical to TronWeb")
    (F.get_str tx "raw_data_hex")
    (hex (Raw_data.to_bytes raw));
  Alcotest.(check string)
    (name ^ ": txID is SHA-256 of those bytes")
    (F.get_str tx "txID")
    (Tx_id.to_hex (Raw_data.tx_id raw));
  raw

let test_trx_transfer () =
  ignore
    (case "trx_transfer"
       (build
          (trx_transfer
             ~to_:(F.get_str (bob ()) "address_hex")
             ~amount:1_000_000L)))

let test_trx_transfer_permission_2 () =
  ignore
    (case "trx_transfer_permission_2"
       (build ~permission_id:2
          (trx_transfer
             ~to_:(F.get_str (bob ()) "address_hex")
             ~amount:1_000_000L)))

let test_trx_transfer_multisig () =
  ignore
    (case "trx_transfer_multisig"
       (build ~permission_id:2
          (trx_transfer
             ~to_:(F.get_str (carol ()) "address_hex")
             ~amount:2_500_000L)))

let test_trx_transfer_with_memo () =
  ignore
    (case "trx_transfer_with_memo"
       (build ~memo:"reuna"
          (trx_transfer ~to_:(F.get_str (bob ()) "address_hex") ~amount:1L)))

let test_trc20_transfer () =
  let tx = F.find (transactions ()) ~name:"trc20_transfer" in
  let abi = F.field tx "abi" in
  let raw =
    build ~fee_limit:(sun 150_000_000L)
      (Contract.Trigger_smart_contract
         {
           owner = addr (F.get_str (alice ()) "address_hex");
           contract = addr "41a614f803b6fd780986a42c78ec9c7f77e6ded13c";
           call_value = sun 0L;
           data = unhex (F.get_str abi "data");
           call_token_value = 0L;
           token_id = 0L;
         })
  in
  ignore (case "trc20_transfer" raw)

(* Building the call data ourselves, through evm-abi, must reproduce what
   TronWeb encoded -- including the address argument being the 20-byte form
   left-padded to 32, with the 0x41 prefix dropped. *)
let test_trc20_call_data () =
  let tx = F.find (transactions ()) ~name:"trc20_transfer" in
  let abi = F.field tx "abi" in
  let signature = F.get_str abi "signature" in
  let selector = Evm_abi.selector signature in
  Alcotest.(check string)
    "selector"
    (F.get_str abi "selector_hex")
    (hex selector);
  let recipient = addr (F.get_str abi "to") in
  let amount = Z.of_string (F.get_str abi "amount") in
  let args =
    ok "encode"
      (Evm_abi.encode
         [ Evm_abi.Address (Address.to_hash20 recipient); Evm_abi.Uint amount ])
  in
  Alcotest.(check string) "arguments" (F.get_str abi "args_hex") (hex args);
  Alcotest.(check string)
    "full call data" (F.get_str abi "data")
    (hex (selector ^ args))

(* Signing the whole way through, then rendering the broadcast body. *)
let test_sign_and_broadcast () =
  let name = "trx_transfer" in
  let fx = F.find (transactions ()) ~name in
  let raw =
    build
      (trx_transfer ~to_:(F.get_str (bob ()) "address_hex") ~amount:1_000_000L)
  in
  let tx = Transaction.of_raw_data raw in
  let sk =
    ok "key"
      (Tron_crypto.private_key_of_bytes
         (unhex (F.get_str (alice ()) "private_key")))
  in
  let signed = ok "sign" (Transaction.sign tx sk) in
  Alcotest.(check string)
    "signature matches TronWeb"
    (String.lowercase_ascii (List.hd (F.strings (F.field fx "signatures"))))
    (hex
       (Tron_crypto.signature_to_bytes ~v:`Eth_offset
          (List.hd (Transaction.signatures signed))));
  Alcotest.(check string)
    "txID unchanged by signing" (F.get_str fx "txID")
    (Tx_id.to_hex (Transaction.tx_id signed));
  (* The broadcast body must decode back to the same transaction. *)
  let round =
    ok "of_broadcast_hex"
      (Transaction.of_broadcast_hex (Transaction.to_broadcast_hex signed))
  in
  Alcotest.(check string)
    "round trips through the broadcast form" (F.get_str fx "txID")
    (Tx_id.to_hex (Transaction.tx_id round));
  let signers = ok "recover" (Transaction.recover_signers round) in
  Alcotest.(check int) "one signer" 1 (List.length signers);
  Alcotest.(check string)
    "recovers to alice"
    (F.get_str (alice ()) "address_hex")
    (Address.to_hex (ok "signer" (List.hd signers)))

let test_multisig_accumulates () =
  let fx = F.find (transactions ()) ~name:"trx_transfer_multisig" in
  let raw =
    build ~permission_id:2
      (trx_transfer
         ~to_:(F.get_str (carol ()) "address_hex")
         ~amount:2_500_000L)
  in
  let key acc =
    ok "key"
      (Tron_crypto.private_key_of_bytes (unhex (F.get_str acc "private_key")))
  in
  let signed =
    ok "second"
      (Transaction.sign
         (ok "first"
            (Transaction.sign (Transaction.of_raw_data raw) (key (alice ()))))
         (key (bob ())))
  in
  Alcotest.(check int)
    "two signatures" 2
    (List.length (Transaction.signatures signed));
  List.iteri
    (fun i expected ->
      Alcotest.(check string)
        (Printf.sprintf "signature %d matches TronWeb" i)
        (String.lowercase_ascii expected)
        (hex
           (Tron_crypto.signature_to_bytes ~v:`Eth_offset
              (List.nth (Transaction.signatures signed) i))))
    (F.strings (F.field fx "signatures"));
  (* Both signers recover, in order. *)
  let signers = ok "recover" (Transaction.recover_signers signed) in
  Alcotest.(check (list string))
    "signers in order"
    [ F.get_str (alice ()) "address_hex"; F.get_str (bob ()) "address_hex" ]
    (List.map (fun s -> Address.to_hex (ok "s" s)) signers)

(* Decoding TronWeb's bytes and getting our own model back. *)
let test_decode_oracle_bytes () =
  List.iter
    (fun tx ->
      let name = F.get_str tx "name" in
      let raw =
        ok (name ^ " decode")
          (Raw_data.of_bytes (unhex (F.get_str tx "raw_data_hex")))
      in
      Alcotest.(check string)
        (name ^ ": decoded txID matches")
        (F.get_str tx "txID")
        (Tx_id.to_hex (Raw_data.tx_id raw));
      (* of_bytes retains the source bytes, so to_bytes is the identity. *)
      Alcotest.(check string)
        (name ^ ": to_bytes returns the bytes it decoded")
        (F.get_str tx "raw_data_hex")
        (hex (Raw_data.to_bytes raw));
      Alcotest.(check int64)
        (name ^ ": expiration") expiration (Raw_data.expiration raw);
      match Raw_data.contract raw with
      | Contract.Unknown _ -> Alcotest.failf "%s decoded as Unknown" name
      | _ -> ())
    (transactions ())

let test_permission_id_round_trips () =
  List.iter
    (fun (name, expect) ->
      let tx = F.find (transactions ()) ~name in
      let raw =
        ok "decode" (Raw_data.of_bytes (unhex (F.get_str tx "raw_data_hex")))
      in
      Alcotest.(check int)
        (name ^ ": permission id") expect
        (Raw_data.permission_id raw))
    [
      ("trx_transfer", 0);
      ("trx_transfer_permission_2", 2);
      ("trx_transfer_multisig", 2);
      ("trc20_transfer", 0);
    ]

let test_fee_limit_visible () =
  let trc20 = F.find (transactions ()) ~name:"trc20_transfer" in
  let raw =
    ok "decode" (Raw_data.of_bytes (unhex (F.get_str trc20 "raw_data_hex")))
  in
  (match Raw_data.fee_limit raw with
  | Some f ->
      Alcotest.(check int64) "fee limit survives" 150_000_000L (Sun.to_sun f)
  | None -> Alcotest.fail "fee limit was dropped");
  let transfer = F.find (transactions ()) ~name:"trx_transfer" in
  let raw =
    ok "decode" (Raw_data.of_bytes (unhex (F.get_str transfer "raw_data_hex")))
  in
  Alcotest.(check bool)
    "absent on a plain transfer" true
    (Raw_data.fee_limit raw = None)

(* An unrecognised contract must survive as Unknown rather than being dropped
   or guessed at, and must never become approvable. The adversarial bytes are
   built here through the generated wire types, because that is exactly how
   they would arrive: a well-formed transaction naming a contract type this
   library does not implement. *)
let test_unknown_contract () =
  let module PB = Tron_proto.Tron.Protocol in
  let module Any = Tron_proto.Any.Google.Protobuf.Any in
  let module W = Ocaml_protoc_plugin.Writer in
  let alien_url = "type.googleapis.com/protocol.ShieldedTransferContract" in
  let alien_payload = "\x0a\x03\x01\x02\x03" in
  let br = block_ref () in
  let bytes =
    W.contents
      (PB.Transaction.Raw.to_proto
         (PB.Transaction.Raw.make
            ~ref_block_bytes:(Bytes.of_string (Block_ref.block_bytes br))
            ~ref_block_hash:(Bytes.of_string (Block_ref.block_hash br))
            ~expiration ~timestamp
            ~contract:
              [
                PB.Transaction.Contract.make
                  ~type':
                    PB.Transaction.Contract.ContractType
                    .ShieldedTransferContract
                  ~parameter:
                    (Any.make ~type_url:alien_url
                       ~value:(Bytes.of_string alien_payload)
                       ())
                  ();
              ]
            ()))
  in
  let raw = ok "decode alien" (Raw_data.of_bytes bytes) in
  (match Raw_data.contract raw with
  | Contract.Unknown { type_url; value } ->
      Alcotest.(check string) "type_url preserved" alien_url type_url;
      Alcotest.(check string) "payload preserved verbatim" alien_payload value
  | c -> Alcotest.failf "decoded as something known: %a" Contract.pp c);
  (* It still has a transaction id -- an unrecognised transaction is readable,
     just not approvable. *)
  Alcotest.(check int)
    "txID is still 32 bytes" 32
    (String.length (Tx_id.to_bytes (Raw_data.tx_id raw)));
  (* And it cannot be rebuilt: re-encoding would have to invent a ContractType
     enum to sit beside the type_url, and the two would then disagree. *)
  Alcotest.(check bool)
    "an Unknown cannot be built into a transaction" true
    (Result.is_error
       (Raw_data.make ~block_ref:br ~expiration ~timestamp
          (Contract.Unknown { type_url = alien_url; value = alien_payload })))

(* A payload that claims a type_url this library does know, but does not decode
   as it, is malformed rather than unknown -- and must not silently become an
   empty contract of that type. *)
let test_malformed_known_contract () =
  let module PB = Tron_proto.Tron.Protocol in
  let module Any = Tron_proto.Any.Google.Protobuf.Any in
  let module W = Ocaml_protoc_plugin.Writer in
  let br = block_ref () in
  let build_with value =
    W.contents
      (PB.Transaction.Raw.to_proto
         (PB.Transaction.Raw.make
            ~ref_block_bytes:(Bytes.of_string (Block_ref.block_bytes br))
            ~ref_block_hash:(Bytes.of_string (Block_ref.block_hash br))
            ~expiration ~timestamp
            ~contract:
              [
                PB.Transaction.Contract.make
                  ~type':PB.Transaction.Contract.ContractType.TransferContract
                  ~parameter:
                    (Any.make
                       ~type_url:"type.googleapis.com/protocol.TransferContract"
                       ~value:(Bytes.of_string value) ())
                  ();
              ]
            ()))
  in
  (* A 20-byte owner address: decodes as protobuf, invalid as an address. *)
  let short_owner = "\x0a\x14" ^ String.make 20 '\x11' in
  (match Raw_data.of_bytes (build_with short_owner) with
  | Ok raw ->
      Alcotest.failf "a 20-byte owner address was accepted: %a" Contract.pp
        (Raw_data.contract raw)
  | Error _ -> ());
  (* Truncated payload. *)
  Alcotest.(check bool)
    "truncated payload rejected" true
    (Result.is_error (Raw_data.of_bytes (build_with "\x0a\x15\x41")))

(* The wire form must carry the raw_data that was signed, byte for byte --
   including when it arrived with framing this library would not have chosen.

   Protobuf permits a non-repeated scalar to appear more than once; the later
   occurrence wins. Such a message decodes to exactly the same model and
   re-encodes to different bytes. If to_bytes round-tripped through the model,
   the transaction on the wire would have a different id than the one that was
   signed and reviewed, and the node would reject the signature -- or worse,
   not. *)
let test_wire_form_preserves_signed_bytes () =
  let tx = F.find (transactions ()) ~name:"trx_transfer" in
  let canonical = unhex (F.get_str tx "raw_data_hex") in
  (* Field 8 (expiration) is a varint: tag byte 0x40. A duplicate ahead of the
     real one is legal and is ignored in favour of the later value. *)
  let non_canonical = "\x40\x01" ^ canonical in

  (* raw_data field 1, wire type 2: tag 0x0a then a varint length. *)
  let carried_raw_data full =
    Alcotest.(check char) "field 1, wire type 2" '\x0a' full.[0];
    let i = ref 1 and shift = ref 0 and len = ref 0 and go = ref true in
    while !go do
      let b = Char.code full.[!i] in
      len := !len lor ((b land 0x7f) lsl !shift);
      shift := !shift + 7;
      incr i;
      if b land 0x80 = 0 then go := false
    done;
    String.sub full !i !len
  in

  let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s)) in

  List.iter
    (fun (label, bytes) ->
      let raw = ok (label ^ " decode") (Raw_data.of_bytes bytes) in
      Alcotest.(check string)
        (label ^ ": Raw_data keeps the bytes it decoded")
        (hex bytes)
        (hex (Raw_data.to_bytes raw));
      let signed =
        ok "sign"
          (Transaction.sign
             (Transaction.of_raw_data raw)
             (ok "key"
                (Tron_crypto.private_key_of_bytes
                   (unhex (F.get_str (alice ()) "private_key")))))
      in
      let carried = carried_raw_data (Transaction.to_bytes signed) in
      Alcotest.(check string)
        (label ^ ": the wire form carries those same bytes")
        (hex bytes) (hex carried);
      (* And so the id the wire form implies is the id that was signed. *)
      Alcotest.(check string)
        (label ^ ": and therefore the same transaction id")
        (Tx_id.to_hex (Raw_data.tx_id raw))
        (hex (sha256 carried)))
    [ ("canonical", canonical); ("non-canonical", non_canonical) ];

  (* The two really are different transactions, so the checks above are not
     comparing something with itself. *)
  let a = ok "a" (Raw_data.of_bytes canonical) in
  let b = ok "b" (Raw_data.of_bytes non_canonical) in
  Alcotest.(check bool)
    "the two framings give different ids" false
    (Tx_id.equal (Raw_data.tx_id a) (Raw_data.tx_id b));
  Alcotest.(check int64)
    "but decode to the same expiration" (Raw_data.expiration a)
    (Raw_data.expiration b)

let test_rejections () =
  let contract =
    trx_transfer ~to_:(F.get_str (bob ()) "address_hex") ~amount:1L
  in
  (* Permission 1 is the witness permission and cannot authorise a transfer. *)
  Alcotest.(check bool)
    "witness permission rejected" true
    (Result.is_error
       (Raw_data.make ~block_ref:(block_ref ()) ~expiration ~timestamp
          ~permission_id:1 contract));
  List.iter
    (fun n ->
      Alcotest.(check bool)
        (Printf.sprintf "permission id %d rejected" n)
        true
        (Result.is_error
           (Raw_data.make ~block_ref:(block_ref ()) ~expiration ~timestamp
              ~permission_id:n contract)))
    [ -1; 10; 255 ];
  List.iter
    (fun n ->
      Alcotest.(check bool)
        (Printf.sprintf "permission id %d accepted" n)
        true
        (Result.is_ok
           (Raw_data.make ~block_ref:(block_ref ()) ~expiration ~timestamp
              ~permission_id:n contract)))
    [ 0; 2; 9 ];
  Alcotest.(check bool)
    "garbage does not decode" true
    (Result.is_error (Raw_data.of_bytes "\xff\xff\xff\xff"));
  Alcotest.(check bool)
    "empty does not decode" true
    (Result.is_error (Raw_data.of_bytes ""))

let () =
  Alcotest.run "tron-transaction"
    [
      ( "raw_data vs TronWeb",
        [
          Alcotest.test_case "TRX transfer" `Quick test_trx_transfer;
          Alcotest.test_case "TRX transfer, permission 2" `Quick
            test_trx_transfer_permission_2;
          Alcotest.test_case "TRX transfer, multisig" `Quick
            test_trx_transfer_multisig;
          Alcotest.test_case "TRX transfer, memo" `Quick
            test_trx_transfer_with_memo;
          Alcotest.test_case "TRC-20 transfer" `Quick test_trc20_transfer;
        ] );
      ( "abi",
        [
          Alcotest.test_case "TRC-20 call data via evm-abi" `Quick
            test_trc20_call_data;
        ] );
      ( "signing",
        [
          Alcotest.test_case "sign, broadcast, round trip" `Quick
            test_sign_and_broadcast;
          Alcotest.test_case "multisig accumulates in order" `Quick
            test_multisig_accumulates;
        ] );
      ( "decoding",
        [
          Alcotest.test_case "TronWeb bytes decode to our model" `Quick
            test_decode_oracle_bytes;
          Alcotest.test_case "permission id round trips" `Quick
            test_permission_id_round_trips;
          Alcotest.test_case "fee limit is visible" `Quick
            test_fee_limit_visible;
          Alcotest.test_case "the wire form preserves the signed bytes" `Quick
            test_wire_form_preserves_signed_bytes;
          Alcotest.test_case "unknown contracts stay unknown" `Quick
            test_unknown_contract;
          Alcotest.test_case "malformed known contracts are rejected" `Quick
            test_malformed_known_contract;
          Alcotest.test_case "rejections" `Quick test_rejections;
        ] );
    ]
