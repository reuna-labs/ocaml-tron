(* The protobuf decode path: arbitrary bytes in, no crash, and whatever comes
   out must survive a round trip.

   This is the parser that stands between a remote node and a signature, so
   "does not crash" is the floor rather than the goal. The properties that
   matter are that a decoded transaction keeps the bytes it decoded, and that
   nothing this library refuses to build can be conjured by decoding. *)

let () =
  Crowbar.add_test ~name:"Raw_data.of_bytes never raises" [ Crowbar.bytes ]
    (fun s ->
      Crowbar.check
        (match Tron_transaction.Raw_data.of_bytes s with _ -> true))

let () =
  Crowbar.add_test ~name:"Transaction.of_bytes never raises" [ Crowbar.bytes ]
    (fun s ->
      Crowbar.check
        (match Tron_transaction.Transaction.of_bytes s with _ -> true))

let () =
  Crowbar.add_test ~name:"of_broadcast_hex never raises" [ Crowbar.bytes ]
    (fun s ->
      Crowbar.check
        (match Tron_transaction.Transaction.of_broadcast_hex s with _ -> true))

let () =
  Crowbar.add_test ~name:"Intent.derive never raises" [ Crowbar.bytes ]
    (fun s ->
      Crowbar.check (match Tron_transaction.Intent.derive s with _ -> true))

(* Anything that decodes keeps its bytes. This is the property the wire form
   depends on: Transaction.to_bytes frames around the retained raw_data, so if
   of_bytes ever stopped retaining, a signature would cover different bytes
   than the ones broadcast. *)
let () =
  Crowbar.add_test ~name:"a decoded raw_data keeps its bytes" [ Crowbar.bytes ]
    (fun s ->
      match Tron_transaction.Raw_data.of_bytes s with
      | Error _ -> ()
      | Ok raw ->
          Crowbar.check_eq ~pp:Crowbar.pp_string s
            (Tron_transaction.Raw_data.to_bytes raw))

(* And the transaction id follows from those bytes, not from the model. *)
let () =
  Crowbar.add_test ~name:"tx_id is SHA-256 of the retained bytes"
    [ Crowbar.bytes ] (fun s ->
      match Tron_transaction.Raw_data.of_bytes s with
      | Error _ -> ()
      | Ok raw ->
          let expect = Digestif.SHA256.(to_raw_string (digest_string s)) in
          Crowbar.check_eq ~pp:Crowbar.pp_string expect
            (Tron_types.Tx_id.to_bytes (Tron_transaction.Raw_data.tx_id raw)))

(* Whatever an attacker puts in an Any, it must not become approvable. This is
   the invariant the whole contract layer exists to hold. *)
let () =
  Crowbar.add_test ~name:"a decoded transaction is never approved by accident"
    [ Crowbar.bytes ] (fun s ->
      match Tron_transaction.Intent.derive s with
      | Error _ -> ()
      | Ok intent -> (
          match intent.Tron_transaction.Intent.instruction with
          | Tron_transaction.Intent.Opaque _ ->
              (* An opaque contract must fail every policy, unconditionally. *)
              Crowbar.check
                (Result.is_error
                   (Tron_transaction.Intent.validate_trx_transfer intent)
                && Result.is_error
                     (Tron_transaction.Intent.validate_trc20_transfer
                        ~trusted_contracts:[] intent))
          | _ ->
              (* A TRC-20 policy with no trusted contracts can never pass,
                 whatever the bytes said. *)
              Crowbar.check
                (Result.is_error
                   (Tron_transaction.Intent.validate_trc20_transfer
                      ~trusted_contracts:[] intent))))

(* The wire form must carry the signed bytes through, for any transaction that
   decoded -- including ones framed in ways this library would not choose. *)
let () =
  Crowbar.add_test ~name:"the wire form preserves the decoded raw_data"
    [ Crowbar.bytes ] (fun s ->
      match Tron_transaction.Raw_data.of_bytes s with
      | Error _ -> ()
      | Ok raw ->
          let tx = Tron_transaction.Transaction.of_raw_data raw in
          let wire = Tron_transaction.Transaction.to_bytes tx in
          (* field 1, wire type 2: tag 0x0a then a varint length. *)
          Crowbar.check_eq ~pp:Crowbar.pp_int 0x0a (Char.code wire.[0]);
          let i = ref 1 and shift = ref 0 and len = ref 0 and go = ref true in
          while !go do
            let b = Char.code wire.[!i] in
            len := !len lor ((b land 0x7f) lsl !shift);
            shift := !shift + 7;
            incr i;
            if b land 0x80 = 0 then go := false
          done;
          Crowbar.check_eq ~pp:Crowbar.pp_string s (String.sub wire !i !len))
