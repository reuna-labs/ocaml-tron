(** Tron account and contract addresses.

    The type is the 21-byte binary form -- a [0x41] prefix followed by 20 bytes
    of hash. Everything else is a rendering of it:

    - {!to_base58check} is the user-facing form, 34 characters starting [T];
    - {!to_hex} is what the HTTP API returns when [visible=false];
    - {!to_abi_word} is what goes into a TVM call, and is 20 bytes wide, not 21.

    Keeping the binary form as the type is deliberate. Confusing the 21-byte
    address with its Base58Check spelling is named as a Tron risk in
    [vault/Reuna/Attic/OCaml web3 state of the art status.md], and writing a
    21-byte address into a 32-byte ABI word shifts every subsequent byte -- a
    silent fund-loss bug rather than a decode failure. *)

type t = private string

type error =
  [ `Invalid_length
    (** Not 21 bytes, or not the expected width for the form. *)
  | `Invalid_prefix  (** The leading byte is not [0x41]. *)
  | `Invalid_checksum  (** Base58Check's trailing 4 bytes do not match. *)
  | `Invalid_format  (** Not decodable as the form claimed. *) ]

val pp_error : Format.formatter -> [< error ] -> unit

val prefix : char
(** [0x41]. The mainnet address prefix, and the reason every Base58Check Tron
    address starts with [T]. The testnets use it too: Nile and Shasta are not
    distinguished by an address prefix, which is why an address alone can never
    tell a signer which chain it is for. See {!Network}. *)

val length : int
(** [21]. *)

(** {1 Binary} *)

val of_bytes : string -> (t, error) result
(** The 21-byte form, prefix included. *)

val to_bytes : t -> string

val of_bytes_exn : string -> t
(** @raise Invalid_argument if invalid. For literals and test vectors only. *)

val of_hash20 : string -> (t, error) result
(** The 20-byte hash without its prefix, as produced by hashing a public key or
    read out of an ABI word. Prepends {!prefix}. *)

val to_hash20 : t -> string
(** The 20 bytes after the prefix. This, not {!to_bytes}, is what an EVM-shaped
    consumer means by "the address". *)

(** {1 Base58Check} *)

val of_base58check : string -> (t, error) result
val to_base58check : t -> string

(** {1 Hex} *)

val of_hex : string -> (t, error) result
(** 42 hex characters, with or without a [0x] prefix, either case. This is the
    form java-tron's HTTP API returns when [visible] is false. *)

val to_hex : t -> string
(** Lowercase, unprefixed, 42 characters -- the form java-tron accepts. *)

(** {1 Contract ABI} *)

val to_abi_word : t -> string
(** The 32-byte ABI word: 12 zero bytes then {!to_hash20}. The [0x41] prefix is
    {b not} included, which is what TronWeb and Trident emit and what the TVM
    reads. *)

val of_abi_word : string -> (t, error) result
(** Reads the last 20 bytes of a 32-byte word and prepends {!prefix}.

    Accepts both encodings Tron allows: the canonical form with 12 leading zero
    bytes, and the variant carrying [0x41] at byte 11. It does {b not} check
    that the leading bytes are zero beyond that, because the TVM does not either
    -- a word whose high bytes are garbage still names this address on chain,
    and a decoder that rejected it would disagree with the machine that is going
    to execute the call. *)

(** {1 Comparison} *)

val equal : t -> t -> bool
val compare : t -> t -> int

val pp : Format.formatter -> t -> unit
(** Prints the Base58Check form: this is what a human reviews. *)
