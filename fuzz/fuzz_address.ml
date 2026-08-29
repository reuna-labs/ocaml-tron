(* Addresses: the four renderings must agree, and no input may crash.

   The interesting direction is decode-then-encode, not the reverse. Anything
   this library produced will round-trip; the question is what happens to bytes
   someone else produced, or an attacker chose. *)

let () =
  Crowbar.add_test ~name:"of_bytes never raises" [ Crowbar.bytes ] (fun s ->
      Crowbar.check (match Tron_types.Address.of_bytes s with _ -> true))

let () =
  Crowbar.add_test ~name:"of_base58check never raises" [ Crowbar.bytes ]
    (fun s ->
      Crowbar.check (match Tron_types.Address.of_base58check s with _ -> true))

let () =
  Crowbar.add_test ~name:"of_hex never raises" [ Crowbar.bytes ] (fun s ->
      Crowbar.check (match Tron_types.Address.of_hex s with _ -> true))

let () =
  Crowbar.add_test ~name:"of_abi_word never raises" [ Crowbar.bytes ] (fun s ->
      Crowbar.check (match Tron_types.Address.of_abi_word s with _ -> true))

(* Every valid address survives every rendering. The generator makes the
   20-byte hash rather than a whole address, because a random 21 bytes is
   almost never valid and the round trip is the property worth testing. *)
let hash20 = Crowbar.map [ Crowbar.bytes_fixed 20 ] (fun s -> s)

let () =
  Crowbar.add_test ~name:"round trips through every rendering" [ hash20 ]
    (fun h ->
      let a = Result.get_ok (Tron_types.Address.of_hash20 h) in
      let via f g = Result.get_ok (f (g a)) in
      Crowbar.check_eq ~pp:Tron_types.Address.pp a
        (via Tron_types.Address.of_base58check Tron_types.Address.to_base58check);
      Crowbar.check_eq ~pp:Tron_types.Address.pp a
        (via Tron_types.Address.of_hex Tron_types.Address.to_hex);
      Crowbar.check_eq ~pp:Tron_types.Address.pp a
        (via Tron_types.Address.of_abi_word Tron_types.Address.to_abi_word))

(* A Base58Check string with any single character altered must fail the
   checksum rather than decode to a neighbouring account. That is the entire
   reason the checksum is there. *)
let () =
  Crowbar.add_test ~name:"a mutated base58check does not decode"
    [ hash20; Crowbar.uint8; Crowbar.uint8 ] (fun h pos ch ->
      let a = Result.get_ok (Tron_types.Address.of_hash20 h) in
      let s = Tron_types.Address.to_base58check a in
      let i = pos mod String.length s in
      let alphabet =
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
      in
      let c = alphabet.[ch mod String.length alphabet] in
      Crowbar.guard (c <> s.[i]);
      let b = Bytes.of_string s in
      Bytes.set b i c;
      match Tron_types.Address.of_base58check (Bytes.to_string b) with
      | Error _ -> ()
      | Ok other ->
          (* Decoding is allowed only if it is somehow the same address, which
             it cannot be -- but say so rather than assuming. *)
          Crowbar.check_eq ~pp:Tron_types.Address.pp a other)

(* The ABI word carries 20 bytes, not 21. A word built from an address must
   never read back as a different one. *)
let () =
  Crowbar.add_test ~name:"abi word identifies the same account" [ hash20 ]
    (fun h ->
      let a = Result.get_ok (Tron_types.Address.of_hash20 h) in
      let w = Tron_types.Address.to_abi_word a in
      Crowbar.check_eq ~pp:Crowbar.pp_string (String.sub w 12 20)
        (Tron_types.Address.to_hash20 a))
