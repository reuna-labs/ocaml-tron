(* The offline surface of the Tron SDK.

   Transports are not here. tron-rpc-flow and tron-rpc-unix are separate
   packages, so a consumer linking this one takes on no Lwt, no Unix and no
   socket -- which is what makes it linkable into a Solo5 unikernel. *)

module Address = Tron_types.Address
module Sun = Tron_types.Sun
module Tx_id = Tron_types.Tx_id
module Block_ref = Tron_types.Block_ref
module Network = Tron_types.Network
module Crypto = Tron_crypto
module Contract = Tron_transaction.Contract
module Raw_data = Tron_transaction.Raw_data
module Transaction = Tron_transaction.Transaction
module Permission = Tron_transaction.Permission
module Trc20 = Tron_transaction.Trc20
module Intent = Tron_transaction.Intent
module Rpc = Tron_rpc

(* The generated wire types, for a caller that needs a message this library does
   not model. Reaching for these means leaving the validated layer behind:
   nothing in Proto is checked, and Transaction.Contract.parameter is an
   unnarrowed google.protobuf.Any. *)
module Proto = Tron_proto
