// Regenerates conformance/fixtures/tronweb-<version>.json.
//
// Everything here runs offline. TronWeb's transaction builders normally talk to
// a node; these do not -- the transaction JSON is written out by hand in the
// shape java-tron's HTTP API uses, and only TronWeb's pure helpers are called
// on it:
//
//   utils.transaction.txJsonToPb      JSON -> protobuf message
//   utils.transaction.txPbToRawDataHex   canonical raw_data serialization
//   utils.transaction.txPbToTxID         SHA-256 over those bytes
//   utils.crypto.signTransaction         secp256k1 over the txID
//
// That is exactly the boundary ocaml-tron implements, so a mismatch is a real
// disagreement about the wire format rather than about who called the node.
//
// The keys below are the smallest secp256k1 scalars, chosen so the fixture is
// obviously not a live account. They control nothing.

import { utils as u, TronWeb } from 'tronweb';
import { writeFileSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
// Read the version out of the installed tree rather than importing it: tronweb
// does not export ./package.json, and the lockfile is the pin anyway.
const version = JSON.parse(
  readFileSync(join(here, 'node_modules', 'tronweb', 'package.json'), 'utf8')
).version;
const out = join(here, '..', 'fixtures', `tronweb-${version}.json`);

const hex = (bytes) => u.code.byteArray2hexStr(bytes).toLowerCase();
const toBytes = (h) => u.code.hexStr2byteArray(h.replace(/^0x/, ''));

const keys = [
  '0000000000000000000000000000000000000000000000000000000000000001',
  '0000000000000000000000000000000000000000000000000000000000000002',
  '0000000000000000000000000000000000000000000000000000000000000003',
];

const account = (pk) => ({
  private_key: pk,
  public_key: hex(u.crypto.getPubKeyFromPriKey(toBytes(pk))),
  address_hex: hex(u.crypto.getAddressFromPriKey(toBytes(pk))),
  address_base58: u.crypto.pkToAddress(pk),
});

const accounts = keys.map(account);
const [alice, bob, carol] = accounts;

// A reference block whose number and id are consistent: the id's leading eight
// bytes are the number, big-endian, which is what Block_ref.of_block checks.
const refBlockNumber = 0x0000000000123456n;
const refBlockIdTail = 'aabbccddeeff11223344556677889900112233445566778899aabbcc';
const refBlockId =
  refBlockNumber.toString(16).padStart(16, '0') + refBlockIdTail;
const refBlockBytes = refBlockId.slice(12, 16); // [6,8) of the number
const refBlockHash = refBlockId.slice(16, 32); // [8,16) of the id

const expiration = 1755000000000; // fixed: nothing here may read a clock
const timestamp = 1754999940000;

const base = (contract, extra = {}) => ({
  visible: false,
  raw_data: {
    contract: [contract],
    ref_block_bytes: refBlockBytes,
    ref_block_hash: refBlockHash,
    expiration,
    timestamp,
    ...extra,
  },
});

// The USDT mainnet contract, used purely as a well-known 21-byte constant.
const trc20Contract = '41a614f803b6fd780986a42c78ec9c7f77e6ded13c';

// buildFunctionSelector takes a fragment and returns the canonical signature
// string, not the 4-byte selector; the selector is Keccak-256 over that string.
// Both steps go through TronWeb so the fixture stays oracle-produced.
const trc20Fragment = {
  name: 'transfer',
  type: 'function',
  inputs: [{ type: 'address' }, { type: 'uint256' }],
};
const selector = u.abi.buildFunctionSelector(trc20Fragment);
const trc20Amount = '50000000000';
const trc20SelectorHex = u.crypto.sha3(selector, false).slice(0, 8);
const trc20Args = u.abi
  .encodeParams(['address', 'uint256'], ['0x' + bob.address_hex.slice(2), trc20Amount])
  .replace(/^0x/, '');
const trc20Data = trc20SelectorHex + trc20Args;

const cases = [
  {
    name: 'trx_transfer',
    note: 'TransferContract: 1 TRX from alice to bob.',
    tx: base({
      type: 'TransferContract',
      parameter: {
        type_url: 'type.googleapis.com/protocol.TransferContract',
        value: {
          owner_address: alice.address_hex,
          to_address: bob.address_hex,
          amount: 1000000,
        },
      },
    }),
    signers: [alice.private_key],
  },
  {
    name: 'trc20_transfer',
    note:
      'TriggerSmartContract carrying transfer(address,uint256). The address ' +
      'argument is the 20-byte form left-padded to 32; the 0x41 prefix is not ' +
      'in the word.',
    tx: base(
      {
        type: 'TriggerSmartContract',
        parameter: {
          type_url: 'type.googleapis.com/protocol.TriggerSmartContract',
          value: {
            owner_address: alice.address_hex,
            contract_address: trc20Contract,
            data: trc20Data,
          },
        },
      },
      { fee_limit: 150000000 }
    ),
    signers: [alice.private_key],
    abi: {
      signature: selector,
      selector_hex: trc20SelectorHex,
      args_hex: trc20Args,
      data: trc20Data,
      to: bob.address_hex,
      amount: trc20Amount,
    },
  },
  {
    name: 'trx_transfer_permission_2',
    note:
      'The same transfer signed under active permission 2 rather than owner ' +
      'permission 0. Permission_id is a field of the contract, so it changes ' +
      'the signed bytes.',
    tx: base({
      type: 'TransferContract',
      Permission_id: 2,
      parameter: {
        type_url: 'type.googleapis.com/protocol.TransferContract',
        value: {
          owner_address: alice.address_hex,
          to_address: bob.address_hex,
          amount: 1000000,
        },
      },
    }),
    signers: [alice.private_key],
  },
  {
    name: 'trx_transfer_multisig',
    note:
      'Two signatures on one transaction, accumulated in order. The node sums ' +
      'their weights against the permission threshold.',
    tx: base({
      type: 'TransferContract',
      Permission_id: 2,
      parameter: {
        type_url: 'type.googleapis.com/protocol.TransferContract',
        value: {
          owner_address: alice.address_hex,
          to_address: carol.address_hex,
          amount: 2500000,
        },
      },
    }),
    signers: [alice.private_key, bob.private_key],
  },
  {
    name: 'trx_transfer_with_memo',
    note: 'raw_data.data carries an arbitrary memo and is covered by the txID.',
    tx: base(
      {
        type: 'TransferContract',
        parameter: {
          type_url: 'type.googleapis.com/protocol.TransferContract',
          value: {
            owner_address: alice.address_hex,
            to_address: bob.address_hex,
            amount: 1,
          },
        },
      },
      { data: Buffer.from('reuna', 'utf8').toString('hex') }
    ),
    signers: [alice.private_key],
  },
];

const results = cases.map(({ name, note, tx, signers, abi }) => {
  const pb = u.transaction.txJsonToPb(tx);
  const raw_data_hex = u.transaction.txPbToRawDataHex(pb).toLowerCase();
  const txID = u.transaction.txPbToTxID(pb).replace(/^0x/, '').toLowerCase();

  let signed = { ...tx, txID, raw_data_hex };
  for (const pk of signers) signed = u.crypto.signTransaction(pk, signed);

  return {
    name,
    note,
    ...(abi ? { abi } : {}),
    tx_json: tx,
    raw_data_hex,
    txID,
    signatures: signed.signature,
  };
});

const fixture = {
  generator: 'tronweb',
  version,
  note:
    'Generated offline by conformance/tronweb/generate.mjs. Every value is ' +
    'TronWeb output, never ocaml-tron output. Regenerated and diffed in CI.',
  reference_block: {
    number: Number(refBlockNumber),
    id: refBlockId,
    ref_block_bytes: refBlockBytes,
    ref_block_hash: refBlockHash,
  },
  accounts,
  transactions: results,
};

mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(fixture, null, 2) + '\n');
console.log(`wrote ${out}`);
