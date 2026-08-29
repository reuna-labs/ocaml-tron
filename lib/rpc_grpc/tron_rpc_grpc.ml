module Io_of_flow = Io_of_flow
module Method = Method_grpc
module Wallet = Wallet_grpc

module type FLOW = Io_of_flow.FLOW

module Make (F : FLOW) = struct
  module Io = Io_of_flow.Make (F)
  module Runtime = Gluten_lwt.Client (Io)
  module H2_client = H2_lwt.Client (Runtime)

  type t = { conn : H2_client.t; socket : Io.socket; scheme : string }

  let status_code_name : Grpc.Status.code -> string = function
    | Grpc.Status.OK -> "OK"
    | Cancelled -> "CANCELLED"
    | Unknown -> "UNKNOWN"
    | Invalid_argument -> "INVALID_ARGUMENT"
    | Deadline_exceeded -> "DEADLINE_EXCEEDED"
    | Not_found -> "NOT_FOUND"
    | Already_exists -> "ALREADY_EXISTS"
    | Permission_denied -> "PERMISSION_DENIED"
    | Resource_exhausted -> "RESOURCE_EXHAUSTED"
    | Failed_precondition -> "FAILED_PRECONDITION"
    | Aborted -> "ABORTED"
    | Out_of_range -> "OUT_OF_RANGE"
    | Unimplemented -> "UNIMPLEMENTED"
    | Internal -> "INTERNAL"
    | Unavailable -> "UNAVAILABLE"
    | Data_loss -> "DATA_LOSS"
    | Unauthenticated -> "UNAUTHENTICATED"

  let create ?authority ?(scheme = "http") flow =
    ignore authority;
    let socket = Io.create flow in
    Lwt.bind
      (H2_client.create_connection ~error_handler:(fun _ -> ()) socket)
      (fun conn -> Lwt.return { conn; socket; scheme })

  let flow t = Io.flow t.socket
  let shutdown t = H2_client.shutdown t.conn

  let call t (m : 'a Method.t) =
    let handler =
      Grpc_lwt.Client.Rpc.unary ~f:(fun response -> response) m.Method.request
    in
    Lwt.bind
      (Grpc_lwt.Client.call ~service:m.Method.service ~rpc:m.Method.rpc
         ~scheme:t.scheme ~handler
         ~do_request:(H2_client.request t.conn ~error_handler:(fun _ -> ()))
         ())
      (function
        | Error status ->
            (* An HTTP/2 status here means the request never reached the
               application -- the same distinction the HTTP client draws. *)
            Lwt.return
              (Error
                 (Tron_rpc.Error.Http
                    ( H2.Status.to_code status,
                      "gRPC request rejected at the HTTP layer" )))
        | Ok (body, status) -> (
            match Grpc.Status.code status with
            | Grpc.Status.OK -> (
                match body with
                | None ->
                    Lwt.return
                      (Error (Tron_rpc.Error.Invalid_response "empty gRPC body"))
                | Some body -> (
                    match m.Method.decode body with
                    | Ok v -> Lwt.return (Ok v)
                    | Error e ->
                        Lwt.return (Error (Tron_rpc.Error.Invalid_response e))))
            | code ->
                (* Node-reported failure. Reported through the same constructor
                   the HTTP client uses for an Error member, so a caller
                   handling node errors does not have to branch on transport.

                   The name is spelled out rather than taken from
                   Grpc.Status.show_code: that is ppx_deriving output, which
                   would put ppx_deriving.runtime into the closure of a package
                   that a unikernel links. *)
                Lwt.return
                  (Error
                     (Tron_rpc.Error.Node
                        {
                          code = status_code_name code;
                          message =
                            (match Grpc.Status.message status with
                            | Some m -> m
                            | None -> "no message");
                        }))))
end
