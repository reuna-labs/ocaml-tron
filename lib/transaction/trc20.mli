(** TRC-20, built through the Ethereum Contract ABI.

    TRC-20 is ERC-20: the same function signatures, the same selectors, the same
    head/tail argument encoding. There is one difference and it matters -- the
    [address] type is the 20-byte form left-padded to 32 bytes, with Tron's
    [0x41] prefix stripped. That single fact is why this module exists rather
    than callers reaching for {!Evm_abi} directly: it is the one place a 21-byte
    address could be written into a 32-byte word, and doing so shifts every
    following byte without failing anything.

    Encoding goes through [evm-abi] unchanged. Nothing about the ABI is
    reimplemented here. *)

val transfer_selector : string
(** [a9059cbb] as 4 raw bytes -- [keccak256("transfer(address,uint256)")[0:4]].
*)

val transfer : to_:Tron_types.Address.t -> amount:Z.t -> (string, string) result
(** The [data] field for [transfer(address,uint256)]. *)

val transfer_from :
  from:Tron_types.Address.t ->
  to_:Tron_types.Address.t ->
  amount:Z.t ->
  (string, string) result

val approve :
  spender:Tron_types.Address.t -> amount:Z.t -> (string, string) result

val balance_of : owner:Tron_types.Address.t -> (string, string) result
(** For [/wallet/triggerconstantcontract]; this is a read, not a transaction. *)

(** {1 Decoding} *)

type call =
  | Transfer of { to_ : Tron_types.Address.t; amount : Z.t }
  | Transfer_from of {
      from : Tron_types.Address.t;
      to_ : Tron_types.Address.t;
      amount : Z.t;
    }
  | Approve of { spender : Tron_types.Address.t; amount : Z.t }
  | Balance_of of { owner : Tron_types.Address.t }

val decode : string -> call option
(** Recognises a TRC-20 call in a [TriggerSmartContract]'s [data].

    [None] for anything else, including a call to a function that merely shares
    a selector prefix or that has trailing bytes past its arguments. This is the
    input to a policy decision, so "probably a transfer" is not an answer it may
    give.

    A contract is free to implement [transfer(address,uint256)] with entirely
    different semantics; a matching selector says what the call looks like, not
    what the contract will do. Which contract addresses are trusted is the
    caller's question. *)

val call_to_ : call -> Tron_types.Address.t option
val call_amount : call -> Z.t option
val pp_call : Format.formatter -> call -> unit
