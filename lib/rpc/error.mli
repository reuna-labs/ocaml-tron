(** What can go wrong between asking a node something and believing the answer.

    Closed, so that a caller matching on it is told by the compiler when a new
    failure becomes possible. *)

type t =
  | Transport of string
      (** The bytes did not make the round trip. Nothing can be concluded about
          whether the request was acted on -- a broadcast that fails this way
          may still have been accepted. *)
  | Http of int * string
      (** A non-200 status. The request did not reach the application: a proxy,
          a wrong path, a rate limit. *)
  | Malformed_json of string
  | Invalid_response of string
      (** Valid JSON, wrong shape, or a field that will not validate -- an
          address that is not 21 bytes, say. *)
  | Node of { code : string; message : string }
      (** java-tron reported a failure. It does this with a 200 and an [Error]
          member, so this is not an {!Http} case. *)

val pp : Format.formatter -> t -> unit
val to_string : t -> string
