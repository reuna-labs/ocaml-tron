module Sun = Tron_types.Sun

type bandwidth_charge =
  | Free of { points : int64 }
  | Staked of { points : int64 }
  | Burned of { sun : Sun.t }

let bandwidth_charge ~(params : Wallet.chain_parameters)
    ~(resources : Wallet.resources) ~size =
  let need = Int64.of_int size in
  let free_left = Int64.sub resources.free_net_limit resources.free_net_used in
  let staked_left = Int64.sub resources.net_limit resources.net_used in
  (* java-tron's order: free quota, then staked, then burn. *)
  if Int64.compare free_left need >= 0 then Free { points = need }
  else if Int64.compare staked_left need >= 0 then Staked { points = need }
  else
    let sun = Int64.mul need params.transaction_fee in
    Burned
      { sun = (match Sun.of_sun sun with Ok s -> s | Error _ -> Sun.zero) }

let fee_limit_for_energy ~(params : Wallet.chain_parameters) ~energy =
  match Sun.of_sun (Int64.mul energy params.energy_fee) with
  | Ok s -> s
  | Error _ -> Sun.zero

let suggested_fee_limit ~params ~energy ?(headroom_percent = 20) () =
  let base = fee_limit_for_energy ~params ~energy in
  match Sun.mul base (100 + headroom_percent) with
  | Error _ -> base
  | Ok scaled -> (
      match Sun.of_sun (Int64.div (Sun.to_sun scaled) 100L) with
      | Ok s -> s
      | Error _ -> base)
