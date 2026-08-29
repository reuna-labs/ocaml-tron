(** The java-tron HTTP client over a Unix socket.

    This is {!Tron_rpc_flow.Make} instantiated over [Mirage_flow_unix.Fd] and
    nothing more. The interesting property is what is {e absent}: there is no
    Unix-specific client code, so the Unix path and the unikernel path are the
    same implementation with a different flow underneath. Rehearsing an enclave
    workflow on Unix is then worth something.

    {b No TLS here.} Public Tron endpoints are HTTPS, and this client speaks
    plaintext HTTP/1.1 over whatever flow it is given. Wrap the descriptor in a
    TLS flow before handing it over -- a TLS flow is a flow -- or point it at a
    local node. Silently making an unencrypted connection to a public endpoint
    would be worse than not offering one. *)

type t

val create :
  ?host:string -> ?limits:Tron_rpc_flow.Http.limits -> Lwt_unix.file_descr -> t
(** Wraps an already-connected descriptor. *)

val flow : t -> Lwt_unix.file_descr

val connect_tcp : ?host_header:string -> string -> int -> t Lwt.t
(** Plaintext. For a local node, or a TLS-terminating proxy on the loopback. *)

val connect_unix : ?host_header:string -> string -> t Lwt.t
(** Dials a Unix domain socket, which is how a vsock relay is reached from the
    host side -- the same shape a unikernel sees, one layer down. *)

val call : t -> 'a Tron_rpc.Method.t -> ('a, Tron_rpc.Error.t) result Lwt.t

module Provider : Tron_rpc.Provider.S with type t = t and type 'a io = 'a Lwt.t
