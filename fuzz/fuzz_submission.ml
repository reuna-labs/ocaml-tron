(* The submission state machine, driven by an adversary rather than a workflow.

   Events arrive in whatever order a hostile or broken node produces them:
   duplicated, out of sequence, interleaved with failures. The machine must
   terminate, must never ask for a broadcast of bytes it has already been told
   expired, and must never claim finality it was not shown. *)

module S = Tron_rpc.Submission

let tx_id = Result.get_ok (Tron_types.Tx_id.of_hex (String.make 64 'd'))

let head_block number =
  let id =
    Result.get_ok
      (Tron_types.Tx_id.of_hex
         (Printf.sprintf "%016Lx%s" number (String.make 48 'e')))
  in
  {
    Tron_rpc.Wallet.number;
    id;
    block_ref = Tron_types.Block_ref.of_block_id id;
    timestamp = 0L;
  }

let receipt ~succeeded ~block =
  Some
    {
      Tron_rpc.Wallet.tx_id;
      block_number = block;
      block_timestamp = 0L;
      fee = 0L;
      net_usage = 0L;
      energy_usage_total = 0L;
      succeeded;
      result_message = "";
    }

type event =
  | Reference_block of int64
  | Signed
  | Broadcast_ok
  | Broadcast_rejected of string
  | Receipt of bool * int64
  | No_receipt
  | Head of int64
  | Failed
  | Expired

let event =
  Crowbar.choose
    [
      Crowbar.map
        [ Crowbar.range 1000 ]
        (fun n -> Reference_block (Int64.of_int n));
      Crowbar.const Signed;
      Crowbar.const Broadcast_ok;
      Crowbar.map [ Crowbar.bytes ] (fun s -> Broadcast_rejected s);
      Crowbar.map
        [ Crowbar.bool; Crowbar.range 1000 ]
        (fun ok n -> Receipt (ok, Int64.of_int n));
      Crowbar.const No_receipt;
      Crowbar.map [ Crowbar.range 2000 ] (fun n -> Head (Int64.of_int n));
      Crowbar.const Failed;
      Crowbar.const Expired;
    ]

let apply s = function
  | Reference_block n -> S.got_reference_block s (head_block n)
  | Signed -> S.got_signed s ~tx_id ~hex:"deadbeef" ~expiration:1755000000000L
  | Broadcast_ok ->
      S.got_broadcast s
        {
          Tron_rpc.Wallet.accepted = true;
          code = None;
          message = None;
          tx_id = None;
        }
  | Broadcast_rejected m ->
      S.got_broadcast s
        {
          Tron_rpc.Wallet.accepted = false;
          code = Some "X";
          message = Some m;
          tx_id = None;
        }
  | Receipt (ok, block) -> S.got_receipt s (receipt ~succeeded:ok ~block)
  | No_receipt -> S.got_receipt s None
  | Head n -> S.got_head s n
  | Failed -> S.failed s (Tron_rpc.Error.Transport "injected")
  | Expired -> S.expired s

let () =
  Crowbar.add_test ~name:"any event sequence terminates without raising"
    [ Crowbar.list event ]
    (fun events ->
      let s = List.fold_left apply (S.start ()) events in
      Crowbar.check (match S.step s with _ -> true))

(* The property the machine exists for: once expiry has been observed, the
   machine may never hand back the bytes it already signed. It has to rebuild,
   because those bytes name a reference block the chain has moved past. *)
let () =
  Crowbar.add_test ~name:"expiry is never followed by a replay"
    [ Crowbar.list event ]
    (fun events ->
      let rec go s expired = function
        | [] -> ()
        | e :: rest ->
            let s = apply s e in
            let expired = expired || e = Expired in
            (* A rebuild clears it: the caller is being told to start over, and
               what it produces next is a new signature over new bytes. *)
            let expired =
              match S.step s with S.Rebuild _ -> false | _ -> expired
            in
            (match (expired, S.step s) with
            | true, S.Need_broadcast _ ->
                Crowbar.fail
                  "asked to broadcast after expiry without rebuilding"
            | _ -> ());
            go s expired rest
      in
      go (S.start ()) false events)

(* Finality is never claimed without a head deep enough to justify it. *)
let () =
  Crowbar.add_test ~name:"Done is only reached with evidence"
    [ Crowbar.list event ]
    (fun events ->
      let s = List.fold_left apply (S.start ()) events in
      match S.step s with
      | S.Done { confirmation; _ } -> (
          match confirmation with
          | Tron_rpc.Confirmation.In_block { depth; _ } ->
              (* The default config requires 19. *)
              Crowbar.check (Int64.compare depth 19L >= 0)
          | Tron_rpc.Confirmation.Failed _ -> ()
          | Tron_rpc.Confirmation.Unknown ->
              Crowbar.fail "finished without ever seeing the transaction")
      | _ -> ())
