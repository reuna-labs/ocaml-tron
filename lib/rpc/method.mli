(** A typed call: the path, the request body, and how to read the reply, bundled
    so they cannot drift apart.

    A transport takes a {!t} and knows nothing about what it means. That is the
    whole boundary -- see {!Provider}. *)

type 'a t = {
  path : string;  (** e.g. ["/wallet/getnowblock"]. *)
  body : Yojson.Safe.t;
  decode : Yojson.Safe.t -> ('a, string) result;
}

val make :
  path:string ->
  ?body:(string * Yojson.Safe.t) list ->
  (Yojson.Safe.t -> ('a, string) result) ->
  'a t
(** [body] defaults to an empty object. Every [/wallet/*] endpoint is a POST
    with a JSON body, including the ones that only read, so there is no GET case
    to model. *)

val map : ('a -> ('b, string) result) -> 'a t -> 'b t
