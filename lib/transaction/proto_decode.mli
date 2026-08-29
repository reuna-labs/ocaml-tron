(** Decoding generated protobuf without trusting it to be total.

    [ocaml-protoc-plugin]'s [from_proto] returns a [result], and on malformed
    input it also raises. Its [Result.catch] handles only its own exception, so
    a [Failure] from the field-header reader travels straight out of what looks
    like a total function:

    {[
    Raw_data.of_bytes "&!cf\181(\224J..."
    (* Failure "Illegal field header: 0x26" *)
    ]}

    Every decoder in this library faces bytes chosen by a remote node, and each
    one's type says it returns a [result]. That promise has to be kept here
    rather than assumed from a dependency.

    Found by [fuzz/fuzz_raw_data.ml]. *)

val protect : (unit -> ('a, 'e) result) -> string -> ('a, string) result
(** [protect f what] runs [f], turning any exception -- and any decode error --
    into [Error what]. *)
