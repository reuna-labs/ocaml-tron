(* java-tron's JSON decoders, on input a node did not send.

   These sit between a remote peer and a policy decision, so the floor is that
   nothing crashes and nothing invalid decodes. The specific trap being tested
   is the one the shape invites: a decoder that reads a number where it wanted
   an address, or accepts a block whose two halves disagree. *)

let json = Crowbar.map [ Crowbar.bytes ] (fun s -> s)

let try_decode (m : 'a Tron_rpc.Method.t) s =
  match Yojson.Safe.from_string s with
  | exception _ -> `Not_json
  | j -> (
      match m.Tron_rpc.Method.decode j with
      | Ok v -> `Ok v
      | Error _ -> `Rejected)

let addr =
  Result.get_ok
    (Tron_types.Address.of_hex "417e5f4552091a69125d5dfcb7b8c2659029395bdf")

let tx_id = Result.get_ok (Tron_types.Tx_id.of_hex (String.make 64 'a'))

let () =
  Crowbar.add_test ~name:"now_block never raises" [ json ] (fun s ->
      Crowbar.check
        (match try_decode Tron_rpc.Wallet.now_block s with _ -> true))

let () =
  Crowbar.add_test ~name:"account never raises" [ json ] (fun s ->
      Crowbar.check
        (match try_decode (Tron_rpc.Wallet.account addr) s with _ -> true))

let () =
  Crowbar.add_test ~name:"account_resources never raises" [ json ] (fun s ->
      Crowbar.check
        (match try_decode (Tron_rpc.Wallet.account_resources addr) s with
        | _ -> true))

let () =
  Crowbar.add_test ~name:"chain_parameters never raises" [ json ] (fun s ->
      Crowbar.check
        (match try_decode Tron_rpc.Wallet.chain_parameters s with _ -> true))

let () =
  Crowbar.add_test ~name:"transaction_info never raises" [ json ] (fun s ->
      Crowbar.check
        (match try_decode (Tron_rpc.Wallet.transaction_info tx_id) s with
        | _ -> true))

let () =
  Crowbar.add_test ~name:"broadcast never raises" [ json ] (fun s ->
      Crowbar.check
        (match try_decode (Tron_rpc.Wallet.broadcast_hex "00") s with
        | _ -> true))

(* A block whose number and id disagree must never decode, however the JSON is
   arranged. This is the check that binds a reference block to a chain, and a
   Tron transaction has no other. *)
let () =
  Crowbar.add_test ~name:"an inconsistent block never decodes"
    [ Crowbar.int64; Crowbar.bytes_fixed 24 ]
    (fun number tail ->
      let id =
        Printf.sprintf "%016Lx%s" number
          (String.concat ""
             (List.init 24 (fun i -> Printf.sprintf "%02x" (Char.code tail.[i]))))
      in
      (* Claim a different number than the id encodes. *)
      let wrong = Int64.add number 1L in
      let body =
        Printf.sprintf
          {|{"blockID":"%s","block_header":{"raw_data":{"number":%Ld,"timestamp":0}}}|}
          id wrong
      in
      match try_decode Tron_rpc.Wallet.now_block body with
      | `Ok _ -> Crowbar.fail "a block with a mismatched number decoded"
      | `Rejected | `Not_json -> ())

(* And a consistent one always does, so the check above is not passing by
   rejecting everything. *)
let () =
  Crowbar.add_test ~name:"a consistent block always decodes"
    [ Crowbar.range 1000000; Crowbar.bytes_fixed 24 ]
    (fun n tail ->
      let number = Int64.of_int n in
      let id =
        Printf.sprintf "%016Lx%s" number
          (String.concat ""
             (List.init 24 (fun i -> Printf.sprintf "%02x" (Char.code tail.[i]))))
      in
      let body =
        Printf.sprintf
          {|{"blockID":"%s","block_header":{"raw_data":{"number":%Ld,"timestamp":0}}}|}
          id number
      in
      match try_decode Tron_rpc.Wallet.now_block body with
      | `Ok b ->
          Crowbar.check_eq
            ~pp:(fun ppf -> Format.fprintf ppf "%Ld")
            number b.Tron_rpc.Wallet.number
      | `Rejected -> Crowbar.fail "a consistent block was rejected"
      | `Not_json -> Crowbar.fail "generated JSON was not JSON")
