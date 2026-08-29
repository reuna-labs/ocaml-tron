(* The intent layer is derived from bytes, so these tests feed it the oracle's
   bytes -- not a value this library built -- and check what a reviewer would
   be shown. The policies are then attacked. *)

open Tron_types
open Tron_transaction
module F = Fixture_intent

let fixture = lazy (F.load "../conformance/fixtures/tronweb-6.5.0.json")
let accounts () = F.get_list (Lazy.force fixture) "accounts"
let transactions () = F.get_list (Lazy.force fixture) "transactions"

let unhex h =
  String.init
    (String.length h / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2)))

let ok name = function
  | Ok v -> v
  | Error _ -> Alcotest.failf "%s: expected Ok" name

let addr h = ok "address" (Address.of_hex h)
let account n = List.nth (accounts ()) n
let alice () = addr (F.get_str (account 0) "address_hex")
let bob () = addr (F.get_str (account 1) "address_hex")
let carol () = addr (F.get_str (account 2) "address_hex")

let intent name =
  let tx = F.find (transactions ()) ~name in
  ok (name ^ " derive") (Intent.derive (unhex (F.get_str tx "raw_data_hex")))

let usdt = addr "41a614f803b6fd780986a42c78ec9c7f77e6ded13c"
let expiration = 1755000000000L

(* Derivation *)

let test_trx_transfer_intent () =
  let i = intent "trx_transfer" in
  (match i.Intent.instruction with
  | Intent.Trx_transfer { from; to_; amount } ->
      Alcotest.(check bool) "from alice" true (Address.equal from (alice ()));
      Alcotest.(check bool) "to bob" true (Address.equal to_ (bob ()));
      Alcotest.(check int64) "1 TRX" 1_000_000L (Sun.to_sun amount)
  | other -> Alcotest.failf "wrong instruction: %a" Intent.pp_instruction other);
  Alcotest.(check int) "owner permission" 0 i.Intent.permission_id;
  Alcotest.(check bool) "no fee limit" true (i.Intent.fee_limit = None);
  Alcotest.(check int64) "expiration is carried" expiration i.Intent.expiration

let test_trc20_intent () =
  let i = intent "trc20_transfer" in
  (match i.Intent.instruction with
  | Intent.Trc20_call
      { owner; contract; call = Trc20.Transfer { to_; amount }; call_value } ->
      Alcotest.(check bool)
        "owner is alice" true
        (Address.equal owner (alice ()));
      Alcotest.(check bool)
        "contract is the token" true
        (Address.equal contract usdt);
      Alcotest.(check bool) "recipient is bob" true (Address.equal to_ (bob ()));
      Alcotest.(check string) "amount" "50000000000" (Z.to_string amount);
      Alcotest.(check int64) "no TRX rides along" 0L (Sun.to_sun call_value)
  | other -> Alcotest.failf "wrong instruction: %a" Intent.pp_instruction other);
  (* The field the vault doc says must never be hidden. *)
  match i.Intent.fee_limit with
  | Some f ->
      Alcotest.(check int64) "fee limit is shown" 150_000_000L (Sun.to_sun f)
  | None -> Alcotest.fail "fee limit was not carried into the intent"

let test_permission_is_shown () =
  Alcotest.(check int)
    "permission 2 surfaces" 2
    (intent "trx_transfer_permission_2").Intent.permission_id;
  Alcotest.(check int)
    "and on the multisig case" 2
    (intent "trx_transfer_multisig").Intent.permission_id

let test_memo_and_bandwidth () =
  let i = intent "trx_transfer_with_memo" in
  Alcotest.(check string) "memo surfaces" "reuna" i.Intent.memo;
  (* Bandwidth is the byte count, so raw_data alone is smaller than the signed
     transaction. Both are honest answers to different questions. *)
  Alcotest.(check bool)
    "bandwidth is the byte count" true
    (Intent.bandwidth_cost i = i.Intent.size && i.Intent.size > 0)

let test_rendering_shows_the_dangerous_fields () =
  let rendered = Format.asprintf "%a" Intent.pp (intent "trc20_transfer") in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        (Printf.sprintf "rendering mentions %S" needle)
        true
        (let re = Str.regexp_string needle in
         try
           ignore (Str.search_forward re rendered 0);
           true
         with Not_found -> false))
    [ "permission:"; "fee limit:"; "expires:"; "bandwidth:"; "transaction id:" ]

(* An unexplained call must say so, loudly, rather than being rendered as
   something reassuring. *)
let test_unexplained_call_is_marked () =
  let module PB = Tron_proto.Tron.Protocol in
  let module Any = Tron_proto.Any.Google.Protobuf.Any in
  let module W = Ocaml_protoc_plugin.Writer in
  let module Smart = Tron_proto.Smart_contract.Protocol in
  let br = (intent "trx_transfer").Intent.block_ref in
  let data = "\xde\xad\xbe\xef" ^ String.make 32 '\x07' in
  let payload =
    W.contents
      (Smart.TriggerSmartContract.to_proto
         (Smart.TriggerSmartContract.make
            ~owner_address:(Bytes.of_string (Address.to_bytes (alice ())))
            ~contract_address:(Bytes.of_string (Address.to_bytes usdt))
            ~data:(Bytes.of_string data) ()))
  in
  let bytes =
    W.contents
      (PB.Transaction.Raw.to_proto
         (PB.Transaction.Raw.make
            ~ref_block_bytes:(Bytes.of_string (Block_ref.block_bytes br))
            ~ref_block_hash:(Bytes.of_string (Block_ref.block_hash br))
            ~expiration ~timestamp:0L
            ~contract:
              [
                PB.Transaction.Contract.make
                  ~type':
                    PB.Transaction.Contract.ContractType.TriggerSmartContract
                  ~parameter:
                    (Any.make
                       ~type_url:
                         "type.googleapis.com/protocol.TriggerSmartContract"
                       ~value:(Bytes.of_string payload) ())
                  ();
              ]
            ()))
  in
  let i = ok "derive" (Intent.derive bytes) in
  (match i.Intent.instruction with
  | Intent.Contract_call { selector; _ } ->
      Alcotest.(check string)
        "selector is reported as-is" "\xde\xad\xbe\xef" selector
  | other ->
      Alcotest.failf "should not have been explained: %a" Intent.pp_instruction
        other);
  let rendered = Format.asprintf "%a" Intent.pp i in
  Alcotest.(check bool)
    "rendering says UNEXPLAINED" true
    (try
       ignore (Str.search_forward (Str.regexp_string "UNEXPLAINED") rendered 0);
       true
     with Not_found -> false);
  (* And no TRC-20 policy may accept it, trusted contract or not. *)
  Alcotest.(check bool)
    "TRC-20 policy refuses it" true
    (Result.is_error
       (Intent.validate_trc20_transfer ~trusted_contracts:[ usdt ] i))

(* Policies *)

let test_trx_policy_accepts () =
  let i = intent "trx_transfer" in
  Alcotest.(check bool)
    "bare" true
    (Result.is_ok (Intent.validate_trx_transfer i));
  Alcotest.(check bool)
    "fully constrained" true
    (Result.is_ok
       (Intent.validate_trx_transfer ~from:(alice ()) ~to_:(bob ())
          ~max_amount:(ok "sun" (Sun.of_sun 1_000_000L))
          i))

let test_trx_policy_refuses () =
  let i = intent "trx_transfer" in
  let refused what r =
    Alcotest.(check bool) (what ^ " refused") true (Result.is_error r)
  in
  refused "wrong sender" (Intent.validate_trx_transfer ~from:(carol ()) i);
  refused "wrong destination" (Intent.validate_trx_transfer ~to_:(carol ()) i);
  refused "amount over the limit"
    (Intent.validate_trx_transfer
       ~max_amount:(ok "sun" (Sun.of_sun 999_999L))
       i);
  refused "expired"
    (Intent.validate_trx_transfer ~now:(Int64.add expiration 1L) i);
  (* Signed under an active permission rather than owner. *)
  refused "non-owner permission"
    (Intent.validate_trx_transfer (intent "trx_transfer_permission_2"));
  (* A TRC-20 call is not a TRX transfer, however it is dressed. *)
  refused "a token transfer is not a TRX transfer"
    (Intent.validate_trx_transfer (intent "trc20_transfer"));
  (* Exactly at expiry is expired, not still valid. *)
  refused "expires at the boundary"
    (Intent.validate_trx_transfer ~now:expiration i);
  Alcotest.(check bool)
    "one millisecond earlier is fine" true
    (Result.is_ok
       (Intent.validate_trx_transfer ~now:(Int64.sub expiration 1L) i))

let test_trc20_policy () =
  let i = intent "trc20_transfer" in
  Alcotest.(check bool)
    "accepted for a trusted contract" true
    (Result.is_ok
       (Intent.validate_trc20_transfer ~from:(alice ()) ~to_:(bob ())
          ~trusted_contracts:[ usdt ] i));
  let refused what r =
    Alcotest.(check bool) (what ^ " refused") true (Result.is_error r)
  in
  (* The whole point of the parameter having no default. *)
  refused "untrusted contract"
    (Intent.validate_trc20_transfer ~trusted_contracts:[] i);
  refused "a different trusted contract"
    (Intent.validate_trc20_transfer ~trusted_contracts:[ carol () ] i);
  refused "wrong recipient"
    (Intent.validate_trc20_transfer ~to_:(carol ()) ~trusted_contracts:[ usdt ]
       i);
  refused "token amount over the limit"
    (Intent.validate_trc20_transfer ~max_amount:(Z.of_int 1)
       ~trusted_contracts:[ usdt ] i);
  refused "fee limit over the limit"
    (Intent.validate_trc20_transfer
       ~max_fee_limit:(ok "sun" (Sun.of_sun 1L))
       ~trusted_contracts:[ usdt ] i);
  refused "expired"
    (Intent.validate_trc20_transfer ~now:(Int64.add expiration 1L)
       ~trusted_contracts:[ usdt ] i);
  refused "a TRX transfer is not a token transfer"
    (Intent.validate_trc20_transfer ~trusted_contracts:[ usdt ]
       (intent "trx_transfer"))

(* An opaque contract must fail every policy, unconditionally. *)
let test_opaque_is_never_approvable () =
  let module PB = Tron_proto.Tron.Protocol in
  let module Any = Tron_proto.Any.Google.Protobuf.Any in
  let module W = Ocaml_protoc_plugin.Writer in
  let br = (intent "trx_transfer").Intent.block_ref in
  let bytes =
    W.contents
      (PB.Transaction.Raw.to_proto
         (PB.Transaction.Raw.make
            ~ref_block_bytes:(Bytes.of_string (Block_ref.block_bytes br))
            ~ref_block_hash:(Bytes.of_string (Block_ref.block_hash br))
            ~expiration ~timestamp:0L
            ~contract:
              [
                PB.Transaction.Contract.make
                  ~type':
                    PB.Transaction.Contract.ContractType
                    .ExchangeTransactionContract
                  ~parameter:
                    (Any.make
                       ~type_url:
                         "type.googleapis.com/protocol.ExchangeTransactionContract"
                       ~value:(Bytes.of_string "\x08\x01")
                       ())
                  ();
              ]
            ()))
  in
  let i = ok "derive" (Intent.derive bytes) in
  (match i.Intent.instruction with
  | Intent.Opaque _ -> ()
  | other ->
      Alcotest.failf "should have been opaque: %a" Intent.pp_instruction other);
  Alcotest.(check bool)
    "TRX policy refuses" true
    (Result.is_error (Intent.validate_trx_transfer i));
  Alcotest.(check bool)
    "TRC-20 policy refuses" true
    (Result.is_error
       (Intent.validate_trc20_transfer ~trusted_contracts:[ usdt ] i));
  Alcotest.(check bool)
    "rendering says UNRECOGNISED" true
    (try
       ignore
         (Str.search_forward
            (Str.regexp_string "UNRECOGNISED")
            (Format.asprintf "%a" Intent.pp i)
            0);
       true
     with Not_found -> false)

(* Permission weight arithmetic: one key must not reach a threshold of two. *)
let test_permission_weights () =
  let open Permission in
  let p =
    {
      kind = Active;
      id = 2;
      name = "ops";
      threshold = 2L;
      operations = String.make 32 '\xff';
      keys =
        [
          { address = alice (); weight = 1L }; { address = bob (); weight = 1L };
        ];
    }
  in
  Alcotest.(check int64) "one signer" 1L (total_weight p [ alice () ]);
  Alcotest.(check int64)
    "the same signer twice still counts once" 1L
    (total_weight p [ alice (); alice () ]);
  Alcotest.(check bool)
    "one key does not meet a threshold of two" false
    (meets_threshold p [ alice (); alice () ]);
  Alcotest.(check bool)
    "two distinct keys do" true
    (meets_threshold p [ alice (); bob () ]);
  Alcotest.(check int64)
    "an unknown signer contributes nothing" 0L
    (total_weight p [ carol () ])

(* The operations bitmap: byte n/8, bit n land 7, little-endian. *)
let test_permission_operations_bitmap () =
  let open Permission in
  let module Ct = Tron_proto.Tron.Protocol.Transaction.Contract.ContractType in
  let bitmap_for types =
    let b = Bytes.make 32 '\x00' in
    List.iter
      (fun ct ->
        let n = Ct.to_int ct in
        let i = n / 8 in
        Bytes.set b i
          (Char.chr (Char.code (Bytes.get b i) lor (1 lsl (n land 7)))))
      types;
    Bytes.to_string b
  in
  let p ops =
    {
      kind = Active;
      id = 2;
      name = "";
      threshold = 1L;
      operations = ops;
      keys = [];
    }
  in
  let transfer_only = p (bitmap_for [ Ct.TransferContract ]) in
  Alcotest.(check bool)
    "transfer allowed" true
    (allows transfer_only Ct.TransferContract);
  Alcotest.(check bool)
    "contract call not allowed" false
    (allows transfer_only Ct.TriggerSmartContract);
  (* TriggerSmartContract is enum 31, so byte 3 bit 7 -- a case that would pass
     a naive implementation using the wrong byte or bit order. *)
  Alcotest.(check int)
    "TriggerSmartContract is enum 31" 31
    (Ct.to_int Ct.TriggerSmartContract);
  let trigger_only = p (bitmap_for [ Ct.TriggerSmartContract ]) in
  Alcotest.(check bool)
    "trigger allowed" true
    (allows trigger_only Ct.TriggerSmartContract);
  Alcotest.(check bool)
    "transfer no longer allowed" false
    (allows trigger_only Ct.TransferContract);
  (* An owner permission is not restricted by the bitmap. *)
  let owner = { (p "") with kind = Owner } in
  Alcotest.(check bool)
    "owner permits anything" true
    (allows owner Ct.TriggerSmartContract)

let () =
  Alcotest.run "tron-intent"
    [
      ( "derivation",
        [
          Alcotest.test_case "TRX transfer" `Quick test_trx_transfer_intent;
          Alcotest.test_case "TRC-20 transfer" `Quick test_trc20_intent;
          Alcotest.test_case "permission id is shown" `Quick
            test_permission_is_shown;
          Alcotest.test_case "memo and bandwidth" `Quick test_memo_and_bandwidth;
          Alcotest.test_case "rendering shows the dangerous fields" `Quick
            test_rendering_shows_the_dangerous_fields;
          Alcotest.test_case "an unexplained call is marked" `Quick
            test_unexplained_call_is_marked;
        ] );
      ( "policy",
        [
          Alcotest.test_case "TRX transfer accepted" `Quick
            test_trx_policy_accepts;
          Alcotest.test_case "TRX transfer refusals" `Quick
            test_trx_policy_refuses;
          Alcotest.test_case "TRC-20 transfer" `Quick test_trc20_policy;
          Alcotest.test_case "opaque is never approvable" `Quick
            test_opaque_is_never_approvable;
        ] );
      ( "permission",
        [
          Alcotest.test_case "weights" `Quick test_permission_weights;
          Alcotest.test_case "operations bitmap" `Quick
            test_permission_operations_bitmap;
        ] );
    ]
