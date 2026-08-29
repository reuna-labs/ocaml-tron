(** The java-tron gRPC client, over any {!Mirage_flow.S}.

    java-tron exposes the same Wallet surface twice: HTTP/1.1 with JSON, and
    gRPC with protobuf. This is the second. It decodes into the {b same} typed
    values {!Tron_rpc.Wallet} produces, which is what makes "HTTP and gRPC
    responses agree" a claim that can be tested rather than a slogan -- see
    [test/test_grpc_parity.ml].

    {2 Same reach as the HTTP client}

    Functorised over the same flow signature as {!Tron_rpc_flow}, so gRPC runs
    wherever HTTP does, vsock included. That took implementing [Gluten_lwt.IO]
    over a flow -- see {!Io_of_flow} for why [h2-mirage] was not the answer.

    {2 Which one to prefer}

    gRPC is the better read path: responses are protobuf, so there is no
    hex-versus-base64 question and no [visible] flag changing the shape of a
    reply.

    For {b broadcast}, both are equivalent in this library and neither
    re-encodes: {!Tron_transaction.Transaction.to_bytes} produces the wire form
    with the signed [raw_data] carried through byte for byte, and that is what
    goes out over either transport. Sending the decoded model instead would be
    the mistake -- see that function's documentation. *)

module Io_of_flow = Io_of_flow
module Method = Method_grpc
module Wallet = Wallet_grpc

module type FLOW = Io_of_flow.FLOW

module Make (F : FLOW) : sig
  type t

  val create : ?authority:string -> ?scheme:string -> F.flow -> t Lwt.t
  (** Starts an HTTP/2 connection over an already-connected flow. [authority]
      fills the [:authority] pseudo-header, [scheme] defaults to ["http"].

      Never dials: on a unikernel the connection comes from a device the guest
      configured, and this layer must not know how to make one. *)

  val flow : t -> F.flow

  val call : t -> 'a Method.t -> ('a, Tron_rpc.Error.t) result Lwt.t
  (** A gRPC status other than [OK] arrives as {!Tron_rpc.Error.Node}, so a
      caller handling node-reported failures gets them from the same constructor
      regardless of transport. *)

  val shutdown : t -> unit Lwt.t
  (** Closes the HTTP/2 connection. Does {b not} close the flow, which belongs
      to the caller. *)
end
