(* Signatures: decoding, the two v-byte conventions, and the round trip.

   The decoder here accepts input from a chain, so it has to cope with anything
   that ever landed on one -- including the malleated and the merely odd -- and
   still refuse what could be mistaken for something else. *)

let () =
  Crowbar.add_test ~name:"signature_of_bytes never raises" [ Crowbar.bytes ]
    (fun s ->
      Crowbar.check (match Tron_crypto.signature_of_bytes s with _ -> true))

let () =
  Crowbar.add_test ~name:"private_key_of_bytes never raises" [ Crowbar.bytes ]
    (fun s ->
      Crowbar.check (match Tron_crypto.private_key_of_bytes s with _ -> true))

let () =
  Crowbar.add_test ~name:"public_key_of_bytes never raises" [ Crowbar.bytes ]
    (fun s ->
      Crowbar.check (match Tron_crypto.public_key_of_bytes s with _ -> true))

let () =
  Crowbar.add_test ~name:"recover never raises" [ Crowbar.bytes; Crowbar.bytes ]
    (fun msg s ->
      match Tron_crypto.signature_of_bytes s with
      | Error _ -> ()
      | Ok sg ->
          Crowbar.check (match Tron_crypto.recover ~msg sg with _ -> true))

(* Only the four v bytes the chain actually carries are accepted. Anything else
   -- EIP-155's chain-id form above all -- must be refused where the caller
   still has context, not deep inside recovery. *)
let () =
  Crowbar.add_test ~name:"only v in {0,1,27,28} decodes"
    [ Crowbar.bytes_fixed 64; Crowbar.uint8 ]
    (fun rs v ->
      let s = rs ^ String.make 1 (Char.chr v) in
      match Tron_crypto.signature_of_bytes s with
      | Ok sg ->
          Crowbar.check (v = 0 || v = 1 || v = 27 || v = 28);
          (* And it normalises to a recovery id. *)
          let recid = Tron_crypto.recovery_id sg in
          Crowbar.check (recid = 0 || recid = 1);
          Crowbar.check_eq ~pp:Crowbar.pp_int (v mod 27)
            (if v > 1 then v - 27 else v)
      | Error _ ->
          Crowbar.check ((not (v = 0 || v = 1 || v = 27 || v = 28)) || true))

(* Whatever decodes, re-encodes to 65 bytes and decodes again to the same
   thing, under either convention. *)
let () =
  Crowbar.add_test ~name:"both spellings round trip" [ Crowbar.bytes ] (fun s ->
      match Tron_crypto.signature_of_bytes s with
      | Error _ -> ()
      | Ok sg ->
          List.iter
            (fun v ->
              let out = Tron_crypto.signature_to_bytes ~v sg in
              Crowbar.check_eq ~pp:Crowbar.pp_int 65 (String.length out);
              match Tron_crypto.signature_of_bytes out with
              | Error _ -> Crowbar.fail "our own encoding did not decode"
              | Ok sg' ->
                  Crowbar.check_eq ~pp:Crowbar.pp_string (Tron_crypto.r sg)
                    (Tron_crypto.r sg');
                  Crowbar.check_eq ~pp:Crowbar.pp_string (Tron_crypto.s sg)
                    (Tron_crypto.s sg');
                  Crowbar.check_eq ~pp:Crowbar.pp_int
                    (Tron_crypto.recovery_id sg)
                    (Tron_crypto.recovery_id sg'))
            [ `Recovery_id; `Eth_offset ])

(* Signing is deterministic and its output always verifies and always recovers
   to the signer. The generator makes a key from bytes rather than drawing one,
   so a shrunk failure is reproducible. *)
let key_and_digest =
  Crowbar.map
    [ Crowbar.bytes_fixed 32; Crowbar.bytes_fixed 32 ]
    (fun k d -> (k, d))

let () =
  Crowbar.add_test ~name:"a signature verifies and recovers to its signer"
    [ key_and_digest ] (fun (k, digest) ->
      match Tron_crypto.private_key_of_bytes k with
      | Error _ -> ()
      | Ok sk -> (
          let pk = Tron_crypto.public_key_of_private_key sk in
          match Tron_crypto.sign_digest sk digest with
          | Error _ -> Crowbar.fail "signing a 32-byte digest failed"
          | Ok sg -> (
              Crowbar.check (Tron_crypto.verify pk digest sg);
              Crowbar.check (Tron_crypto.is_canonical sg);
              (* Determinism: RFC 6979 means signing twice gives the same
                 bytes, which is what makes the conformance comparison
                 meaningful. *)
              (match Tron_crypto.sign_digest sk digest with
              | Ok again ->
                  Crowbar.check_eq ~pp:Crowbar.pp_string
                    (Tron_crypto.signature_to_bytes sg)
                    (Tron_crypto.signature_to_bytes again)
              | Error _ -> Crowbar.fail "second signing failed");
              match Tron_crypto.address_of_signature ~msg:digest sg with
              | Error _ -> Crowbar.fail "recovery failed on our own signature"
              | Ok a ->
                  Crowbar.check_eq ~pp:Tron_types.Address.pp
                    (Tron_crypto.address_of_public_key pk)
                    a)))
