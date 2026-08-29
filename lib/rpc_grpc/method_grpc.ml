type 'a t = {
  service : string;
  rpc : string;
  request : string;
  decode : string -> ('a, string) result;
}

let make ~service ~rpc ~request decode = { service; rpc; request; decode }

let of_rpc (type req resp)
    (module R : Ocaml_protoc_plugin.Service.Rpc
      with type Request.t = req
       and type Response.t = resp) (req : req) (f : resp -> ('a, string) result)
    =
  (* The generated stub knows its own names. Writing them out again here would
     be a second source of truth that a schema bump could not update. *)
  let service =
    match R.package_name with
    | Some p -> p ^ "." ^ R.service_name
    | None -> R.service_name
  in
  {
    service;
    rpc = R.method_name;
    request = Ocaml_protoc_plugin.Writer.contents (R.Request.to_proto req);
    decode =
      (fun body ->
        (* Through Proto_decode.protect: the generated reader raises on some
           malformed input despite its result type, and a response body is
           whatever the node sent. *)
        match
          Tron_transaction.Proto_decode.protect
            (fun () ->
              R.Response.from_proto (Ocaml_protoc_plugin.Reader.create body))
            R.method_name
        with
        | Error _ ->
            Error (Printf.sprintf "%s: response did not decode" R.method_name)
        | Ok resp -> f resp);
  }
