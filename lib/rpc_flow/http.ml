(* Lifted from ocaml-cardano/lib/rpc_flow/http.ml, sha256 prefix c294cfd5e2576185
   (that repository has no commits yet, so the source is identified by content).

   A deliberate fork rather than a shared dependency, following the precedent
   of ocaml-cardano/lib/address/bech32.ml: there is no HTTP package in this
   tree to depend on, and inventing one for its second consumer is premature.
   Extract it when a third appears.

   The parser is unchanged. Only comments and the `request` headers differ,
   naming java-tron's API rather than Ogmios.

   Minimal HTTP/1.1. Both framings are supported because both occur: a server
   that knows the length sends Content-Length, and one that streams sends
   chunked. Guessing wrong truncates the JSON silently. *)

type limits = { max_headers : int; max_body : int }

let default_limits = { max_headers = 64 * 1024; max_body = 16 * 1024 * 1024 }

let request ~host ~path ~body =
  Printf.sprintf
    "POST %s HTTP/1.1\r\n\
     Host: %s\r\n\
     Content-Type: application/json\r\n\
     Accept: application/json\r\n\
     Content-Length: %d\r\n\
     Connection: keep-alive\r\n\
     \r\n\
     %s"
    path host (String.length body) body

type framing = Length of int | Chunked | Until_close
type phase = Headers | Body of framing | Chunk_header | Chunk_body of int

type state = {
  limits : limits;
  buf : Buffer.t;  (** Unconsumed input. *)
  out : Buffer.t;  (** Body assembled so far. *)
  phase : phase;
  status : int option;
  got : int;  (** Body bytes taken, for the Length framing. *)
}

let start ?(limits = default_limits) () =
  {
    limits;
    buf = Buffer.create 1024;
    out = Buffer.create 1024;
    phase = Headers;
    status = None;
    got = 0;
  }

let status t = t.status

(* DIVERGES from the ocaml-cardano original, which is `Done of string`.
   That shape loses the state, and with it the status line, whenever a whole
   response arrives in a single read -- the common case on a fast local
   connection. A caller then has no way to tell a 200 from a 503 carrying a
   JSON body, and reads the latter as success. Carrying the status in the
   constructor makes it unmissable. *)
type progress =
  | Need_more of state
  | Done of { status : int option; body : string }
  | Failed of string

let index_sub s sub from =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then None
    else if String.sub s i m = sub then Some i
    else go (i + 1)
  in
  go from

let lower = String.lowercase_ascii

let parse_status line =
  match String.split_on_char ' ' line with
  | _ :: code :: _ -> int_of_string_opt code
  | _ -> None

(* Header values are matched case-insensitively; a server is free to send
   "content-length" and several do. *)
let find_header headers name =
  let name = lower name in
  List.find_map
    (fun h ->
      match String.index_opt h ':' with
      | None -> None
      | Some i ->
          if lower (String.trim (String.sub h 0 i)) = name then
            Some (String.trim (String.sub h (i + 1) (String.length h - i - 1)))
          else None)
    headers

let rec run t =
  let s = Buffer.contents t.buf in
  match t.phase with
  | Headers -> (
      match index_sub s "\r\n\r\n" 0 with
      | None ->
          if String.length s > t.limits.max_headers then
            Failed
              (Printf.sprintf "headers exceed %d bytes" t.limits.max_headers)
          else Need_more t
      | Some i -> (
          let head = String.sub s 0 i in
          let rest = String.sub s (i + 4) (String.length s - i - 4) in
          let lines =
            String.split_on_char '\n' head |> List.map (fun l -> String.trim l)
          in
          let status_line, headers =
            match lines with [] -> ("", []) | h :: t -> (h, t)
          in
          let status = parse_status status_line in
          let framing =
            match find_header headers "transfer-encoding" with
            | Some te when lower te = "chunked" -> Some Chunked
            | _ -> (
                match find_header headers "content-length" with
                | Some v -> (
                    match int_of_string_opt (String.trim v) with
                    | Some n -> Some (Length n)
                    | None -> None)
                | None -> Some Until_close)
          in
          match framing with
          | None -> Failed "malformed Content-Length"
          | Some (Length n) when n > t.limits.max_body ->
              Failed
                (Printf.sprintf "body of %d bytes exceeds the %d-byte limit" n
                   t.limits.max_body)
          | Some f ->
              Buffer.clear t.buf;
              Buffer.add_string t.buf rest;
              let phase =
                match f with Chunked -> Chunk_header | f -> Body f
              in
              run { t with phase; status }))
  | Body (Length n) ->
      if String.length s >= n - t.got then (
        Buffer.add_string t.out (String.sub s 0 (n - t.got));
        Done { status = t.status; body = Buffer.contents t.out })
      else (
        Buffer.add_string t.out s;
        let got = t.got + String.length s in
        Buffer.clear t.buf;
        Need_more { t with got })
  | Body Until_close ->
      (* No length and no chunking: the body ends when the peer closes. The
         driver signals that by feeding "" at end of stream. *)
      Buffer.add_string t.out s;
      Buffer.clear t.buf;
      if Buffer.length t.out > t.limits.max_body then
        Failed "body exceeds the limit"
      else Need_more t
  | Body Chunked -> Need_more t
  | Chunk_header -> (
      match index_sub s "\r\n" 0 with
      | None ->
          if String.length s > 64 then Failed "malformed chunk header"
          else Need_more t
      | Some i -> (
          let line = String.sub s 0 i in
          (* A chunk header may carry extensions after a semicolon. *)
          let hex =
            match String.index_opt line ';' with
            | None -> line
            | Some j -> String.sub line 0 j
          in
          match int_of_string_opt ("0x" ^ String.trim hex) with
          | None -> Failed (Printf.sprintf "malformed chunk length %S" hex)
          | Some 0 -> Done { status = t.status; body = Buffer.contents t.out }
          | Some n ->
              if Buffer.length t.out + n > t.limits.max_body then
                Failed "chunked body exceeds the limit"
              else
                let rest = String.sub s (i + 2) (String.length s - i - 2) in
                Buffer.clear t.buf;
                Buffer.add_string t.buf rest;
                run { t with phase = Chunk_body n }))
  | Chunk_body n ->
      if String.length s >= n + 2 then (
        Buffer.add_string t.out (String.sub s 0 n);
        let rest = String.sub s (n + 2) (String.length s - n - 2) in
        Buffer.clear t.buf;
        Buffer.add_string t.buf rest;
        run { t with phase = Chunk_header })
      else Need_more t

let feed t chunk =
  if chunk = "" then
    (* End of stream. Only the close-delimited framing can end this way. *)
    match t.phase with
    | Body Until_close ->
        Done { status = t.status; body = Buffer.contents t.out }
    | _ -> Failed "connection closed before the response was complete"
  else (
    Buffer.add_string t.buf chunk;
    run t)
