(* The HTTP parser is fed a byte at a time, because that is how a socket
   delivers and it is where framing bugs live. A response split anywhere --
   mid status line, mid header, mid chunk length -- must parse identically to
   the same response delivered whole. *)

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

let crlf = "\r\n"

let content_length_response body =
  Printf.sprintf
    "HTTP/1.1 200 OK%sContent-Type: application/json%sContent-Length: %d%s%s%s"
    crlf crlf (String.length body) crlf crlf body

let chunked_response parts =
  let b = Buffer.create 256 in
  Buffer.add_string b
    ("HTTP/1.1 200 OK" ^ crlf ^ "Transfer-Encoding: chunked" ^ crlf ^ crlf);
  List.iter
    (fun p ->
      Buffer.add_string b
        (Printf.sprintf "%x%s%s%s" (String.length p) crlf p crlf))
    parts;
  Buffer.add_string b ("0" ^ crlf ^ crlf);
  Buffer.contents b

let body = {|{"result":true,"txid":"aa"}|}

(* Every split of the same response must give the same answer. *)
let test_content_length_any_split () =
  let response = content_length_response body in
  List.iter
    (fun chunk ->
      match drive ~chunk response with
      | `Done (status, got) ->
          Alcotest.(check string)
            (Printf.sprintf "chunk size %d" chunk)
            body got;
          Alcotest.(check (option int)) "status came with it" (Some 200) status
      | `Failed m -> Alcotest.failf "chunk size %d failed: %s" chunk m
      | `Truncated -> Alcotest.failf "chunk size %d truncated" chunk)
    [ 1; 2; 3; 7; 13; 64; String.length response ]

let test_chunked_any_split () =
  let parts = [ {|{"result":|}; {|true,"txid"|}; {|:"aa"}|} ] in
  let response = chunked_response parts in
  let expected = String.concat "" parts in
  List.iter
    (fun chunk ->
      match drive ~chunk response with
      | `Done (_, got) ->
          Alcotest.(check string)
            (Printf.sprintf "chunk size %d" chunk)
            expected got
      | `Failed m -> Alcotest.failf "chunk size %d failed: %s" chunk m
      | `Truncated -> Alcotest.failf "chunk size %d truncated" chunk)
    [ 1; 3; 8; 32; String.length response ]

(* An oversized body must be refused rather than accumulated: the declared
   length is a remote peer's claim, not a fact. *)
let test_body_limit () =
  let limits = { Http.max_headers = 4096; max_body = 16 } in
  let response = content_length_response (String.make 1024 'x') in
  match drive ~limits ~chunk:7 response with
  | `Failed _ -> ()
  | `Done _ -> Alcotest.fail "an oversized body was accepted"
  | `Truncated ->
      Alcotest.fail "an oversized body was neither accepted nor refused"

let test_header_limit () =
  let limits = { Http.max_headers = 64; max_body = 1024 } in
  let padding =
    String.concat ""
      (List.init 50 (fun i -> Printf.sprintf "X-Pad-%d: v%s" i crlf))
  in
  let response =
    Printf.sprintf "HTTP/1.1 200 OK%s%sContent-Length: 2%s%s{}" crlf padding
      crlf crlf
  in
  match drive ~limits ~chunk:5 response with
  | `Failed _ -> ()
  | `Done _ -> Alcotest.fail "oversized headers were accepted"
  | `Truncated ->
      Alcotest.fail "oversized headers were neither accepted nor refused"

(* A non-200 has to be visible, and it has to survive the case that discards
   the parser state: a whole response arriving in a single read. Before Done
   carried the status, a caller in that case had nothing to consult and would
   read a 503 with a JSON body as a successful reply. *)
let test_status_survives_a_single_read () =
  let response =
    Printf.sprintf "HTTP/1.1 503 Service Unavailable%sContent-Length: 2%s%s{}"
      crlf crlf crlf
  in
  match Http.feed (Http.start ()) response with
  | Http.Done { status; body } ->
      Alcotest.(check (option int))
        "status is carried out of a single feed" (Some 503) status;
      Alcotest.(check string) "body too" "{}" body
  | Http.Failed m -> Alcotest.failf "unexpected failure: %s" m
  | Http.Need_more _ -> Alcotest.fail "a complete response was not complete"

let test_status_survives_byte_at_a_time () =
  let state = ref (Http.start ()) in
  let response =
    Printf.sprintf "HTTP/1.1 429 Too Many%sContent-Length: 2%s%s{}" crlf crlf
      crlf
  in
  let rec go i =
    if i >= String.length response then Alcotest.fail "never completed"
    else
      match Http.feed !state (String.sub response i 1) with
      | Http.Done { status; _ } ->
          Alcotest.(check (option int)) "status" (Some 429) status
      | Http.Failed m -> Alcotest.failf "failed: %s" m
      | Http.Need_more s ->
          state := s;
          go (i + 1)
  in
  go 0

let test_request_shape () =
  let r =
    Http.request ~host:"api.trongrid.io" ~path:"/wallet/getnowblock" ~body:"{}"
  in
  let contains needle =
    let nl = String.length needle and hl = String.length r in
    let rec go i = i + nl <= hl && (String.sub r i nl = needle || go (i + 1)) in
    go 0
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        (Printf.sprintf "request contains %S" needle)
        true (contains needle))
    [
      "POST /wallet/getnowblock HTTP/1.1";
      "Host: api.trongrid.io";
      "Content-Length: 2";
      "Content-Type: application/json";
    ]

let () =
  Alcotest.run "tron-rpc-flow"
    [
      ( "framing",
        [
          Alcotest.test_case "content-length, any split" `Quick
            test_content_length_any_split;
          Alcotest.test_case "chunked, any split" `Quick test_chunked_any_split;
          Alcotest.test_case "status survives a single read" `Quick
            test_status_survives_a_single_read;
          Alcotest.test_case "status survives a byte at a time" `Quick
            test_status_survives_byte_at_a_time;
        ] );
      ( "bounds",
        [
          Alcotest.test_case "body limit" `Quick test_body_limit;
          Alcotest.test_case "header limit" `Quick test_header_limit;
        ] );
      ("request", [ Alcotest.test_case "shape" `Quick test_request_shape ]);
    ]
