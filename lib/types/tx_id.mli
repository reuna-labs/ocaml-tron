(** Transaction ids and block ids: 32-byte SHA-256 digests.

    A transaction id is [SHA-256] of the serialized [raw_data]. It is {b not}
    Keccak-256; Keccak appears in this protocol only in address derivation and
    ABI selectors, and since both produce 32 bytes, swapping them fails
    silently. See [docs/protocol-pin.md].

    Block ids are the same width and are carried by the same type, because
    [ref_block_hash] slices one and callers otherwise end up passing raw strings
    around. {!Block_ref} is where the slicing lives. *)

type t = private string
type error = [ `Invalid_length | `Invalid_format ]

val pp_error : Format.formatter -> [< error ] -> unit

val length : int
(** [32]. *)

val of_bytes : string -> (t, error) result
val to_bytes : t -> string

val of_bytes_exn : string -> t
(** @raise Invalid_argument if not 32 bytes. For literals and test vectors. *)

val of_hex : string -> (t, error) result
(** 64 hex characters, with or without a [0x] prefix, either case. *)

val to_hex : t -> string
(** Lowercase, unprefixed. This is the form java-tron's HTTP API uses. *)

val equal : t -> t -> bool
val compare : t -> t -> int
val pp : Format.formatter -> t -> unit
