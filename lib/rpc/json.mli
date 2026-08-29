(** Decoding java-tron's JSON, which is not canonical protobuf JSON.

    Two differences, both load-bearing:

    - [bytes] fields are {b hex}, not base64. A generated protobuf JSON codec
      would read them as base64 and produce garbage that sometimes decodes.
    - The [visible] request flag switches addresses between hex and Base58Check
      in the {i response}. It is per-request, so the decoder has to be told
      which form to expect rather than guessing.

    Everything here is hand-written against a pinned java-tron release for
    exactly that reason. See [docs/protocol-pin.md]. *)

type t = Yojson.Safe.t
type 'a decoder = t -> ('a, string) result

val error_of : t -> (string * string) option
(** java-tron reports failures as a 200 whose body carries [Error], sometimes
    with [code]. Returns [(code, message)] when the body is one of those.

    The message is itself hex-encoded in some responses and plain in others;
    this decodes it when it can and passes it through when it cannot, because an
    error message that fails to decode is still worth showing. *)

val field : string -> t -> t option
val string_field : string -> t -> (string, string) result
val int64_field : string -> t -> (int64, string) result
val bool_field : string -> t -> bool
val list_field : string -> t -> (t list, string) result

val opt_int64_field : string -> t -> int64
(** Absent means [0]. java-tron omits int64 fields at their default rather than
    sending a zero, so absent and zero are the same statement. *)

val hex_field : string -> t -> (string, string) result
(** A [bytes] field: hex in, raw bytes out. *)

val address_field : string -> t -> (Tron_types.Address.t, string) result
(** Accepts either rendering, because which one arrives depends on the [visible]
    flag the request set, and a decoder that accepted only one would break the
    moment a caller flipped it. *)

val tx_id_field : string -> t -> (Tron_types.Tx_id.t, string) result
val sun_field : string -> t -> (Tron_types.Sun.t, string) result
