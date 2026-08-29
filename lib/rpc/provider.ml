module type S = sig
  type t
  type 'a io

  val return : 'a -> 'a io
  val bind : 'a io -> ('a -> 'b io) -> 'b io

  val request :
    t -> path:string -> body:Yojson.Safe.t -> (Yojson.Safe.t, Error.t) result io
end

module type TEXT = sig
  type t
  type 'a io

  val return : 'a -> 'a io
  val bind : 'a io -> ('a -> 'b io) -> 'b io
  val exchange : t -> path:string -> string -> (string, Error.t) result io
end

module Of_text (X : TEXT) = struct
  type t = X.t
  type 'a io = 'a X.io

  let return = X.return
  let bind = X.bind

  let request t ~path ~body =
    X.bind
      (X.exchange t ~path (Yojson.Safe.to_string body))
      (function
        | Error e -> X.return (Error e)
        | Ok raw -> (
            match Yojson.Safe.from_string raw with
            | exception Yojson.Json_error m ->
                X.return (Error (Error.Malformed_json m))
            | json -> (
                (* java-tron signals failure with a 200 and an Error member, so
                 this check is not redundant with the status line. *)
                match Json.error_of json with
                | Some (code, message) ->
                    X.return (Error (Error.Node { code; message }))
                | None -> X.return (Ok json))))
end

module Make (P : S) = struct
  let call t (m : 'a Method.t) =
    P.bind (P.request t ~path:m.path ~body:m.body) (function
      | Error e -> P.return (Error e)
      | Ok json -> (
          match m.decode json with
          | Ok v -> P.return (Ok v)
          | Error e -> P.return (Error (Error.Invalid_response e))))
end
