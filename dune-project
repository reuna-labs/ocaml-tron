(lang dune 3.6)

(name tron)

(version 0.1.0~alpha1)

(generate_opam_files true)

; Careful: the *.opam files are generated from this one, but tron.opam also
; carries a hand-maintained `pin-depends:` block that dune cannot express, kept
; alongside in tron.opam.template. Regenerating drops it from tron.opam, and the
; drop is silent -- the package still solves, just against released
; mirage-crypto instead of the fork that provides Secp256k1 and Keccak256.
; Re-add it after any regeneration. ocaml-cardano, ocaml-bitcoin and ocaml-mpc
; carry the same hazard; ocaml-cometbft gave up on generation over it.

(implicit_transitive_deps false)

(source
 (github reuna-labs/ocaml-tron))

(license ISC)

(authors "Gil Bahat <bahat.gil@gmail.com>")

(maintainers "Gil Bahat <bahat.gil@gmail.com>")

; zarith, and therefore GMP, is in this closure and cannot be removed. It enters
; twice: web3-codec-basen backs Base58, and mirage-crypto-blockchain's Secp256k1
; is the reference bignum implementation behind public-key recovery. Cardano
; avoids GMP because it is Ed25519-only; Tron has no such option. Unikernel
; builds must therefore supply GMP -- see docs/unikernel.md.
;
; What is enforced instead is the I/O boundary: every package below except
; tron-rpc-flow and tron-rpc-unix is free of unix, lwt, clock, RNG and
; transport. test/no_io_guard.sh checks this from the declared dependencies,
; not by grepping sources.

(package
 (name tron-proto)
 (synopsis "Generated protobuf bindings for the Tron protocol")
 (description
  "Bindings generated with ocaml-protoc-plugin from the .proto tree vendored at\nproto/, pinned to tronprotocol/protocol 8432bec. The generated sources are\ncommitted, so building this package requires neither protoc nor the plugin.\n\nDepends only on web3-codec-protobuf, whose closure is base64 + ptime, and in\nparticular not on unix, so it links into a MirageOS/Solo5 unikernel.\n\nThese are wire types, not a validated model. Transaction.Contract.parameter is\na google.protobuf.Any that the generated code cannot narrow; narrowing it is\ntron-transaction's job.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (web3-codec-protobuf (>= 0.1.0~alpha1))))

(package
 (name tron-types)
 (synopsis "Validated primitive types for Tron")
 (description
  "Addresses, amounts in sun, transaction ids and block references, each\nvalidated at construction. The 21-byte binary address is the type; its\nBase58Check spelling is a rendering, and its 20-byte ABI word is another.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (web3-codec-base58 (>= 0.1.0~alpha1))
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)))

(package
 (name tron-crypto)
 (synopsis "Secp256k1 recoverable signing for Tron")
 (description
  "Signs the 32-byte SHA-256 digest of a serialized raw_data and produces Tron's\n65-byte r-s-v wire signature, where v is the raw recovery id.\n\nSecret-dependent curve operations use mirage-crypto-ec's fiat-crypto P256k1\nbackend. Recovery, which runs on public data, uses mirage-crypto-blockchain's\nreference implementation -- which is documented NOT CONSTANT TIME and must\nnever be handed a secret key. This split follows ocaml-evm's evm-crypto.\n\nNo RNG: nonces are RFC 6979 deterministic.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (tron-types (= :version))
  (digestif (>= 1.2.0))
  (mirage-crypto-ec (>= 2.1.0))
  mirage-crypto-blockchain
  (zarith (>= 1.12))
  (alcotest :with-test)))

(package
 (name tron-transaction)
 (synopsis "Tron transaction construction, signing and intent")
 (description
  "Builds raw_data locally, hashes it to a txID, signs it and renders the\nbroadcast form. The node is never asked to build a transaction this library\nwill sign.\n\nThe contract set is a closed OCaml variant over google.protobuf.Any; anything\nunrecognised decodes as opaque and can never satisfy a policy. The intent\nlayer derives a reviewable meaning from the serialized bytes -- never from the\nbuilder's inputs -- and reports permission id, fee limit and expiration as\nfirst-class fields.\n\nTVM contract calls reuse the Ethereum Contract ABI from evm-abi.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (tron-types (= :version))
  (tron-crypto (= :version))
  (tron-proto (= :version))
  (evm-abi (>= 0.1.0))
  (digestif (>= 1.2.0))
  (zarith (>= 1.12))
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)))

(package
 (name tron-rpc)
 (synopsis "Typed transport-independent java-tron HTTP client")
 (description
  "The /wallet/* method catalogue, its JSON codecs, and the submission and\nconfirmation state machines -- all pure. The transport is a module type.\n\njava-tron's HTTP JSON is not canonical protobuf JSON: bytes fields are hex,\nnot base64, and the visible flag changes address rendering. The codecs here\nare hand-written against a pinned node release for exactly that reason.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (tron-types (= :version))
  (tron-transaction (= :version))
  (yojson (>= 2.0.0))
  (alcotest :with-test)))

(package
 (name tron-rpc-flow)
 (synopsis "Java-tron HTTP over any Mirage_flow.S, including Solo5 vsock")
 (description
  "The HTTP/1.1 framing lives here as a pure parser and the client is a functor\nover Mirage_flow.S; this package owns the socket. Functorising over a flow\nrather than over an HTTP client is not a preference: the confidential Solo5\ntargets forbid NET_BASIC outright, and sptmac has no networking at all, so\nvsock is the only transport available there. TLS composes as Tls_mirage.Make\nover the same signature.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (tron-rpc (= :version))
  (lwt (>= 5.6.0))
  (cstruct (>= 6.0.0))
  (mirage-flow (>= 4.0.0))
  fmt
  (alcotest :with-test)))

(package
 (name tron-rpc-grpc)
 (synopsis "Java-tron gRPC over any Mirage_flow.S, including Solo5 vsock")
 (description
  "The Wallet service over gRPC, decoding into the same typed values the HTTP\nclient produces, so that the two wire paths can be compared rather than merely\ncoexisting.\n\nFunctorised over the same flow signature as tron-rpc-flow. Not h2-mirage: that\npackage would do the functorising, but its closure is 48 packages --\nconduit-mirage, tcpip, tls, x509, dns-client, vchan, xenstore -- because it\nassumes a full network stack, and the confidential Solo5 targets have a vsock\ninstead. What h2 needs from a transport is Gluten_lwt.IO, which is four\nfunctions, so this implements those over a flow directly.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (tron-types (= :version))
  (tron-transaction (= :version))
  (tron-proto (= :version))
  (tron-rpc (= :version))
  (web3-codec-protobuf (>= 0.1.0~alpha1))
  grpc
  grpc-lwt
  (h2 (>= 0.13.0))
  (h2-lwt (>= 0.13.0))
  gluten-lwt
  faraday
  bigstringaf
  (lwt (>= 5.6.0))
  (cstruct (>= 6.0.0))
  (mirage-flow (>= 4.0.0))
  fmt
  (alcotest :with-test)))

(package
 (name tron-rpc-unix)
 (synopsis "Unix transport for the java-tron HTTP client")
 (description
  "Cardano's arrangement: this is Tron_rpc_flow.Make applied to a Unix file\ndescriptor and nothing else, so the Unix path and the unikernel path are the\nsame implementation with a different flow underneath.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (tron-rpc (= :version))
  (tron-rpc-flow (= :version))
  (tron-transaction (= :version))
  (tron-crypto (= :version))
  (lwt (>= 5.6.0))
  (mirage-flow-unix (>= 4.0.0))
  ; examples/nile_transfer.exe, the guarded live-network executable, ships in
  ; this package: it is the only thing here that signs with a real key and
  ; touches a network, and it needs a Unix transport to do either.
  (uri (>= 4.2.0))
  (alcotest :with-test)))

(package
 (name tron)
 (synopsis "Pure OCaml Tron SDK for clients and signers")
 (description
  "The offline surface: types, crypto, generated wire bindings, transaction\nconstruction and the typed RPC protocol. Transports are deliberately absent --\ntron-rpc-flow and tron-rpc-unix are separate packages so that a consumer\nlinking this one takes on no Lwt, no Unix and no socket.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.6))
  (tron-types (= :version))
  (tron-crypto (= :version))
  (tron-proto (= :version))
  (tron-transaction (= :version))
  (tron-rpc (= :version))
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)
  ; fuzz/ builds against this. A real campaign needs an AFL-instrumented
  ; switch; see docs/fuzzing.md.
  (crowbar :with-test)))
