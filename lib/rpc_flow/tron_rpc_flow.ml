module Http = Http

module type FLOW = sig
  type flow
  type error
  type write_error

  val pp_error : error Fmt.t
  val pp_write_error : write_error Fmt.t
  val read : flow -> (Cstruct.t Mirage_flow.or_eof, error) result Lwt.t
  val write : flow -> Cstruct.t -> (unit, write_error) result Lwt.t
end

module Make (F : FLOW) = struct
  type t = { flow : F.flow; host : string; limits : Http.limits }

  let create ?(host = "localhost") ?(limits = Http.default_limits) flow =
    { flow; host; limits }

  let flow t = t.flow

  module Text = struct
    type nonrec t = t
    type 'a io = 'a Lwt.t

    let return = Lwt.return
    let bind = Lwt.bind

    let transport fmt =
      Format.kasprintf (fun s -> Error (Tron_rpc.Error.Transport s)) fmt

    (* java-tron reports application errors with a 200 and an Error member, so
       a non-200 means the request never reached the application at all -- a
       proxy, a wrong path, a rate limit. Both are checked, at different
       layers; neither implies the other.

       A response with no status line at all never happens on a well-formed
       reply, but treating it as success would be the wrong guess in exactly
       the case where the peer is misbehaving. *)
    let finish status body =
      match status with
      | Some 200 -> Ok body
      | Some code -> Error (Tron_rpc.Error.Http (code, body))
      | None ->
          Error (Tron_rpc.Error.Transport "response carried no status line")

    let exchange t ~path body =
      let request = Http.request ~host:t.host ~path ~body in
      Lwt.bind
        (F.write t.flow (Cstruct.of_string request))
        (function
          | Error e -> Lwt.return (transport "write: %a" F.pp_write_error e)
          | Ok () ->
              let rec read state =
                Lwt.bind (F.read t.flow) (function
                  | Error e -> Lwt.return (transport "read: %a" F.pp_error e)
                  | Ok `Eof ->
                      (* A close mid-response is not an empty response. Feeding
                       the parser nothing lets it decide whether Until_close
                       framing means it already has the whole body. *)
                      Lwt.return
                        (match Http.feed state "" with
                        | Http.Done { status; body } -> finish status body
                        | Http.Failed m -> transport "%s" m
                        | Http.Need_more _ ->
                            transport "connection closed mid-response")
                  | Ok (`Data c) -> (
                      match Http.feed state (Cstruct.to_string c) with
                      | Http.Done { status; body } ->
                          Lwt.return (finish status body)
                      | Http.Failed m -> Lwt.return (transport "%s" m)
                      | Http.Need_more state -> read state))
              in
              read (Http.start ~limits:t.limits ()))
  end

  module Provider = Tron_rpc.Provider.Of_text (Text)
  module Client = Tron_rpc.Provider.Make (Provider)

  let call = Client.call
end
