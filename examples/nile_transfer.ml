(* A guarded TRX transfer on the Nile testnet, and the evidence it produces.

   Everything is refused rather than defaulted: no node URL, no expected
   genesis, no key, no destination, no amount has a default here. A live signer
   that fills in a blank is a live signer that can be pointed somewhere its
   operator did not intend.

   Run only through .github/workflows/nile-smoke.yml, which is
   workflow_dispatch-only and gated behind a GitHub Environment. *)

let require name =
  match Sys.getenv_opt name with
  | Some v when String.trim v <> "" -> String.trim v
  | _ ->
      prerr_endline (name ^ " is not set; refusing to guess");
      exit 2

let unhex h =
  match
    String.init
      (String.length h / 2)
      (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (i * 2) 2)))
  with
  | s -> s
  | exception _ ->
      prerr_endline "expected hex";
      exit 2

let get msg = function
  | Ok v -> v
  | Error e ->
      Printf.eprintf "%s: %s\n" msg (Tron_rpc.Error.to_string e);
      exit 1

let get' msg = function
  | Ok v -> v
  | Error _ ->
      prerr_endline msg;
      exit 2

let evidence_dir = "nile-evidence"

let record name contents =
  (try Unix.mkdir evidence_dir 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let oc = open_out (Filename.concat evidence_dir name) in
  output_string oc contents;
  close_out oc;
  Printf.printf "recorded %s/%s\n%!" evidence_dir name

let ( let* ) = Lwt.bind

let main () =
  let node = require "TRON_NODE" in
  let expected_genesis = require "TRON_EXPECTED_GENESIS" in
  let seed = require "TRON_SEED" in
  let destination = require "TRON_DESTINATION" in
  let amount_sun = Int64.of_string (require "TRON_AMOUNT_SUN") in

  let uri = Uri.of_string node in
  let host = match Uri.host uri with Some h -> h | None -> node in
  let port = match Uri.port uri with Some p -> p | None -> 80 in
  if Uri.scheme uri = Some "https" then begin
    (* tron-rpc-unix speaks plaintext. Connecting anyway would send a signed
       transaction over an unencrypted link to a public endpoint. *)
    prerr_endline
      "TRON_NODE is https; this client is plaintext. Put a TLS-terminating \
       proxy on the loopback, or point at a local node.";
    exit 2
  end;

  let sk =
    get' "TRON_SEED is not a valid private key"
      (Tron_crypto.private_key_of_bytes (unhex seed))
  in
  let from = Tron_crypto.address_of_private_key sk in
  let to_ =
    get' "TRON_DESTINATION is not an address"
      (Tron_types.Address.of_base58check destination)
  in
  let amount =
    get' "TRON_AMOUNT_SUN is not a valid amount"
      (Tron_types.Sun.of_sun amount_sun)
  in

  Printf.printf "node        %s\n" node;
  Printf.printf "from        %s\n" (Tron_types.Address.to_base58check from);
  Printf.printf "to          %s\n" (Tron_types.Address.to_base58check to_);
  Printf.printf "amount      %s\n%!"
    (Format.asprintf "%a" Tron_types.Sun.pp amount);

  let* client = Tron_rpc_unix.connect_tcp ~host_header:host host port in

  (* Which chain is this? A Tron transaction carries no chain id; the only
     thing binding it to a chain is a reference block from this node. So the
     question has to be asked before anything is signed. *)
  let* genesis = Tron_rpc_unix.call client Tron_rpc.Wallet.genesis_block in
  let genesis = get "genesis block" genesis in
  let expect =
    get' "TRON_EXPECTED_GENESIS is not a 32-byte digest"
      (Tron_types.Network.expected ~name:"nile" expected_genesis)
  in
  (match
     Tron_types.Network.verify ~expect ~observed:genesis.Tron_rpc.Wallet.id
   with
  | Ok () ->
      Printf.printf "genesis     %s (verified)\n%!"
        (Tron_types.Tx_id.to_hex genesis.Tron_rpc.Wallet.id)
  | Error (`Wrong_chain (e, observed)) ->
      Printf.eprintf
        "this node is not the chain we were configured for.\n\
        \  expected %s\n\
        \  observed %s\n"
        (Tron_types.Tx_id.to_hex (Tron_types.Network.genesis_block_id e))
        (Tron_types.Tx_id.to_hex observed);
      exit 1);
  record "genesis.txt"
    (Tron_types.Tx_id.to_hex genesis.Tron_rpc.Wallet.id ^ "\n");

  let* head = Tron_rpc_unix.call client Tron_rpc.Wallet.now_block in
  let head = get "head block" head in
  Printf.printf "head        %Ld\n%!" head.Tron_rpc.Wallet.number;

  (* Expiration comes from this process's clock, not from the library: nothing
     in lib/ reads one. Sixty seconds is the java-tron default. *)
  let now = Int64.of_float (Unix.gettimeofday () *. 1000.) in
  let expiration = Int64.add now 60_000L in

  let raw =
    match
      Tron_transaction.Raw_data.make ~block_ref:head.Tron_rpc.Wallet.block_ref
        ~expiration ~timestamp:now
        (Tron_transaction.Contract.Transfer { owner = from; to_; amount })
    with
    | Ok r -> r
    | Error _ ->
        prerr_endline "could not build the transaction";
        exit 1
  in

  (* Review before signing, from the bytes about to be signed -- not from the
     arguments that produced them. *)
  let intent =
    match
      Tron_transaction.Intent.derive (Tron_transaction.Raw_data.to_bytes raw)
    with
    | Ok i -> i
    | Error _ ->
        prerr_endline "could not derive the intent from the bytes";
        exit 1
  in
  let rendered = Format.asprintf "%a" Tron_transaction.Intent.pp intent in
  print_endline "--- intent ---";
  print_endline rendered;
  print_endline "--------------";
  (match
     Tron_transaction.Intent.validate_trx_transfer ~from ~to_ ~max_amount:amount
       ~now intent
   with
  | Ok () -> print_endline "policy      accepted"
  | Error e ->
      prerr_endline
        (Format.asprintf "policy rejected: %a"
           Tron_transaction.Intent.pp_policy_error e);
      exit 1);
  record "intent.txt" (rendered ^ "\n");

  let tx = Tron_transaction.Transaction.of_raw_data raw in
  let signed =
    match Tron_transaction.Transaction.sign tx sk with
    | Ok s -> s
    | Error _ ->
        prerr_endline "signing failed";
        exit 1
  in
  let tx_id = Tron_transaction.Transaction.tx_id signed in
  let hex = Tron_transaction.Transaction.to_broadcast_hex signed in
  Printf.printf "txID        %s\n%!" (Tron_types.Tx_id.to_hex tx_id);
  record "transaction.hex" (hex ^ "\n");
  record "txid.txt" (Tron_types.Tx_id.to_hex tx_id ^ "\n");

  let* result = Tron_rpc_unix.call client (Tron_rpc.Wallet.broadcast_hex hex) in
  let result = get "broadcast" result in
  if not result.Tron_rpc.Wallet.accepted then begin
    Printf.eprintf "rejected: %s %s\n"
      (Option.value ~default:"" result.Tron_rpc.Wallet.code)
      (Option.value ~default:"" result.Tron_rpc.Wallet.message);
    exit 1
  end;
  print_endline "broadcast   accepted";

  (* Poll for the receipt. The bound is the point: a smoke test that waits
     forever is a smoke test that hangs a workflow. *)
  let rec poll n =
    if n = 0 then begin
      prerr_endline "no receipt within the poll budget";
      exit 1
    end
    else
      let* r =
        Tron_rpc_unix.call client (Tron_rpc.Wallet.transaction_info tx_id)
      in
      match get "receipt" r with
      | None ->
          let* () = Lwt_unix.sleep 3.0 in
          poll (n - 1)
      | Some receipt ->
          let* head = Tron_rpc_unix.call client Tron_rpc.Wallet.now_block in
          let head = get "head" head in
          let confirmation =
            Tron_rpc.Confirmation.of_receipt ~head:head.Tron_rpc.Wallet.number
              (Some receipt)
          in
          let summary =
            Format.asprintf
              "txID %s@\n\
               block %Ld@\n\
               fee %Ld sun@\n\
               bandwidth %Ld@\n\
               energy %Ld@\n\
               %a@."
              (Tron_types.Tx_id.to_hex tx_id)
              receipt.Tron_rpc.Wallet.block_number receipt.Tron_rpc.Wallet.fee
              receipt.Tron_rpc.Wallet.net_usage
              receipt.Tron_rpc.Wallet.energy_usage_total
              Tron_rpc.Confirmation.pp confirmation
          in
          print_endline "--- receipt ---";
          print_string summary;
          record "receipt.txt" summary;
          if not receipt.Tron_rpc.Wallet.succeeded then exit 1
          else Lwt.return_unit
  in
  poll 20

let () = Lwt_main.run (main ())
