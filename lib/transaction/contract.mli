(** The contract carried by a transaction.

    [Transaction.Contract.parameter] is a [google.protobuf.Any]: a [type_url]
    and opaque bytes. The generated bindings cannot narrow it, so narrowing is
    done here, by hand, and it is where validation belongs.

    {2 Unrecognised is not approvable}

    The variant is closed over the launch set and everything else decodes to
    {!Unknown}, carrying the [type_url] and the raw bytes. That is deliberate.
    Tron has 41 contract types and this library implements a handful; a decoder
    that silently dropped the rest, or that guessed at them, would let a policy
    approve a transaction nobody had read. {!Unknown} can be displayed and
    logged. It can never satisfy a policy in {!Intent}.

    Adding a case here is therefore a security decision, not a convenience: it
    moves a contract from "cannot be approved" to "can be". *)

type resource =
  | Bandwidth
  | Energy  (** [core/contract/common.proto]'s [ResourceCode]. *)

type t =
  | Transfer of {
      owner : Tron_types.Address.t;
      to_ : Tron_types.Address.t;
      amount : Tron_types.Sun.t;
    }  (** TRX. [TransferContract]. *)
  | Transfer_asset of {
      asset_name : string;
      owner : Tron_types.Address.t;
      to_ : Tron_types.Address.t;
      amount : int64;
    }
      (** TRC-10. [TransferAssetContract]. The amount is in the asset's own
          units, whose precision is a property of the asset rather than of the
          protocol, so it is not a {!Tron_types.Sun.t}. *)
  | Trigger_smart_contract of {
      owner : Tron_types.Address.t;
      contract : Tron_types.Address.t;
      call_value : Tron_types.Sun.t;  (** TRX sent with the call. *)
      data : string;  (** 4-byte selector then ABI arguments. *)
      call_token_value : int64;
      token_id : int64;
    }  (** TVM. [TriggerSmartContract]. TRC-20 transfers are this. *)
  | Freeze_balance_v2 of {
      owner : Tron_types.Address.t;
      frozen_balance : Tron_types.Sun.t;
      resource : resource;
    }
  | Delegate_resource of {
      owner : Tron_types.Address.t;
      receiver : Tron_types.Address.t;
      balance : Tron_types.Sun.t;
      resource : resource;
      lock : bool;
      lock_period : int64;
    }
  | Unknown of { type_url : string; value : string }
      (** Anything this library does not decode. Never approvable. *)

type error =
  [ `Unknown_type_url of string
  | `Malformed of string  (** The payload did not decode as its [type_url]. *)
  | `Invalid_field of string  (** A field decoded but is not a valid value. *)
  ]

val pp_error : Format.formatter -> [< error ] -> unit

val type_url : t -> string
(** The [type.googleapis.com/protocol.*] URL this contract packs as. *)

val contract_type :
  t -> Tron_proto.Tron.Protocol.Transaction.Contract.ContractType.t
(** The enum that travels in the [type] field alongside the [Any]. Both are on
    the wire and both are covered by the signature, so they have to agree. *)

val to_proto :
  ?permission_id:int -> t -> Tron_proto.Tron.Protocol.Transaction.Contract.t
(** [permission_id] defaults to [0], the owner permission. *)

val of_proto :
  Tron_proto.Tron.Protocol.Transaction.Contract.t -> (t, error) result
(** Narrows the [Any]. A [type_url] outside the launch set yields {!Unknown}
    rather than an error: an unrecognised contract is a thing this library can
    faithfully report, and reporting it is more useful than refusing to decode
    the transaction that carries it.

    Errors are reserved for a payload that claims a [type_url] this library
    {i does} know and then fails to decode as it, or decodes to a field that is
    not a valid value -- a 20-byte owner address, say. That is a malformed
    transaction, not an unfamiliar one. *)

val pp : Format.formatter -> t -> unit
