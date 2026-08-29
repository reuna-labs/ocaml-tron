(* "HTTP and gRPC responses agree" is a G6 launch gate. It is only a testable
   claim because both clients decode into the same types -- two transports each
   with their own result types could never disagree, because they would never
   be compared.

   No socket here. Each transport's decoder is fed a response body the node
   would have sent, and the two resulting values are compared. What is under
   test is the decoding, which is where the two wire formats actually differ:
   JSON with hex-encoded bytes and a `visible` flag on one side, protobuf on
   the other. *)

open Tron_types
module W = Tron_rpc.Wallet
module G = Tron_rpc_grpc.Wallet
module Api = Tron_proto.Api.Protocol
module Tron = Tron_proto.Tron.Protocol
module Writer = Ocaml_protoc_plugin.Writer

let ok name = function
  | Ok v -> v
  | Error _ -> Alcotest.failf "%s: expected Ok" name

let addr h = ok "address" (Address.of_hex h)
let bytes = Bytes.of_string

(* Drive an HTTP Method.t's decoder directly. *)
let http (m : 'a Tron_rpc.Method.t) json =
  match Yojson.Safe.from_string json with
  | exception Yojson.Json_error e -> Alcotest.failf "bad test JSON: %s" e
  | j -> m.Tron_rpc.Method.decode j

(* Drive a gRPC Method_grpc.t's decoder directly. *)
let grpc (m : 'a Tron_rpc_grpc.Method.t) body =
  m.Tron_rpc_grpc.Method.decode body

let alice_hex = "417e5f4552091a69125d5dfcb7b8c2659029395bdf"
let usdt_hex = "41a614f803b6fd780986a42c78ec9c7f77e6ded13c"

(* A block id whose leading eight bytes are the number, as the chain
   guarantees and both decoders check. *)
let block_id_hex number =
  Printf.sprintf "%016Lx%s" number
    (String.concat "" (List.init 24 (fun _ -> "ab")))

let unhex h =
  String.init
    (String.length h / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2)))

(* Blocks *)

let test_block_agrees () =
  let number = 1193046L in
  let id_hex = block_id_hex number in
  let a =
    ok "http"
      (http Tron_rpc.Wallet.now_block
         (Printf.sprintf
            {|{"blockID":"%s","block_header":{"raw_data":{"number":%Ld,"timestamp":1755000000000}}}|}
            id_hex number))
  in
  let b =
    ok "grpc"
      (grpc G.now_block
         (Writer.contents
            (Api.BlockExtention.to_proto
               (Api.BlockExtention.make
                  ~blockid:(bytes (unhex id_hex))
                  ~block_header:
                    (Tron.BlockHeader.make
                       ~raw_data:
                         (Tron.BlockHeader.Raw.make ~number
                            ~timestamp:1755000000000L ())
                       ())
                  ()))))
  in
  Alcotest.(check int64) "number" a.W.number b.W.number;
  Alcotest.(check string) "id" (Tx_id.to_hex a.W.id) (Tx_id.to_hex b.W.id);
  Alcotest.(check int64) "timestamp" a.W.timestamp b.W.timestamp;
  Alcotest.(check bool)
    "reference block" true
    (Block_ref.equal a.W.block_ref b.W.block_ref)

(* Both transports must reject an inconsistent block, not just one of them.
   A check that exists on one wire path and not the other is a check an
   attacker chooses their way around. *)
let test_block_mismatch_rejected_by_both () =
  let id_hex = block_id_hex 1193046L in
  Alcotest.(check bool)
    "http rejects" true
    (Result.is_error
       (http Tron_rpc.Wallet.now_block
          (Printf.sprintf
             {|{"blockID":"%s","block_header":{"raw_data":{"number":99,"timestamp":0}}}|}
             id_hex)));
  Alcotest.(check bool)
    "grpc rejects" true
    (Result.is_error
       (grpc G.now_block
          (Writer.contents
             (Api.BlockExtention.to_proto
                (Api.BlockExtention.make
                   ~blockid:(bytes (unhex id_hex))
                   ~block_header:
                     (Tron.BlockHeader.make
                        ~raw_data:(Tron.BlockHeader.Raw.make ~number:99L ())
                        ())
                   ())))))

(* Accounts *)

let test_account_agrees () =
  let a =
    ok "http"
      (http
         (Tron_rpc.Wallet.account (addr alice_hex))
         (Printf.sprintf
            {|{"address":"%s","balance":123456789,"create_time":1700000000000}|}
            alice_hex))
  in
  let b =
    ok "grpc"
      (grpc
         (G.account (addr alice_hex))
         (Writer.contents
            (Tron.Account.to_proto
               (Tron.Account.make
                  ~address:(bytes (unhex alice_hex))
                  ~balance:123456789L ~create_time:1700000000000L ()))))
  in
  match (a, b) with
  | Some a, Some b ->
      Alcotest.(check string)
        "address"
        (Address.to_hex a.W.address)
        (Address.to_hex b.W.address);
      Alcotest.(check int64)
        "balance" (Sun.to_sun a.W.balance) (Sun.to_sun b.W.balance);
      Alcotest.(check int64) "create_time" a.W.create_time b.W.create_time
  | _ -> Alcotest.fail "one transport lost the account"

(* An account the chain has never seen is an answer, not an error, and it has
   to be the same answer on both wires. HTTP says {}; protobuf says a message
   with an empty address. *)
let test_absent_account_agrees () =
  Alcotest.(check bool)
    "http: absent" true
    (ok "http" (http (Tron_rpc.Wallet.account (addr alice_hex)) "{}") = None);
  Alcotest.(check bool)
    "grpc: absent" true
    (ok "grpc"
       (grpc
          (G.account (addr alice_hex))
          (Writer.contents (Tron.Account.to_proto (Tron.Account.make ()))))
    = None)

let test_resources_agree () =
  let a =
    ok "http"
      (http
         (Tron_rpc.Wallet.account_resources (addr alice_hex))
         {|{"freeNetUsed":10,"freeNetLimit":600,"NetUsed":5,"NetLimit":1000,"EnergyUsed":7,"EnergyLimit":2000}|})
  in
  let b =
    ok "grpc"
      (grpc
         (G.account_resources (addr alice_hex))
         (Writer.contents
            (Api.AccountResourceMessage.to_proto
               (Api.AccountResourceMessage.make ~freeNetUsed:10L
                  ~freeNetLimit:600L ~netUsed:5L ~netLimit:1000L ~energyUsed:7L
                  ~energyLimit:2000L ()))))
  in
  Alcotest.(check int64) "free used" a.W.free_net_used b.W.free_net_used;
  Alcotest.(check int64) "free limit" a.W.free_net_limit b.W.free_net_limit;
  Alcotest.(check int64) "net used" a.W.net_used b.W.net_used;
  Alcotest.(check int64) "net limit" a.W.net_limit b.W.net_limit;
  Alcotest.(check int64) "energy used" a.W.energy_used b.W.energy_used;
  Alcotest.(check int64) "energy limit" a.W.energy_limit b.W.energy_limit

let test_chain_parameters_agree () =
  let a =
    ok "http"
      (http Tron_rpc.Wallet.chain_parameters
         {|{"chainParameter":[{"key":"getEnergyFee","value":210},{"key":"getTransactionFee","value":1000}]}|})
  in
  let b =
    ok "grpc"
      (grpc G.chain_parameters
         (Writer.contents
            (Tron.ChainParameters.to_proto
               [
                 Tron.ChainParameters.ChainParameter.make ~key:"getEnergyFee"
                   ~value:210L ();
                 Tron.ChainParameters.ChainParameter.make
                   ~key:"getTransactionFee" ~value:1000L ();
               ])))
  in
  Alcotest.(check int64) "energy fee" a.W.energy_fee b.W.energy_fee;
  Alcotest.(check int64)
    "transaction fee" a.W.transaction_fee b.W.transaction_fee;
  Alcotest.(check (list (pair string int64))) "raw" a.W.raw b.W.raw

(* Simulation. Both transports report a revert inside `result` with an
   otherwise successful response, and both must refuse to call it an
   estimate. *)
let test_estimate_energy_agrees () =
  let m_http =
    Tron_rpc.Wallet.estimate_energy ~owner:(addr alice_hex)
      ~contract:(addr usdt_hex) ~data:"\xa9\x05\x9c\xbb" ()
  in
  let m_grpc =
    G.estimate_energy ~owner:(addr alice_hex) ~contract:(addr usdt_hex)
      ~data:"\xa9\x05\x9c\xbb" ()
  in
  let a =
    ok "http"
      (http m_http {|{"result":{"result":true},"energy_required":31895}|})
  in
  let b =
    ok "grpc"
      (grpc m_grpc
         (Writer.contents
            (Api.EstimateEnergyMessage.to_proto
               (Api.EstimateEnergyMessage.make
                  ~result:(Api.Return.make ~result:true ())
                  ~energy_required:31895L ()))))
  in
  Alcotest.(check int64) "energy required" a b;
  (* And the revert, on both. *)
  Alcotest.(check bool)
    "http refuses a revert" true
    (Result.is_error
       (http m_http
          {|{"result":{"result":false,"message":"52455645525420"},"energy_required":0}|}));
  Alcotest.(check bool)
    "grpc refuses a revert" true
    (Result.is_error
       (grpc m_grpc
          (Writer.contents
             (Api.EstimateEnergyMessage.to_proto
                (Api.EstimateEnergyMessage.make
                   ~result:
                     (Api.Return.make ~result:false ~message:(bytes "REVERT") ())
                   ())))))

let test_receipt_agrees () =
  let id =
    ok "id" (Tx_id.of_hex (String.concat "" (List.init 32 (fun _ -> "cd"))))
  in
  let a =
    ok "http"
      (http
         (Tron_rpc.Wallet.transaction_info id)
         (Printf.sprintf
            {|{"id":"%s","blockNumber":1001,"blockTimeStamp":1755000000000,"fee":1000,"receipt":{"net_usage":270,"energy_usage_total":31895}}|}
            (Tx_id.to_hex id)))
  in
  let b =
    ok "grpc"
      (grpc (G.transaction_info id)
         (Writer.contents
            (Tron.TransactionInfo.to_proto
               (Tron.TransactionInfo.make
                  ~id:(bytes (Tx_id.to_bytes id))
                  ~blockNumber:1001L ~blockTimeStamp:1755000000000L ~fee:1000L
                  ~receipt:
                    (Tron.ResourceReceipt.make ~net_usage:270L
                       ~energy_usage_total:31895L ())
                  ()))))
  in
  match (a, b) with
  | Some a, Some b ->
      Alcotest.(check string)
        "id" (Tx_id.to_hex a.W.tx_id) (Tx_id.to_hex b.W.tx_id);
      Alcotest.(check int64) "block" a.W.block_number b.W.block_number;
      Alcotest.(check int64) "fee" a.W.fee b.W.fee;
      Alcotest.(check int64) "bandwidth" a.W.net_usage b.W.net_usage;
      Alcotest.(check int64)
        "energy" a.W.energy_usage_total b.W.energy_usage_total;
      Alcotest.(check bool) "succeeded" a.W.succeeded b.W.succeeded
  | _ -> Alcotest.fail "one transport lost the receipt"

let test_pending_receipt_agrees () =
  let id =
    ok "id" (Tx_id.of_hex (String.concat "" (List.init 32 (fun _ -> "cd"))))
  in
  Alcotest.(check bool)
    "http: pending" true
    (ok "http" (http (Tron_rpc.Wallet.transaction_info id) "{}") = None);
  Alcotest.(check bool)
    "grpc: pending" true
    (ok "grpc"
       (grpc (G.transaction_info id)
          (Writer.contents
             (Tron.TransactionInfo.to_proto (Tron.TransactionInfo.make ()))))
    = None)

(* A reverted transaction must be reported as reverted on both wires. HTTP
   omits `result` on success and sets it to FAILED on failure; protobuf carries
   an enum. Getting either backwards reports a lost fee as a success. *)
let test_revert_agrees () =
  let id =
    ok "id" (Tx_id.of_hex (String.concat "" (List.init 32 (fun _ -> "ef"))))
  in
  let a =
    ok "http"
      (http
         (Tron_rpc.Wallet.transaction_info id)
         (Printf.sprintf
            {|{"id":"%s","result":"FAILED","resMessage":"5245564552541122"}|}
            (Tx_id.to_hex id)))
  in
  let b =
    ok "grpc"
      (grpc (G.transaction_info id)
         (Writer.contents
            (Tron.TransactionInfo.to_proto
               (Tron.TransactionInfo.make
                  ~id:(bytes (Tx_id.to_bytes id))
                  ~result:Tron.TransactionInfo.Code.FAILED
                  ~resMessage:(bytes "REVERT\x11\x22") ()))))
  in
  match (a, b) with
  | Some a, Some b ->
      Alcotest.(check bool) "http says failed" false a.W.succeeded;
      Alcotest.(check bool) "grpc says failed" false b.W.succeeded;
      Alcotest.(check string)
        "same message" a.W.result_message b.W.result_message
  | _ -> Alcotest.fail "one transport lost the receipt"

(* The broadcast request must be the signed bytes, unmodified. gRPC would
   otherwise re-encode a decoded model and change the transaction id. *)
let test_broadcast_sends_the_signed_bytes () =
  let wire = "\x0a\x03\x01\x02\x03\x12\x02\xaa\xbb" in
  let m = G.broadcast wire in
  Alcotest.(check string)
    "request is the wire form verbatim" wire m.Tron_rpc_grpc.Method.request;
  Alcotest.(check string)
    "service" "protocol.Wallet" m.Tron_rpc_grpc.Method.service;
  Alcotest.(check string)
    "rpc" "BroadcastTransaction" m.Tron_rpc_grpc.Method.rpc;
  let r =
    ok "decode"
      (grpc m
         (Writer.contents
            (Api.Return.to_proto (Api.Return.make ~result:true ()))))
  in
  Alcotest.(check bool) "accepted" true r.W.accepted

(* The service and method names come from the generated stubs, not from strings
   typed twice. If a schema bump renames one, this notices. *)
let test_method_names_come_from_the_schema () =
  Alcotest.(check string)
    "now_block service" "protocol.Wallet"
    Tron_rpc_grpc.Wallet.now_block.Tron_rpc_grpc.Method.service;
  Alcotest.(check string)
    "now_block rpc" "GetNowBlock2"
    Tron_rpc_grpc.Wallet.now_block.Tron_rpc_grpc.Method.rpc;
  Alcotest.(check string)
    "chain_parameters rpc" "GetChainParameters"
    Tron_rpc_grpc.Wallet.chain_parameters.Tron_rpc_grpc.Method.rpc;
  Alcotest.(check string)
    "estimate_energy rpc" "EstimateEnergy"
    (G.estimate_energy ~owner:(addr alice_hex) ~contract:(addr usdt_hex)
       ~data:"" ())
      .Tron_rpc_grpc.Method.rpc

let () =
  Alcotest.run "tron-grpc-parity"
    [
      ( "reads agree",
        [
          Alcotest.test_case "block" `Quick test_block_agrees;
          Alcotest.test_case "account" `Quick test_account_agrees;
          Alcotest.test_case "absent account" `Quick test_absent_account_agrees;
          Alcotest.test_case "resources" `Quick test_resources_agree;
          Alcotest.test_case "chain parameters" `Quick
            test_chain_parameters_agree;
          Alcotest.test_case "energy estimate" `Quick
            test_estimate_energy_agrees;
          Alcotest.test_case "receipt" `Quick test_receipt_agrees;
          Alcotest.test_case "pending receipt" `Quick
            test_pending_receipt_agrees;
          Alcotest.test_case "revert" `Quick test_revert_agrees;
        ] );
      ( "refusals agree",
        [
          Alcotest.test_case "inconsistent block" `Quick
            test_block_mismatch_rejected_by_both;
        ] );
      ( "broadcast",
        [
          Alcotest.test_case "sends the signed bytes" `Quick
            test_broadcast_sends_the_signed_bytes;
          Alcotest.test_case "names come from the schema" `Quick
            test_method_names_come_from_the_schema;
        ] );
    ]
