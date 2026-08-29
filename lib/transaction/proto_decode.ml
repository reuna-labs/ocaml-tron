let protect f what =
  match f () with
  | Ok v -> Ok v
  | Error _ -> Error what
  (* Out_of_memory and Stack_overflow say something about the process rather
     than about the input, so they are re-raised: swallowing them would turn a
     resource problem into a parse error. Everything else here is the reader
     objecting to bytes. *)
  | exception Out_of_memory -> raise Out_of_memory
  | exception Stack_overflow -> raise Stack_overflow
  | exception _ -> Error what
