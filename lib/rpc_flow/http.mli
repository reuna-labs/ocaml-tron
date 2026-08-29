(** Just enough HTTP/1.1 to carry java-tron's JSON API, as a pure parser.

    Lifted from [ocaml-cardano]; see the top of [http.ml] for provenance.

    Not a general HTTP client. It sends one POST and reads one response, which
    is all the [/wallet/*] endpoints need -- every one of them is a POST with a
    JSON body, including the ones that only read.

    The parser is separated from the socket for the same reason as everything
    else here: it can then be driven from a unikernel with no TCP stack, and
    tested by feeding it bytes a few at a time -- which is how a real socket
    delivers them, and where framing bugs actually live. *)

val request : host:string -> path:string -> body:string -> string
(** A complete POST, with [Content-Length] and [Connection: keep-alive]. *)

type limits = { max_headers : int; max_body : int }

val default_limits : limits
(** 64 KiB of headers and 16 MiB of body. The response is a remote peer's, so
    its declared length is a claim to be bounded rather than believed. *)

type state

val start : ?limits:limits -> unit -> state

type progress =
  | Need_more of state
  | Done of { status : int option; body : string }
  | Failed of string
      (** [Done] carries the status rather than leaving it to be read back out
          of a state the caller no longer has. When a whole response arrives in
          one read there is no intermediate state to ask, and a caller that fell
          back to "assume 200" would read a 503 carrying a JSON body as a
          successful reply. *)

val feed : state -> string -> progress
(** Feeds however many bytes arrived. Splitting a response anywhere -- mid
    header, mid chunk length, mid body -- must not change the result. *)

val status : state -> int option
(** The status line as soon as the headers have been read, for a caller that
    wants it before the body finishes. Once the body is complete, prefer the
    field on {!Done}: the state that would answer this may no longer exist. *)
