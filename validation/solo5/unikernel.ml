(* Exercises the offline path end to end, in one executable that links no
   transport: derive an address, build a transaction, hash it, sign it, recover
   the signer, and derive the intent back out of the bytes.

   The point is the link, not the output -- see dune. But it runs, because a
   target that only ever compiles stops being checked the moment someone
   silences it. *)

let unhex h =
  String.init
    (String.length h / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2)))

let hex s =
  String.concat ""
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let get msg = function
  | Ok v -> v
  | Error _ ->
      prerr_endline ("offline path failed at: " ^ msg);
      exit 1

let () =
  (* A key with no funds and no secret worth keeping: the smallest valid
     secp256k1 scalar. *)
  let sk =
    get "private key"
      (Tron_crypto.private_key_of_bytes (unhex (String.make 63 '0' ^ "1")))
  in
  let from = Tron_crypto.address_of_private_key sk in
  Printf.printf "address        %s\n" (Tron_types.Address.to_base58check from);

  let to_ =
    get "destination"
      (Tron_types.Address.of_hex "412b5ad5c4795c026514f8317c7a215e218dccd6cf")
  in
  let block_id =
    get "block id"
      (Tron_types.Tx_id.of_hex ("0000000000123456" ^ String.make 48 'a'))
  in
  let block_ref = Tron_types.Block_ref.of_block_id block_id in

  (* Nothing here reads a clock: expiration is an input, as it is everywhere in
     this library. *)
  let raw =
    get "raw_data"
      (Tron_transaction.Raw_data.make ~block_ref ~expiration:1755000000000L
         ~timestamp:1754999940000L
         (Tron_transaction.Contract.Transfer
            {
              owner = from;
              to_;
              amount = get "amount" (Tron_types.Sun.of_sun 1_000_000L);
            }))
  in
  Printf.printf "raw_data       %d bytes\n"
    (String.length (Tron_transaction.Raw_data.to_bytes raw));
  Printf.printf "txID           %s\n"
    (Tron_types.Tx_id.to_hex (Tron_transaction.Raw_data.tx_id raw));

  let tx = Tron_transaction.Transaction.of_raw_data raw in
  let signed = get "sign" (Tron_transaction.Transaction.sign tx sk) in
  let signature = List.hd (Tron_transaction.Transaction.signatures signed) in
  Printf.printf "signature      %s\n"
    (hex (Tron_crypto.signature_to_bytes signature));

  let signers =
    get "recover" (Tron_transaction.Transaction.recover_signers signed)
  in
  let signer = get "signer" (List.hd signers) in
  if not (Tron_types.Address.equal signer from) then begin
    prerr_endline "recovered signer does not match";
    exit 1
  end;
  print_endline "recovered      matches the signing key";

  (* The intent comes back out of the bytes, not out of what we passed in. *)
  let intent =
    get "intent"
      (Tron_transaction.Intent.derive (Tron_transaction.Raw_data.to_bytes raw))
  in
  Printf.printf "intent\n%s\n"
    (Format.asprintf "%a" Tron_transaction.Intent.pp intent);
  (match Tron_transaction.Intent.validate_trx_transfer ~from ~to_ intent with
  | Ok () -> print_endline "policy         accepted"
  | Error e ->
      prerr_endline
        (Format.asprintf "policy rejected: %a"
           Tron_transaction.Intent.pp_policy_error e);
      exit 1);

  (* The RPC layer is in this closure too, and it is pure: building a request
     needs no socket. *)
  let m = Tron_rpc.Wallet.now_block in
  Printf.printf "rpc            %s %s\n" m.Tron_rpc.Method.path
    (Yojson.Safe.to_string m.Tron_rpc.Method.body);
  print_endline "offline path   ok, with no transport linked"
