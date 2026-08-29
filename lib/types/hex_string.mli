(** Hex, because java-tron's HTTP API encodes every [bytes] field as hex rather
    than the base64 canonical protobuf JSON would use.

    Internal to [tron-types]; the public spellings are {!Address.of_hex} and
    friends. *)

val of_hex : string -> string option
(** Accepts an optional [0x] prefix and either case. [None] on an odd length or
    a non-hex character. *)

val to_hex : string -> string
(** Lowercase, unprefixed. *)
