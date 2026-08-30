module Plain_client = Tron_rpc_flow.Make (Mirage_flow_unix.Fd)

module Tls_flow = struct
  type flow = Tls_lwt.Unix.t
  type error = string
  type write_error = string

  let pp_error = Fmt.string
  let pp_write_error = Fmt.string

  let read flow =
    let buffer = Bytes.create 16_384 in
    Lwt.catch
      (fun () ->
        Lwt.map
          (fun length ->
            let data : Cstruct.t Mirage_flow.or_eof =
              if length = 0 then `Eof
              else `Data (Cstruct.of_bytes (Bytes.sub buffer 0 length))
            in
            Ok data)
          (Tls_lwt.Unix.read flow buffer))
      (fun exn -> Lwt.return (Error (Printexc.to_string exn)))

  let write flow buffer =
    Lwt.catch
      (fun () ->
        Lwt.map
          (fun () -> Ok ())
          (Tls_lwt.Unix.write flow (Cstruct.to_string buffer)))
      (fun exn -> Lwt.return (Error (Printexc.to_string exn)))
end

module Secure_client = Tron_rpc_flow.Make (Tls_flow)

module Endpoint = struct
  type scheme = [ `Http | `Https ]
  type t = { scheme : scheme; host : string; port : int; host_header : string }

  let bracket_ipv6 host =
    if String.contains host ':' then "[" ^ host ^ "]" else host

  let of_string value =
    let value = String.trim value in
    if value = "" then Error "endpoint is empty"
    else
      let uri = Uri.of_string value in
      match (Uri.userinfo uri, Uri.fragment uri) with
      | Some _, _ -> Error "endpoint must not contain user information"
      | _, Some _ -> Error "endpoint must not contain a fragment"
      | None, None -> (
          match Uri.scheme uri with
          | Some scheme -> (
              let scheme = String.lowercase_ascii scheme in
              match (scheme, Uri.host uri) with
              | ("http" | "https"), Some host ->
                  if Uri.path uri <> "" && Uri.path uri <> "/" then
                    Error "endpoint must not contain a base path"
                  else if Uri.query uri <> [] then
                    Error "endpoint must not contain a query"
                  else
                    let scheme = if scheme = "https" then `Https else `Http in
                    let default_port = if scheme = `Https then 443 else 80 in
                    let port =
                      Option.value (Uri.port uri) ~default:default_port
                    in
                    if port < 1 || port > 65535 then
                      Error "endpoint port is outside 1..65535"
                    else
                      let host_header =
                        if port = default_port then bracket_ipv6 host
                        else Printf.sprintf "%s:%d" (bracket_ipv6 host) port
                      in
                      Ok { scheme; host; port; host_header }
              | ("http" | "https"), None -> Error "endpoint has no host"
              | other, _ -> Error ("unsupported endpoint scheme: " ^ other))
          | None -> Error "endpoint must include http:// or https://")

  let scheme endpoint = endpoint.scheme
  let host endpoint = endpoint.host
  let port endpoint = endpoint.port
  let host_header endpoint = endpoint.host_header
end

type flow = [ `Plain of Lwt_unix.file_descr | `Tls of Tls_lwt.Unix.t ]

type t =
  | Plain of Plain_client.t * Lwt_unix.file_descr
  | Secure of Secure_client.t * Tls_lwt.Unix.t

let create ?host ?limits flow =
  Plain (Plain_client.create ?host ?limits flow, flow)

let flow = function
  | Plain (_, flow) -> `Plain flow
  | Secure (_, flow) -> `Tls flow

module Provider = struct
  type nonrec t = t
  type 'a io = 'a Lwt.t

  let return = Lwt.return
  let bind = Lwt.bind

  let request client ~path ~body =
    match client with
    | Plain (client, _) -> Plain_client.Provider.request client ~path ~body
    | Secure (client, _) -> Secure_client.Provider.request client ~path ~body
end

module Client = Tron_rpc.Provider.Make (Provider)

let call = Client.call
let ( let* ) = Lwt.bind

let connect ?(host_header = "localhost") sockaddr domain =
  let fd = Lwt_unix.socket domain Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.connect fd sockaddr in
  Lwt.return (create ~host:host_header fd)

let connect_tcp ?host_header host port =
  let* addresses =
    Lwt_unix.getaddrinfo host (string_of_int port)
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  in
  match addresses with
  | [] -> Lwt.fail_with (Printf.sprintf "cannot resolve %s" host)
  | address :: _ ->
      let host_header = Option.value host_header ~default:host in
      connect ~host_header address.Unix.ai_addr address.Unix.ai_family

let tls_config authenticator =
  let authenticator =
    match authenticator with
    | Some authenticator -> Ok authenticator
    | None -> Ca_certs.authenticator ()
  in
  match authenticator with
  | Error (`Msg message) -> Error (`Msg message)
  | Ok authenticator -> Tls.Config.client ~authenticator ()

let connect_tls ?authenticator ?host_header host port =
  match tls_config authenticator with
  | Error (`Msg message) -> Lwt.fail_with message
  | Ok config ->
      let* flow = Tls_lwt.Unix.connect config (host, port) in
      let host_header = Option.value host_header ~default:host in
      Lwt.return (Secure (Secure_client.create ~host:host_header flow, flow))

let connect_uri ?authenticator ?host_header value =
  match Endpoint.of_string value with
  | Error message -> Lwt.fail_with message
  | Ok endpoint -> (
      let host = Endpoint.host endpoint in
      let port = Endpoint.port endpoint in
      let host_header =
        Option.value host_header ~default:(Endpoint.host_header endpoint)
      in
      match Endpoint.scheme endpoint with
      | `Http -> connect_tcp ~host_header host port
      | `Https -> connect_tls ?authenticator ~host_header host port)

let connect_unix ?host_header path =
  connect ?host_header (Unix.ADDR_UNIX path) Unix.PF_UNIX

let close = function
  | Plain (_, flow) ->
      Lwt.catch (fun () -> Lwt_unix.close flow) (fun _ -> Lwt.return_unit)
  | Secure (_, flow) ->
      Lwt.catch (fun () -> Tls_lwt.Unix.close flow) (fun _ -> Lwt.return_unit)
