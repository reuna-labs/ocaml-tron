(** TRX amounts, in sun.

    Every operation is checked and returns a [result]. An amount that silently
    wraps [int64] -- a sum of outputs, say -- is a fund-loss bug rather than a
    rounding error, so the type refuses to let it happen quietly.

    Values are constrained to [[0, Int64.max_int]]. Unlike Cardano's lovelace
    there is no protocol-defined supply cap to check against: java-tron carries
    balances as a plain [int64] and the schema states no maximum, so this type
    does not invent one. The upper bound here is the representation's, not the
    protocol's. *)

type t = private int64

type error =
  [ `Overflow of string
    (** The named operation left the representable range. *)
  | `Invalid_range  (** Negative. *)
  | `Invalid_format  (** A decimal figure this type cannot represent exactly. *)
  ]

val pp_error : Format.formatter -> [< error ] -> unit
val zero : t

val sun_per_trx : int64
(** [1_000_000]. *)

(** {1 Conversion} *)

val of_sun : int64 -> (t, error) result
val to_sun : t -> int64

val of_sun_exn : int64 -> t
(** @raise Invalid_argument if negative. For literals only. *)

val of_trx_string : string -> (t, error) result
(** Parses a decimal figure in TRX, such as ["1.234567"], with at most six
    decimal places. Rejects anything it cannot represent exactly rather than
    rounding: a silently rounded amount is a wrong amount. Deliberately does not
    go through [float]. *)

val to_trx_string : t -> string
(** The exact decimal figure in TRX, trailing zeros trimmed. Round-trips through
    {!of_trx_string}. *)

(** {1 Arithmetic} *)

val add : t -> t -> (t, error) result
val sub : t -> t -> (t, error) result
val mul : t -> int -> (t, error) result
val sum : t list -> (t, error) result

(** {1 Comparison} *)

val compare : t -> t -> int
val equal : t -> t -> bool
val min : t -> t -> t
val max : t -> t -> t

val pp : Format.formatter -> t -> unit
(** Prints the TRX figure with its unit, e.g. [1.5 TRX]: a human reviewing a
    transaction is being asked about TRX, not about sun. *)
