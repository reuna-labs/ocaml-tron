module Flow = Tron_rpc_flow.Make (Mirage_flow_unix.Fd)

type t = Flow.t

let create = Flow.create
let flow = Flow.flow
let call = Flow.call

module Provider = Flow.Provider

let connect ?(host_header = "localhost") sockaddr domain =
  let fd = Lwt_unix.socket domain Unix.SOCK_STREAM 0 in
  Lwt.bind (Lwt_unix.connect fd sockaddr) (fun () ->
      Lwt.return (create ~host:host_header fd))

let connect_tcp ?host_header host port =
  Lwt.bind
    (Lwt_unix.getaddrinfo host (string_of_int port)
       [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ])
    (function
      | [] -> Lwt.fail_with (Printf.sprintf "cannot resolve %s" host)
      | ai :: _ ->
          let host_header =
            match host_header with Some h -> h | None -> host
          in
          connect ~host_header ai.Unix.ai_addr ai.Unix.ai_family)

let connect_unix ?host_header path =
  connect ?host_header (Unix.ADDR_UNIX path) Unix.PF_UNIX
