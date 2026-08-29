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
  (* A flow hands back whole chunks; gluten asks for at most [len] bytes into a
     buffer it owns. The leftover has to be kept, or every read larger than the
     window silently truncates the stream -- which on HTTP/2 means a frame
     boundary lands in the wrong place and the connection dies with a protocol
     error rather than with anything that names the cause. *)
  type socket = {
    flow : F.flow;
    mutable pending : Cstruct.t;
    mutable eof : bool;
  }

  type addr = unit

  let create flow = { flow; pending = Cstruct.empty; eof = false }
  let flow t = t.flow

  let rec read t buf ~off ~len =
    if Cstruct.length t.pending > 0 then begin
      let n = min len (Cstruct.length t.pending) in
      Bigstringaf.blit_from_string
        (Cstruct.to_string (Cstruct.sub t.pending 0 n))
        ~src_off:0 buf ~dst_off:off ~len:n;
      t.pending <- Cstruct.shift t.pending n;
      Lwt.return n
    end
    else if t.eof then
      (* gluten's read loop treats End_of_file as the orderly close and
         anything else as a transport failure. Signalling a clean EOF any other
         way turns a finished response into an error. *)
      Lwt.fail End_of_file
    else
      Lwt.bind (F.read t.flow) (function
        | Error e ->
            Lwt.fail_with (Format.asprintf "flow read: %a" F.pp_error e)
        | Ok `Eof ->
            t.eof <- true;
            Lwt.fail End_of_file
        | Ok (`Data cs) ->
            (* A zero-length chunk is not EOF, so looping is correct. *)
            t.pending <- cs;
            read t buf ~off ~len)

  let writev t iovecs =
    let total =
      List.fold_left
        (fun acc (io : Faraday.bigstring Faraday.iovec) -> acc + io.len)
        0 iovecs
    in
    if total = 0 then Lwt.return (`Ok 0)
    else begin
      let cs = Cstruct.create total in
      ignore
        (List.fold_left
           (fun dst_off (io : Faraday.bigstring Faraday.iovec) ->
             Cstruct.blit
               (Cstruct.of_bigarray ~off:io.off ~len:io.len io.buffer)
               0 cs dst_off io.len;
             dst_off + io.len)
           0 iovecs);
      Lwt.bind (F.write t.flow cs) (function
        | Ok () -> Lwt.return (`Ok total)
        | Error _ ->
            (* gluten's signature admits only `Closed here, so the specific
               error is lost. The caller gets it back through the RPC result
               instead, which is where it is actionable. *)
            Lwt.return `Closed)
    end

  (* The flow belongs to the caller -- that is why the FLOW signature carries no
     close. On a unikernel it belongs to a device the guest configured, and
     tearing it down from inside an RPC client would take the connection away
     from whoever else holds it. *)
  let shutdown_receive t = t.eof <- true
  let close _ = Lwt.return_unit
end
