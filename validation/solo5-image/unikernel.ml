(* The offline Tron path, running inside a Solo5 guest.

   This is the claim validation/solo5/ makes structurally, made concretely: the
   same code, cross-compiled to aarch64 and executed by a Solo5 tender with no
   operating system underneath it.

   What it proves that the structural link proof does not: that zarith and GMP
   cross-compile and run here. Base58 needs a bignum, and so does secp256k1
   public-key recovery, so a Tron guest cannot avoid GMP the way ocaml-cardano
   does. See ../../docs/unikernel.md. *)

external console_write : string -> unit = "tron_console_write"

let say fmt = Printf.ksprintf console_write (fmt ^^ "\n")

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
      say "FAIL at %s" msg;
      Solo5_exit.exit 1

let () =
  say "";
  say "tron offline path, in-guest";
  say "---------------------------";

  (* Address derivation: Keccak-256 over the public key, Base58Check over the
     result. Base58 is the first thing here that needs a bignum. *)
  let sk =
    get "private key"
      (Tron_crypto.private_key_of_bytes (unhex (String.make 63 '0' ^ "1")))
  in
  let from = Tron_crypto.address_of_private_key sk in
  let b58 = Tron_types.Address.to_base58check from in
  say "address     %s" b58;
  (* The expected value comes from TronWeb, via the conformance fixture. If
     Base58 or Keccak is wrong on this target, it shows up here. *)
  if not (String.equal b58 "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC") then begin
    say "FAIL address does not match the TronWeb fixture";
    Solo5_exit.exit 1
  end;
  say "            matches the TronWeb fixture";

  let to_ =
    get "destination"
      (Tron_types.Address.of_hex "412b5ad5c4795c026514f8317c7a215e218dccd6cf")
  in
  let block_id =
    get "block id"
      (Tron_types.Tx_id.of_hex ("0000000000123456" ^ String.make 48 'a'))
  in
  let block_ref = Tron_types.Block_ref.of_block_id block_id in

  (* Nothing here reads a clock: expiration is an input, in a guest as much as
     on a host. *)
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
  let bytes = Tron_transaction.Raw_data.to_bytes raw in
  say "raw_data    %d bytes" (String.length bytes);
  say "txID        %s"
    (Tron_types.Tx_id.to_hex (Tron_transaction.Raw_data.tx_id raw));

  (* Signing, then recovery. Recovery is the other bignum user. *)
  let tx = Tron_transaction.Transaction.of_raw_data raw in
  let signed = get "sign" (Tron_transaction.Transaction.sign tx sk) in
  let sg = List.hd (Tron_transaction.Transaction.signatures signed) in
  say "signature   %s" (hex (Tron_crypto.signature_to_bytes sg));
  let signers =
    get "recover" (Tron_transaction.Transaction.recover_signers signed)
  in
  let signer = get "signer" (List.hd signers) in
  if not (Tron_types.Address.equal signer from) then begin
    say "FAIL recovered signer does not match";
    Solo5_exit.exit 1
  end;
  say "recovered   matches the signing key";

  (* The intent, derived from the bytes rather than from what we passed in. *)
  let intent = get "intent" (Tron_transaction.Intent.derive bytes) in
  say "intent      %s"
    (Format.asprintf "%a" Tron_transaction.Intent.pp_instruction
       intent.Tron_transaction.Intent.instruction);
  (match Tron_transaction.Intent.validate_trx_transfer ~from ~to_ intent with
  | Ok () -> say "policy      accepted"
  | Error _ ->
      say "FAIL policy rejected its own transaction";
      Solo5_exit.exit 1);

  (* An ABI encode, which is the third bignum user: uint256. *)
  let data =
    get "trc20"
      (Tron_transaction.Trc20.transfer ~to_ ~amount:(Z.of_string "50000000000"))
  in
  say "trc20 data  %s..." (hex (String.sub data 0 8));
  if not (String.equal (hex (String.sub data 0 4)) "a9059cbb") then begin
    say "FAIL wrong TRC-20 selector";
    Solo5_exit.exit 1
  end;
  say "            selector matches";

  say "";
  say "OK: the offline path runs in a Solo5 guest, GMP and all";
  Solo5_exit.exit 0
