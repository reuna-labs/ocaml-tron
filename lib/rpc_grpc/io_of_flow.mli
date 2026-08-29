(** [Gluten_lwt.IO] over a {!Mirage_flow.S}.

    This is the whole reason gRPC reaches a Solo5 vsock. [h2-mirage] would do
    the functorising, but its closure assumes a full network stack --
    conduit-mirage, tcpip, tls, x509, dns-client, vchan, xenstore, 48 packages
    in all. The confidential targets have no stack; they have a flow. What h2
    actually needs from a transport is [Gluten_lwt.IO], which is four functions,
    and a flow supplies all four. *)

module type FLOW = sig
  type flow
  type error
  type write_error

  val pp_error : error Fmt.t
  val pp_write_error : write_error Fmt.t
  val read : flow -> (Cstruct.t Mirage_flow.or_eof, error) result Lwt.t
  val write : flow -> Cstruct.t -> (unit, write_error) result Lwt.t
end

module Make (F : FLOW) : sig
  type socket

  val create : F.flow -> socket
  val flow : socket -> F.flow

  include Gluten_lwt.IO with type socket := socket
end
