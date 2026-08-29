type t = { name : string; genesis_block_id : Tx_id.t }

let make ~name ~genesis_block_id = { name; genesis_block_id }

let expected ~name hex =
  match Tx_id.of_hex hex with
  | Error _ -> Error `Invalid_format
  | Ok genesis_block_id -> Ok { name; genesis_block_id }

let verify ~expect ~observed =
  if Tx_id.equal expect.genesis_block_id observed then Ok ()
  else Error (`Wrong_chain (expect, observed))

let name t = t.name
let genesis_block_id t = t.genesis_block_id

let equal a b =
  String.equal a.name b.name
  && Tx_id.equal a.genesis_block_id b.genesis_block_id

let pp ppf t =
  Format.fprintf ppf "%s (genesis %s)" t.name (Tx_id.to_hex t.genesis_block_id)
