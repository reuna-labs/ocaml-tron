(** A typed gRPC call: which method, how to encode the request, and how to read
    the reply into the {b same} OCaml value the HTTP client produces.

    That last part is the point of this package existing rather than a second
    parallel client. "HTTP and gRPC agree" is only a meaningful claim if both
    land in one type; two transports each with their own result types can never
    disagree, because they are never compared. *)

type 'a t = {
  service : string;  (** e.g. ["protocol.Wallet"] -- package included. *)
  rpc : string;  (** e.g. ["GetNowBlock2"]. *)
  request : string;  (** The serialized request message. *)
  decode : string -> ('a, string) result;
}

val make :
  service:string ->
  rpc:string ->
  request:string ->
  (string -> ('a, string) result) ->
  'a t

val of_rpc :
  (module Ocaml_protoc_plugin.Service.Rpc
     with type Request.t = 'req
      and type Response.t = 'resp) ->
  'req ->
  ('resp -> ('a, string) result) ->
  'a t
(** Builds a call from a generated stub, so the service and method names come
    from the schema rather than from a string typed twice. *)
