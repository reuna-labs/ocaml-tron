module Tx_id = Tron_types.Tx_id

type config = {
  max_broadcast_attempts : int;
  max_polls : int;
  required_depth : int64;
}

let default_config =
  { max_broadcast_attempts = 3; max_polls = 20; required_depth = 19L }

type phase =
  | Awaiting_reference_block
  | Awaiting_signature of { block : Wallet.block_head }
  | Broadcasting of { hex : string; id : Tx_id.t; expiration : int64 }
  | Polling of { id : Tx_id.t; expiration : int64 }
  | Awaiting_head of {
      id : Tx_id.t;
      receipt : Wallet.receipt option;
      expiration : int64;
    }
  | Rebuilding of { reason : string }
  | Finished of { id : Tx_id.t; confirmation : Confirmation.t }
  | Abandoned of { reason : string }

type state = {
  config : config;
  phase : phase;
  broadcasts : int;
  polls : int;
  head : int64;
  confirmation : Confirmation.t;
}

type step =
  | Need_reference_block
  | Need_broadcast of { hex : string }
  | Need_receipt of { tx_id : Tx_id.t }
  | Need_head
  | Rebuild of { reason : string }
  | Done of { tx_id : Tx_id.t; confirmation : Confirmation.t }
  | Give_up of { reason : string }

let start ?(config = default_config) () =
  {
    config;
    phase = Awaiting_reference_block;
    broadcasts = 0;
    polls = 0;
    head = 0L;
    confirmation = Confirmation.Unknown;
  }

let step t =
  match t.phase with
  | Awaiting_reference_block -> Need_reference_block
  (* The caller has a block and now has to build, review and sign. There is no
     step for that: it is not this machine's decision, and pretending otherwise
     would let a caller drive the workflow without ever showing anyone the
     intent. *)
  | Awaiting_signature _ -> Need_reference_block
  | Broadcasting { hex; _ } -> Need_broadcast { hex }
  | Polling { id; _ } -> Need_receipt { tx_id = id }
  | Awaiting_head _ -> Need_head
  | Rebuilding { reason } -> Rebuild { reason }
  | Finished { id; confirmation } -> Done { tx_id = id; confirmation }
  | Abandoned { reason } -> Give_up { reason }

(* Finished and Abandoned are absorbing.

   Without this, a machine that has given up can be walked back into asking for
   a broadcast: got_reference_block accepted an event in any phase, so a caller
   that kept feeding events after a terminal state would get Need_broadcast for
   a transaction the machine had already refused. A driver would not normally
   do that, but a state machine that is pure and total should not depend on
   being driven politely -- being able to reason about it without reasoning
   about its caller is the whole point of it being separate.

   Found by fuzz/fuzz_submission.ml. *)
let terminal t =
  match t.phase with Finished _ | Abandoned _ -> true | _ -> false

let got_reference_block t block =
  if terminal t then t else { t with phase = Awaiting_signature { block } }

let got_signed t ~tx_id ~hex ~expiration =
  if terminal t then t
  else { t with phase = Broadcasting { hex; id = tx_id; expiration } }

let got_broadcast t (r : Wallet.broadcast_result) =
  match t.phase with
  | Broadcasting { id; expiration; _ } ->
      if r.accepted then
        {
          t with
          phase = Polling { id; expiration };
          broadcasts = t.broadcasts + 1;
        }
      else
        let reason =
          match (r.code, r.message) with
          | Some c, Some m -> Printf.sprintf "%s: %s" c m
          | Some c, None -> c
          | None, Some m -> m
          | None, None -> "rejected without a reason"
        in
        (* A stale reference block is the one rejection worth retrying, and it
           is retried by rebuilding, not by resending. Everything else is the
           transaction being wrong, and sending it again will not make it
           right. *)
        let stale =
          let needles = [ "TAPOS"; "expired"; "Expired"; "block hash" ] in
          List.exists
            (fun n ->
              let re_len = String.length n and s_len = String.length reason in
              let rec go i =
                i + re_len <= s_len
                && (String.sub reason i re_len = n || go (i + 1))
              in
              re_len <= s_len && go 0)
            needles
        in
        if stale && t.broadcasts + 1 < t.config.max_broadcast_attempts then
          {
            t with
            phase = Rebuilding { reason };
            broadcasts = t.broadcasts + 1;
          }
        else
          { t with phase = Abandoned { reason }; broadcasts = t.broadcasts + 1 }
  | _ -> t

let got_receipt t receipt =
  match t.phase with
  | Polling { id; expiration } -> (
      match receipt with
      | Some _ -> { t with phase = Awaiting_head { id; receipt; expiration } }
      | None ->
          let polls = t.polls + 1 in
          if polls >= t.config.max_polls then
            {
              t with
              polls;
              phase = Abandoned { reason = "no receipt within the poll budget" };
            }
          else { t with polls; phase = Polling { id; expiration } })
  | _ -> t

let got_head t head =
  match t.phase with
  | Awaiting_head { id; receipt; expiration } -> (
      let confirmation = Confirmation.of_receipt ~head receipt in
      match confirmation with
      (* A reverted transaction is finished. It is on chain, it charged a fee,
         and no amount of further depth will change what it did. *)
      | Confirmation.Failed _ ->
          { t with head; confirmation; phase = Finished { id; confirmation } }
      | _ ->
          if Confirmation.is_final ~depth:t.config.required_depth confirmation
          then
            { t with head; confirmation; phase = Finished { id; confirmation } }
          else
            (* Included but not deep enough. Keep going: the receipt will not
               change, but the head will, and depth is measured against it. *)
            let polls = t.polls + 1 in
            if polls >= t.config.max_polls then
              {
                t with
                head;
                confirmation;
                polls;
                phase =
                  Abandoned
                    {
                      reason =
                        "included, but not deep enough within the poll budget";
                    };
              }
            else
              {
                t with
                head;
                confirmation;
                polls;
                phase = Polling { id; expiration };
              })
  | _ -> { t with head }

let failed t (e : Error.t) =
  match t.phase with
  (* A broadcast that failed in transit may still have been accepted. Sending
     it again risks nothing on Tron -- the txID is the same and a duplicate is
     rejected -- but polling first is cheaper and tells us which it was. *)
  | Broadcasting { id; expiration; _ } ->
      { t with phase = Polling { id; expiration } }
  | Polling { id; expiration } ->
      let polls = t.polls + 1 in
      if polls >= t.config.max_polls then
        { t with polls; phase = Abandoned { reason = Error.to_string e } }
      else { t with polls; phase = Polling { id; expiration } }
  | Awaiting_reference_block | Awaiting_signature _ ->
      { t with phase = Abandoned { reason = Error.to_string e } }
  | _ -> t

let expired t =
  match t.phase with
  | Finished _ | Abandoned _ -> t
  | Polling _ | Broadcasting _ | Awaiting_head _ ->
      if t.broadcasts < t.config.max_broadcast_attempts then
        {
          t with
          phase =
            Rebuilding { reason = "transaction expired before it was included" };
        }
      else
        {
          t with
          phase = Abandoned { reason = "expired, and out of rebuild attempts" };
        }
  | Awaiting_reference_block | Awaiting_signature _ ->
      {
        t with
        phase =
          Rebuilding { reason = "reference block went stale before signing" };
      }
  | Rebuilding _ -> t

let tx_id t =
  match t.phase with
  | Broadcasting { id; _ }
  | Polling { id; _ }
  | Awaiting_head { id; _ }
  | Finished { id; _ } ->
      Some id
  | _ -> None

let confirmation t = t.confirmation
let head t = t.head
