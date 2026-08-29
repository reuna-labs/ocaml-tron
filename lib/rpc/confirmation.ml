type t =
  | Unknown
  | In_block of { number : int64; depth : int64 }
  | Failed of { message : string }

let of_receipt ~head = function
  | None -> Unknown
  | Some (r : Wallet.receipt) ->
      if not r.succeeded then
        Failed
          {
            message =
              (if r.result_message = "" then "reverted" else r.result_message);
          }
      else
        let depth = Int64.sub head r.block_number in
        In_block
          {
            number = r.block_number;
            depth = (if Int64.compare depth 0L < 0 then 0L else depth);
          }

let is_final ~depth = function
  | In_block b -> Int64.compare b.depth depth >= 0
  | Unknown | Failed _ -> false

let pp ppf = function
  | Unknown -> Format.pp_print_string ppf "not yet seen"
  | In_block { number; depth } ->
      Format.fprintf ppf "in block %Ld (%Ld deep)" number depth
  | Failed { message } -> Format.fprintf ppf "reverted: %s" message
