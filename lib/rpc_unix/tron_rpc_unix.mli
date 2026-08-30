(** The java-tron HTTP client over Unix TCP, TLS, or a Unix socket.

    The HTTP protocol remains in {!Tron_rpc_flow.Make}; this module only dials
    and, for HTTPS, wraps the connection in a certificate- and hostname-
    verifying TLS flow using the system trust store. *)

type t
type flow = [ `Plain of Lwt_unix.file_descr | `Tls of Tls_lwt.Unix.t ]

module Endpoint : sig
  type scheme = [ `Http | `Https ]
  type t

  val of_string : string -> (t, string) result
  val scheme : t -> scheme
  val host : t -> string
  val port : t -> int
  val host_header : t -> string
end

val create :
  ?host:string -> ?limits:Tron_rpc_flow.Http.limits -> Lwt_unix.file_descr -> t
(** Wraps an already-connected plaintext descriptor. *)

val flow : t -> flow

val connect_tcp : ?host_header:string -> string -> int -> t Lwt.t
(** Plaintext TCP, intended for a local node or loopback proxy. *)

val connect_tls :
  ?authenticator:X509.Authenticator.t ->
  ?host_header:string ->
  string ->
  int ->
  t Lwt.t
(** TLS with hostname verification and SNI. The system CA store is used when
    [authenticator] is omitted. *)

val connect_uri :
  ?authenticator:X509.Authenticator.t ->
  ?host_header:string ->
  string ->
  t Lwt.t
(** Selects verified TLS for [https://] and plaintext for [http://]. *)

val connect_unix : ?host_header:string -> string -> t Lwt.t
val close : t -> unit Lwt.t
val call : t -> 'a Tron_rpc.Method.t -> ('a, Tron_rpc.Error.t) result Lwt.t

module Provider : Tron_rpc.Provider.S with type t = t and type 'a io = 'a Lwt.t
