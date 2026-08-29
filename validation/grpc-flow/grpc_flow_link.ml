(* gRPC over a flow that is not a socket.

   The flow here is a pair of in-memory buffers. It satisfies the same
   signature mirage-vsock-solo5 exposes, which is the whole point: if the
   client can be built over this, it can be built over a vsock, and the
   confidential Solo5 targets are reachable.

   Nothing is sent. Establishing the connection would need a peer speaking
   HTTP/2, and a peer is not what is in question -- the functor closing is. *)

module Buffer_flow = struct
  type flow = { mutable inbox : Cstruct.t; mutable outbox : Cstruct.t }
  type error = |
  type write_error = |

  let pp_error : error Fmt.t = fun _ -> function _ -> .
  let pp_write_error : write_error Fmt.t = fun _ -> function _ -> .

  let read t =
    if Cstruct.length t.inbox = 0 then Lwt.return (Ok `Eof)
    else begin
      let cs = t.inbox in
      t.inbox <- Cstruct.empty;
      Lwt.return (Ok (`Data cs))
    end

  let write t cs =
    t.outbox <- Cstruct.append t.outbox cs;
    Lwt.return (Ok ())
end

module Client = Tron_rpc_grpc.Make (Buffer_flow)

let () =
  (* The methods are values, so the catalogue can be inspected without a peer.
     Each carries the service and method names the schema defines. *)
  let show name (m : _ Tron_rpc_grpc.Method.t) =
    Printf.printf "%-22s %s/%s  (%d-byte request)\n" name
      m.Tron_rpc_grpc.Method.service m.Tron_rpc_grpc.Method.rpc
      (String.length m.Tron_rpc_grpc.Method.request)
  in
  show "now_block" Tron_rpc_grpc.Wallet.now_block;
  show "genesis_block" Tron_rpc_grpc.Wallet.genesis_block;
  show "chain_parameters" Tron_rpc_grpc.Wallet.chain_parameters;
  let addr =
    Result.get_ok
      (Tron_types.Address.of_hex "417e5f4552091a69125d5dfcb7b8c2659029395bdf")
  in
  show "account" (Tron_rpc_grpc.Wallet.account addr);
  show "account_resources" (Tron_rpc_grpc.Wallet.account_resources addr);

  (* And the client itself builds over the buffer flow. Constructing it would
     start an HTTP/2 handshake with nobody, so the value is left unapplied --
     that the functor closes over a non-socket flow is the thing being
     proved. *)
  let _ = Client.create in
  let _ = Client.call in
  let _ = Client.shutdown in
  print_endline
    "grpc over a non-socket flow: links, with no Unix in the closure"
