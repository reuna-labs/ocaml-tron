(** Reading the conformance fixtures.

    A minimal JSON reader rather than a yojson dependency: [tron-types] and
    [tron-crypto] have no JSON in their closure and their tests should not add
    one. Only the shapes the fixtures actually use are supported. *)

type t

val load : string -> t
(** [load path] relative to the repository root. Raises on a missing or
    malformed file: a test that cannot read its oracle has failed, not skipped.
*)

val mem : t -> string -> bool
val field : t -> string -> t
val list : t -> t list
val str : t -> string
val int : t -> int
val get_str : t -> string -> string
val get_int : t -> string -> int
val get_list : t -> string -> t list
val strings : t -> string list

val find : t list -> name:string -> t
(** The element whose ["name"] field matches. *)
