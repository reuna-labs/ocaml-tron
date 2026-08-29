(** The boundary between "what to ask" and "how to send it".

    Everything above this line is pure: the method catalogue, the JSON codecs
    and the submission state machine all work on strings and values. A transport
    supplies {!S} or the smaller {!TEXT}, and gets the typed client back.

    This is what lets the same client run over a Unix socket, a MirageOS
    [Mirage_flow.S] -- including a Solo5 vsock -- or a table of canned replies
    in a test. *)

module type S = sig
  type t
  type 'a io

  val return : 'a -> 'a io
  val bind : 'a io -> ('a -> 'b io) -> 'b io

  val request :
    t -> path:string -> body:Yojson.Safe.t -> (Yojson.Safe.t, Error.t) result io
end

module type TEXT = sig
  type t
  type 'a io

  val return : 'a -> 'a io
  val bind : 'a io -> ('a -> 'b io) -> 'b io

  val exchange : t -> path:string -> string -> (string, Error.t) result io
  (** Send one request body, return one reply body. The transport does not need
      to know what either means. *)
end

(** Builds a provider from anything that can exchange a string for a string,
    adding JSON parsing and java-tron's [Error]-member convention -- which is
    reported with a 200 status, so a transport that only checked the status
    would call a rejected broadcast a success. *)
module Of_text (X : TEXT) : S with type t = X.t and type 'a io = 'a X.io

module Make (P : S) : sig
  val call : P.t -> 'a Method.t -> ('a, Error.t) result P.io
end
