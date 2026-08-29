(** What a transaction means, derived from the bytes that will be signed.

    A signer approves a 32-byte digest. This module exists so that what it is
    shown and what it signs are the same object: {!derive} takes the serialized
    [raw_data] and nothing else. It never sees the builder's arguments, so a
    builder that disagreed with its own output cannot hide it here.

    {2 What is always shown}

    [permission_id], [fee_limit] and [expiration] are non-optional fields of
    {!t}. Approving a Tron transaction without them is the failure mode named in
    [vault/Reuna/Attic/OCaml web3 state of the art status.md]:

    {v
    approving a transaction without exposing fee_limit, permission ID,
       energy/bandwidth and expiration
    v}

    A signer that renders {!t} therefore cannot omit them by accident.

    {2 What this cannot tell you}

    - Whether the signer's key is in the named permission. That is on chain;
      fetch it and use {!Permission}.
    - What a contract will actually do. {!Trc20_transfer} means the call
      {i looks like} a TRC-20 transfer. Whether that contract address is the
      token you think it is, is the caller's question.
    - Whether the reference block is recent, or from the chain you meant.
      Nothing here reads a clock or a network. See {!Tron_types.Block_ref}.

    {2 Fee and resource cost}

    Bandwidth is the transaction's own byte count, so {!bandwidth_cost} can be
    computed here. Energy cannot: it is the sum of the TVM instruction costs of
    a call that has not run yet, and only a node can estimate it. *)

type instruction =
  | Trx_transfer of {
      from : Tron_types.Address.t;
      to_ : Tron_types.Address.t;
      amount : Tron_types.Sun.t;
    }
  | Trc10_transfer of {
      from : Tron_types.Address.t;
      to_ : Tron_types.Address.t;
      asset : string;
      amount : int64;
    }
  | Trc20_call of {
      owner : Tron_types.Address.t;
      contract : Tron_types.Address.t;
      call : Trc20.call;
      call_value : Tron_types.Sun.t;
    }  (** A TVM call whose data decodes as a known TRC-20 function. *)
  | Contract_call of {
      owner : Tron_types.Address.t;
      contract : Tron_types.Address.t;
      selector : string;  (** 4 bytes. *)
      call_value : Tron_types.Sun.t;
      data_sha256 : string;
    }
      (** A TVM call this library cannot explain further. The selector is shown
          because it is the most a reviewer can be told truthfully; the digest
          is there so two such calls can be told apart. *)
  | Stake of {
      owner : Tron_types.Address.t;
      amount : Tron_types.Sun.t;
      resource : Contract.resource;
    }
  | Delegate of {
      owner : Tron_types.Address.t;
      receiver : Tron_types.Address.t;
      amount : Tron_types.Sun.t;
      resource : Contract.resource;
      lock_period : int64;
    }
  | Opaque of { type_url : string; value_sha256 : string }
      (** A contract type this library does not decode. Never approvable. *)

type t = {
  instruction : instruction;
  permission_id : int;
  fee_limit : Tron_types.Sun.t option;
  expiration : int64;
  timestamp : int64;
  memo : string;
  block_ref : Tron_types.Block_ref.t;
  tx_id : Tron_types.Tx_id.t;
  size : int;  (** Serialized [raw_data] length, in bytes. *)
}

val derive : string -> (t, Raw_data.error) result
(** From serialized [raw_data] -- the exact bytes whose SHA-256 is signed. *)

val of_raw_data : Raw_data.t -> t
val of_transaction : Transaction.t -> t

val bandwidth_cost : t -> int
(** The transaction's on-chain byte count, which is what bandwidth is charged
    in. Each account has a free 600-bandwidth daily quota; past it, staked
    bandwidth is consumed, and past that TRX is burned at the node's
    [getTransactionFee] rate.

    Computed from the serialized transaction, so it includes the signatures --
    which is why {!of_transaction} gives a larger figure than {!of_raw_data}.
    Callers pricing a transaction they are about to send want the former. *)

(** {1 Policies}

    Allow-lists, not deny-lists. Each states the complete shape it will accept
    and refuses everything else, so a contract type added to {!instruction}
    later does not silently become approvable under an existing policy. *)

type policy_error =
  [ `Unexpected_instruction of string
  | `Wrong_signer of Tron_types.Address.t
  | `Wrong_destination of Tron_types.Address.t
  | `Amount_exceeds_limit of Tron_types.Sun.t
  | `Token_amount_exceeds_limit of Z.t
  | `Unexpected_call_value of Tron_types.Sun.t
  | `Fee_limit_missing
  | `Fee_limit_exceeds of Tron_types.Sun.t
  | `Untrusted_contract of Tron_types.Address.t
  | `Non_owner_permission of int
  | `Expired of int64 ]

val pp_policy_error : Format.formatter -> [< policy_error ] -> unit

val validate_trx_transfer :
  ?from:Tron_types.Address.t ->
  ?to_:Tron_types.Address.t ->
  ?max_amount:Tron_types.Sun.t ->
  ?now:int64 ->
  t ->
  (unit, policy_error) result
(** Accepts exactly one {!Trx_transfer} under permission [0].

    [now] is the caller's wall clock in milliseconds, checked against
    [expiration]. It is an argument because nothing in this library reads a
    clock; omit it and freshness is simply not checked, which is the honest
    default for a signer that has no trusted time source. *)

val validate_trc20_transfer :
  ?from:Tron_types.Address.t ->
  ?to_:Tron_types.Address.t ->
  ?max_amount:Z.t ->
  ?max_fee_limit:Tron_types.Sun.t ->
  trusted_contracts:Tron_types.Address.t list ->
  ?now:int64 ->
  t ->
  (unit, policy_error) result
(** Accepts exactly one {!Trc20_call} carrying a {!Trc20.Transfer}, under
    permission [0], to a contract in [trusted_contracts], with a [fee_limit]
    present.

    [trusted_contracts] has no default and is not optional. A TRC-20 token is an
    arbitrary contract that chose to expose a familiar selector; there is no
    property of the bytes that distinguishes the real USDT from a contract that
    looks exactly like it. Only the caller knows which addresses it means, so
    only the caller can supply them.

    [call_value] must be zero: sending TRX alongside a token transfer is not
    part of this shape, and a non-zero value would move funds the reviewer was
    not shown. *)

val pp_instruction : Format.formatter -> instruction -> unit

val pp : Format.formatter -> t -> unit
(** The reviewable rendering: instruction, permission, fee limit, expiration,
    reference block and transaction id. This is what a human is asked to
    approve. *)
