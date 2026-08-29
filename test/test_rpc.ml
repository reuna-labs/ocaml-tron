(* The transport boundary exists so the client can be exercised without a
   socket. These tests have none: replies are canned, and what is under test is
   the decoding and the state machine's decisions -- especially the ones it
   makes when things go wrong. *)

open Tron_types
open Tron_rpc

let ok name = function
  | Ok v -> v
  | Error _ -> Alcotest.failf "%s: expected Ok" name

let addr h = ok "address" (Address.of_hex h)

(* A provider that answers from a table, so a test can say exactly what the node
   said and nothing else is in the way. *)
module Canned = struct
  type t = { replies : (string * string) list; mutable asked : string list }
  type 'a io = 'a

  let return x = x
  let bind x f = f x

  let exchange t ~path _body =
    t.asked <- path :: t.asked;
    match List.assoc_opt path t.replies with
    | Some raw -> Ok raw
    | None -> Error (Error.Transport ("no canned reply for " ^ path))
end

module P = Provider.Of_text (Canned)
module Client = Provider.Make (P)

let node replies = { Canned.replies; asked = [] }
let call n m = Client.call n m

(* java-tron reports failure with a 200 and an Error member. A transport that
   only checked the status would call this a success. *)
let test_error_member_is_a_failure () =
  let n =
    node
      [
        ( "/wallet/getnowblock",
          {|{"Error":"636f6e74726163742076616c69646174652065727726"}|} );
      ]
  in
  match call n Wallet.now_block with
  | Ok _ -> Alcotest.fail "an Error member was read as success"
  | Error (Error.Node { message; _ }) ->
      (* The message is hex-encoded in this shape and must be decoded. *)
      Alcotest.(check bool)
        "message was hex-decoded" true
        (String.length message > 0 && message.[0] = 'c')
  | Error e -> Alcotest.failf "wrong error: %a" Error.pp e

let test_plain_error_member () =
  let n = node [ ("/wallet/getnowblock", {|{"Error":"not hex at all"}|}) ] in
  match call n Wallet.now_block with
  | Error (Error.Node { message; _ }) ->
      (* A message that is not hex is passed through rather than dropped: an
         error you cannot decode is still worth showing. *)
      Alcotest.(check string) "passed through" "not hex at all" message
  | _ -> Alcotest.fail "expected a node error"

let block_json ~number ~id =
  Printf.sprintf
    {|{"blockID":"%s","block_header":{"raw_data":{"number":%Ld,"timestamp":1755000000000}}}|}
    id number

(* The blockID's leading eight bytes are the block number. A node whose two
   halves disagree is one nothing may be built on. *)
let good_id number = Printf.sprintf "%016Lx%s" number (String.make 48 'a')

let test_block_decoding () =
  let number = 1193046L in
  let n =
    node [ ("/wallet/getnowblock", block_json ~number ~id:(good_id number)) ]
  in
  let b = ok "now_block" (call n Wallet.now_block) in
  Alcotest.(check int64) "number" number b.Wallet.number;
  Alcotest.(check string)
    "ref_block_bytes is [6,8) of the number" "3456"
    (String.concat ""
       (List.map
          (fun c -> Printf.sprintf "%02x" (Char.code c))
          (List.init 2 (String.get (Block_ref.block_bytes b.Wallet.block_ref)))))

let test_block_number_id_mismatch_rejected () =
  let n =
    node
      [ ("/wallet/getnowblock", block_json ~number:99L ~id:(good_id 1193046L)) ]
  in
  match call n Wallet.now_block with
  | Error (Error.Invalid_response _) -> ()
  | Ok _ -> Alcotest.fail "an inconsistent block was accepted"
  | Error e -> Alcotest.failf "wrong error: %a" Error.pp e

(* An address the chain has never seen answers {}. That is an answer, not a
   failure -- Tron accounts are created by being funded. *)
let test_absent_account_is_not_an_error () =
  let n = node [ ("/wallet/getaccount", "{}") ] in
  match
    call n (Wallet.account (addr "417e5f4552091a69125d5dfcb7b8c2659029395bdf"))
  with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "an empty object became an account"
  | Error e ->
      Alcotest.failf "an absent account was reported as an error: %a" Error.pp e

let test_unconfirmed_receipt_is_not_a_failure () =
  let n = node [ ("/wallet/gettransactioninfobyid", "{}") ] in
  let id = ok "id" (Tx_id.of_hex (String.make 64 'b')) in
  match call n (Wallet.transaction_info id) with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "an empty object became a receipt"
  | Error e -> Alcotest.failf "pending was reported as an error: %a" Error.pp e

(* A reverting simulation reports success at the transport level and failure
   inside `result`. Reading energy_required without looking would turn a revert
   into a confident estimate. *)
let test_failed_simulation_is_an_error () =
  let n =
    node
      [
        ( "/wallet/estimateenergy",
          {|{"result":{"result":false,"message":"52455645525420"},"energy_required":0}|}
        );
      ]
  in
  let m =
    Wallet.estimate_energy
      ~owner:(addr "417e5f4552091a69125d5dfcb7b8c2659029395bdf")
      ~contract:(addr "41a614f803b6fd780986a42c78ec9c7f77e6ded13c")
      ~data:"\xa9\x05\x9c\xbb" ()
  in
  match call n m with
  | Error (Error.Invalid_response _) -> ()
  | Ok e -> Alcotest.failf "a reverting simulation returned %Ld" e
  | Error e -> Alcotest.failf "wrong error: %a" Error.pp e

let test_successful_simulation () =
  let n =
    node
      [
        ( "/wallet/estimateenergy",
          {|{"result":{"result":true},"energy_required":31895}|} );
      ]
  in
  let m =
    Wallet.estimate_energy
      ~owner:(addr "417e5f4552091a69125d5dfcb7b8c2659029395bdf")
      ~contract:(addr "41a614f803b6fd780986a42c78ec9c7f77e6ded13c")
      ~data:"\xa9\x05\x9c\xbb" ()
  in
  Alcotest.(check int64) "energy" 31895L (ok "estimate" (call n m))

(* Fees *)

let params ~energy_fee ~transaction_fee =
  { Wallet.energy_fee; transaction_fee; raw = [] }

let resources ~free_used ~free_limit ~net_used ~net_limit =
  {
    Wallet.free_net_used = free_used;
    free_net_limit = free_limit;
    net_used;
    net_limit;
    energy_used = 0L;
    energy_limit = 0L;
  }

let test_bandwidth_order () =
  let p = params ~energy_fee:210L ~transaction_fee:1000L in
  (* Free quota first. *)
  (match
     Fees.bandwidth_charge ~params:p
       ~resources:
         (resources ~free_used:0L ~free_limit:600L ~net_used:0L ~net_limit:0L)
       ~size:270
   with
  | Fees.Free { points } -> Alcotest.(check int64) "free covers it" 270L points
  | other ->
      Alcotest.failf "expected Free, got %s"
        (match other with Fees.Staked _ -> "Staked" | _ -> "Burned"));
  (* Free exhausted, staked available. *)
  (match
     Fees.bandwidth_charge ~params:p
       ~resources:
         (resources ~free_used:600L ~free_limit:600L ~net_used:0L
            ~net_limit:5000L)
       ~size:270
   with
  | Fees.Staked { points } ->
      Alcotest.(check int64) "staked covers it" 270L points
  | _ -> Alcotest.fail "expected Staked");
  (* Neither: burn at getTransactionFee per byte. *)
  match
    Fees.bandwidth_charge ~params:p
      ~resources:
        (resources ~free_used:600L ~free_limit:600L ~net_used:0L ~net_limit:0L)
      ~size:270
  with
  | Fees.Burned { sun } ->
      Alcotest.(check int64) "270 bytes at 1000 sun" 270_000L (Sun.to_sun sun)
  | _ -> Alcotest.fail "expected Burned"

let test_fee_limit_arithmetic () =
  let p = params ~energy_fee:210L ~transaction_fee:1000L in
  Alcotest.(check int64)
    "energy x rate" 6_697_950L
    (Sun.to_sun (Fees.fee_limit_for_energy ~params:p ~energy:31895L));
  Alcotest.(check int64)
    "with 20% headroom" 8_037_540L
    (Sun.to_sun (Fees.suggested_fee_limit ~params:p ~energy:31895L ()));
  Alcotest.(check int64)
    "with no headroom" 6_697_950L
    (Sun.to_sun
       (Fees.suggested_fee_limit ~params:p ~energy:31895L ~headroom_percent:0 ()))

(* Confirmation is a tagged state, never a boolean. *)
let test_confirmation_states () =
  let id = ok "id" (Tx_id.of_hex (String.make 64 'c')) in
  let receipt ~succeeded ~block =
    Some
      {
        Wallet.tx_id = id;
        block_number = block;
        block_timestamp = 0L;
        fee = 0L;
        net_usage = 0L;
        energy_usage_total = 0L;
        succeeded;
        result_message = (if succeeded then "" else "REVERT");
      }
  in
  Alcotest.(check bool)
    "unseen is not final" false
    (Confirmation.is_final ~depth:19L (Confirmation.of_receipt ~head:100L None));
  (* Included but shallow. *)
  Alcotest.(check bool)
    "shallow is not final" false
    (Confirmation.is_final ~depth:19L
       (Confirmation.of_receipt ~head:100L (receipt ~succeeded:true ~block:95L)));
  Alcotest.(check bool)
    "deep enough is final" true
    (Confirmation.is_final ~depth:19L
       (Confirmation.of_receipt ~head:120L
          (receipt ~succeeded:true ~block:100L)));
  (* A reverted transaction is on chain and charged a fee. It is finished, but
     it is never "final" in the sense a caller means when asking. *)
  Alcotest.(check bool)
    "a revert is never final" false
    (Confirmation.is_final ~depth:0L
       (Confirmation.of_receipt ~head:1000L
          (receipt ~succeeded:false ~block:100L)))

(* The state machine, driven through the paths that matter. *)

let signed_id = lazy (ok "id" (Tx_id.of_hex (String.make 64 'd')))

let head_block number =
  {
    Wallet.number;
    id =
      ok "id"
        (Tx_id.of_hex (Printf.sprintf "%016Lx%s" number (String.make 48 'e')));
    block_ref =
      Block_ref.of_block_id
        (ok "id"
           (Tx_id.of_hex
              (Printf.sprintf "%016Lx%s" number (String.make 48 'e'))));
    timestamp = 0L;
  }

let through_to_polling ?config () =
  let s = Submission.start ?config () in
  let s = Submission.got_reference_block s (head_block 1000L) in
  let s =
    Submission.got_signed s ~tx_id:(Lazy.force signed_id) ~hex:"deadbeef"
      ~expiration:1755000000000L
  in
  s

let accepted =
  { Wallet.accepted = true; code = None; message = None; tx_id = None }

let rejected ?code ?message () =
  { Wallet.accepted = false; code; message; tx_id = None }

let test_happy_path () =
  let s = through_to_polling () in
  (match Submission.step s with
  | Submission.Need_broadcast { hex } ->
      Alcotest.(check string) "sends the signed bytes" "deadbeef" hex
  | _ -> Alcotest.fail "expected Need_broadcast");
  let s = Submission.got_broadcast s accepted in
  (match Submission.step s with
  | Submission.Need_receipt _ -> ()
  | _ -> Alcotest.fail "expected Need_receipt");
  let receipt =
    Some
      {
        Wallet.tx_id = Lazy.force signed_id;
        block_number = 1001L;
        block_timestamp = 0L;
        fee = 0L;
        net_usage = 270L;
        energy_usage_total = 0L;
        succeeded = true;
        result_message = "";
      }
  in
  let s = Submission.got_receipt s receipt in
  let s = Submission.got_head s 1030L in
  match Submission.step s with
  | Submission.Done { confirmation; _ } ->
      Alcotest.(check bool)
        "final" true
        (Confirmation.is_final ~depth:19L confirmation)
  | _ -> Alcotest.fail "expected Done"

(* Expiry must produce a rebuild, never a resubmission of the bytes already
   signed. This is the whole point of the machine. *)
let test_expiry_forces_rebuild () =
  let s = through_to_polling () in
  let s = Submission.got_broadcast s accepted in
  let s = Submission.expired s in
  match Submission.step s with
  | Submission.Rebuild _ -> ()
  | Submission.Need_broadcast _ ->
      Alcotest.fail "expiry led to a replay of stale signed bytes"
  | _ -> Alcotest.fail "expected Rebuild"

let test_stale_reference_block_rejection_rebuilds () =
  let s = through_to_polling () in
  let s =
    Submission.got_broadcast s
      (rejected ~code:"TAPOS_ERROR" ~message:"Tapos check error" ())
  in
  match Submission.step s with
  | Submission.Rebuild _ -> ()
  | _ -> Alcotest.fail "a stale-block rejection should rebuild"

(* Every other rejection is the transaction being wrong. Sending it again will
   not make it right. *)
let test_other_rejection_gives_up () =
  let s = through_to_polling () in
  let s =
    Submission.got_broadcast s
      (rejected ~code:"CONTRACT_VALIDATE_ERROR"
         ~message:"Validate TransferContract error" ())
  in
  match Submission.step s with
  | Submission.Give_up { reason } ->
      Alcotest.(check bool) "reason is carried" true (String.length reason > 0)
  | Submission.Rebuild _ ->
      Alcotest.fail "a validation error should not be retried"
  | _ -> Alcotest.fail "expected Give_up"

(* A broadcast that failed in transit may still have been accepted, so the
   machine polls rather than sending again. *)
let test_transport_failure_polls_rather_than_resends () =
  let s = through_to_polling () in
  let s = Submission.failed s (Error.Transport "connection reset") in
  match Submission.step s with
  | Submission.Need_receipt _ -> ()
  | Submission.Need_broadcast _ ->
      Alcotest.fail "resent after a transport failure without checking first"
  | _ -> Alcotest.fail "expected Need_receipt"

let test_poll_budget_is_bounded () =
  let config =
    {
      Submission.max_broadcast_attempts = 3;
      max_polls = 3;
      required_depth = 19L;
    }
  in
  let s = through_to_polling ~config () in
  let s = Submission.got_broadcast s accepted in
  let rec poll s n =
    if n = 0 then s else poll (Submission.got_receipt s None) (n - 1)
  in
  let s = poll s 3 in
  match Submission.step s with
  | Submission.Give_up _ -> ()
  | _ -> Alcotest.fail "polling should be bounded"

let test_rebuild_budget_is_bounded () =
  let config =
    {
      Submission.max_broadcast_attempts = 1;
      max_polls = 20;
      required_depth = 19L;
    }
  in
  let s = through_to_polling ~config () in
  let s = Submission.got_broadcast s accepted in
  let s = Submission.expired s in
  match Submission.step s with
  | Submission.Give_up _ -> ()
  | Submission.Rebuild _ -> Alcotest.fail "rebuilt past the attempt budget"
  | _ -> Alcotest.fail "expected Give_up"

let test_shallow_inclusion_keeps_polling () =
  let s = through_to_polling () in
  let s = Submission.got_broadcast s accepted in
  let receipt =
    Some
      {
        Wallet.tx_id = Lazy.force signed_id;
        block_number = 1001L;
        block_timestamp = 0L;
        fee = 0L;
        net_usage = 0L;
        energy_usage_total = 0L;
        succeeded = true;
        result_message = "";
      }
  in
  let s = Submission.got_receipt s receipt in
  let s = Submission.got_head s 1002L in
  match Submission.step s with
  | Submission.Need_receipt _ ->
      Alcotest.(check int64) "head is retained" 1002L (Submission.head s)
  | Submission.Done _ -> Alcotest.fail "one block deep was treated as final"
  | _ -> Alcotest.fail "expected to keep polling"

let test_revert_finishes_immediately () =
  let s = through_to_polling () in
  let s = Submission.got_broadcast s accepted in
  let receipt =
    Some
      {
        Wallet.tx_id = Lazy.force signed_id;
        block_number = 1001L;
        block_timestamp = 0L;
        fee = 1_000_000L;
        net_usage = 0L;
        energy_usage_total = 30000L;
        succeeded = false;
        result_message = "REVERT";
      }
  in
  let s = Submission.got_receipt s receipt in
  let s = Submission.got_head s 1002L in
  match Submission.step s with
  | Submission.Done { confirmation = Confirmation.Failed _; _ } -> ()
  | Submission.Done _ -> Alcotest.fail "a revert was reported as success"
  | _ -> Alcotest.fail "a revert should finish rather than keep polling"

let () =
  Alcotest.run "tron-rpc"
    [
      ( "decoding",
        [
          Alcotest.test_case "an Error member is a failure" `Quick
            test_error_member_is_a_failure;
          Alcotest.test_case "a non-hex error message survives" `Quick
            test_plain_error_member;
          Alcotest.test_case "block" `Quick test_block_decoding;
          Alcotest.test_case "block number/id mismatch rejected" `Quick
            test_block_number_id_mismatch_rejected;
          Alcotest.test_case "an absent account is not an error" `Quick
            test_absent_account_is_not_an_error;
          Alcotest.test_case "an unconfirmed receipt is not a failure" `Quick
            test_unconfirmed_receipt_is_not_a_failure;
          Alcotest.test_case "a reverting simulation is an error" `Quick
            test_failed_simulation_is_an_error;
          Alcotest.test_case "a successful simulation" `Quick
            test_successful_simulation;
        ] );
      ( "fees",
        [
          Alcotest.test_case "bandwidth is charged in order" `Quick
            test_bandwidth_order;
          Alcotest.test_case "fee limit arithmetic" `Quick
            test_fee_limit_arithmetic;
        ] );
      ( "confirmation",
        [ Alcotest.test_case "states" `Quick test_confirmation_states ] );
      ( "submission",
        [
          Alcotest.test_case "happy path" `Quick test_happy_path;
          Alcotest.test_case "expiry forces a rebuild, never a replay" `Quick
            test_expiry_forces_rebuild;
          Alcotest.test_case "a stale reference block rebuilds" `Quick
            test_stale_reference_block_rejection_rebuilds;
          Alcotest.test_case "other rejections give up" `Quick
            test_other_rejection_gives_up;
          Alcotest.test_case "a transport failure polls rather than resends"
            `Quick test_transport_failure_polls_rather_than_resends;
          Alcotest.test_case "polling is bounded" `Quick
            test_poll_budget_is_bounded;
          Alcotest.test_case "rebuilding is bounded" `Quick
            test_rebuild_budget_is_bounded;
          Alcotest.test_case "shallow inclusion keeps polling" `Quick
            test_shallow_inclusion_keeps_polling;
          Alcotest.test_case "a revert finishes immediately" `Quick
            test_revert_finishes_immediately;
        ] );
    ]
