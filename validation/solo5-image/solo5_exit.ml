(* solo5_exit, as its own module so unikernel.ml can end a run.

   The tender's exit is a C primitive; OCaml's Stdlib.exit would run at_exit
   handlers and return through caml_startup, which is not what a guest wants
   when it has decided it is done. *)
external exit : int -> 'a = "tron_solo5_exit"
