(* The HTTP/1.1 parser, fed by an adversary rather than a well-behaved server.

   Two properties. It must not crash on anything, and -- the one that actually
   matters -- splitting a response must never change the answer. A parser that
   is correct only when bytes arrive in convenient chunks is a parser that is
   wrong on a real socket. *)

module Http = Tron_rpc_flow.Http

let drive ?limits ~chunk response =
  let state = ref (Http.start ?limits ()) in
  let n = String.length response in
  let rec go i =
    if i >= n then `Truncated
    else
      let len = min chunk (n - i) in
      match Http.feed !state (String.sub response i len) with
      | Http.Done { status; body } -> `Done (status, body)
      | Http.Failed m -> `Failed m
      | Http.Need_more s ->
          state := s;
          go (i + len)
  in
  go 0

let () =
  Crowbar.add_test ~name:"never raises, at any chunk size"
    [ Crowbar.bytes; Crowbar.range 32 ]
    (fun s chunk ->
      let chunk = chunk + 1 in
      Crowbar.check (match drive ~chunk s with _ -> true))

(* The property the framing depends on. *)
let () =
  Crowbar.add_test ~name:"the split does not change the answer"
    [ Crowbar.bytes; Crowbar.range 32; Crowbar.range 32 ]
    (fun s a b ->
      let a = a + 1 and b = b + 1 in
      Crowbar.guard (a <> b);
      match (drive ~chunk:a s, drive ~chunk:b s) with
      | `Done (sa, ba), `Done (sb, bb) ->
          Crowbar.check_eq ~pp:Crowbar.pp_string ba bb;
          Crowbar.check_eq
            ~pp:(fun ppf -> function
              | None -> Format.pp_print_string ppf "none"
              | Some c -> Format.pp_print_int ppf c)
            sa sb
      | `Failed _, `Failed _ -> ()
      | `Truncated, `Truncated -> ()
      (* Anything else is the split having changed the outcome, which is the
         bug this test exists for. *)
      | x, y ->
          let name = function
            | `Done _ -> "done"
            | `Failed _ -> "failed"
            | `Truncated -> "truncated"
          in
          Crowbar.failf "chunk %d gave %s, chunk %d gave %s" a (name x) b
            (name y))

(* A declared length is a remote peer's claim. Whatever it says, the parser
   must not accumulate past the limit it was given. *)
let () =
  Crowbar.add_test ~name:"the body limit is respected"
    [ Crowbar.bytes; Crowbar.range 64 ]
    (fun s cap ->
      let cap = cap + 1 in
      let limits = { Http.max_headers = 256; max_body = cap } in
      match drive ~limits ~chunk:7 s with
      | `Done (_, body) -> Crowbar.check (String.length body <= cap)
      | `Failed _ | `Truncated -> ())

(* A well-formed response with a generated body must come back exactly. *)
let () =
  Crowbar.add_test ~name:"content-length round trips"
    [ Crowbar.bytes; Crowbar.range 16 ]
    (fun body chunk ->
      let chunk = chunk + 1 in
      let response =
        Printf.sprintf "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s"
          (String.length body) body
      in
      match drive ~chunk response with
      | `Done (status, got) ->
          Crowbar.check_eq ~pp:Crowbar.pp_string body got;
          Crowbar.check (status = Some 200)
      | `Failed m -> Crowbar.failf "well-formed response failed: %s" m
      | `Truncated -> Crowbar.fail "well-formed response truncated")
