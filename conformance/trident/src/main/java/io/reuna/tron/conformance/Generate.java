package io.reuna.tron.conformance;

import com.google.protobuf.ByteString;
import java.io.IOException;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import org.tron.trident.abi.FunctionEncoder;
import org.tron.trident.abi.datatypes.Address;
import org.tron.trident.abi.datatypes.Function;
import org.tron.trident.abi.datatypes.Type;
import org.tron.trident.abi.datatypes.generated.Uint256;
import org.tron.trident.core.key.KeyPair;
import org.tron.trident.proto.Chain;
import org.tron.trident.proto.Contract;
import org.tron.trident.utils.Numeric;

/**
 * Regenerates the trident fixture, entirely offline.
 *
 * <p>The same five transaction shapes TronWeb generates, built from the same
 * inputs, so the two fixtures are directly comparable. Where they differ, the
 * difference is the finding.
 *
 * <p>The keys are the smallest secp256k1 scalars. They control nothing.
 */
public final class Generate {

  private static final String[] KEYS = {
    "0000000000000000000000000000000000000000000000000000000000000001",
    "0000000000000000000000000000000000000000000000000000000000000002",
    "0000000000000000000000000000000000000000000000000000000000000003",
  };

  // A reference block whose number and id are consistent: the id's leading
  // eight bytes are the number, big-endian.
  private static final long REF_BLOCK_NUMBER = 0x0000000000123456L;
  private static final String REF_BLOCK_ID =
      "0000000000123456aabbccddeeff11223344556677889900112233445566778899aabbcc";

  // Fixed, because nothing here may read a clock.
  private static final long EXPIRATION = 1755000000000L;
  private static final long TIMESTAMP = 1754999940000L;

  private static final String TRC20_CONTRACT = "41a614f803b6fd780986a42c78ec9c7f77e6ded13c";

  public static void main(String[] args) throws Exception {
    Path outDir = Paths.get(args.length > 0 ? args[0] : "../fixtures");
    Files.createDirectories(outDir);

    List<Account> accounts = new ArrayList<>();
    for (String k : KEYS) {
      accounts.add(Account.of(k));
    }
    Account alice = accounts.get(0);
    Account bob = accounts.get(1);
    Account carol = accounts.get(2);

    byte[] refBlockBytes = Numeric.hexStringToByteArray(REF_BLOCK_ID.substring(12, 16));
    byte[] refBlockHash = Numeric.hexStringToByteArray(REF_BLOCK_ID.substring(16, 32));

    List<Case> cases = new ArrayList<>();

    cases.add(
        new Case(
            "trx_transfer",
            "TransferContract: 1 TRX from alice to bob.",
            transfer(alice, bob, 1_000_000L),
            "type.googleapis.com/protocol.TransferContract",
            Chain.Transaction.Contract.ContractType.TransferContract,
            0,
            0L,
            "",
            List.of(alice)));

    String trc20Data = trc20Transfer(bob, new BigInteger("50000000000"));
    cases.add(
        new Case(
            "trc20_transfer",
            "TriggerSmartContract carrying transfer(address,uint256).",
            trigger(alice, TRC20_CONTRACT, trc20Data),
            "type.googleapis.com/protocol.TriggerSmartContract",
            Chain.Transaction.Contract.ContractType.TriggerSmartContract,
            0,
            150_000_000L,
            "",
            List.of(alice)));

    cases.add(
        new Case(
            "trx_transfer_permission_2",
            "The same transfer under active permission 2. Permission_id is a field of the"
                + " contract, so it changes the signed bytes.",
            transfer(alice, bob, 1_000_000L),
            "type.googleapis.com/protocol.TransferContract",
            Chain.Transaction.Contract.ContractType.TransferContract,
            2,
            0L,
            "",
            List.of(alice)));

    cases.add(
        new Case(
            "trx_transfer_multisig",
            "Two signatures on one transaction, accumulated in order.",
            transfer(alice, carol, 2_500_000L),
            "type.googleapis.com/protocol.TransferContract",
            Chain.Transaction.Contract.ContractType.TransferContract,
            2,
            0L,
            "",
            List.of(alice, bob)));

    cases.add(
        new Case(
            "trx_transfer_with_memo",
            "raw_data.data carries a memo and is covered by the txID.",
            transfer(alice, bob, 1L),
            "type.googleapis.com/protocol.TransferContract",
            Chain.Transaction.Contract.ContractType.TransferContract,
            0,
            0L,
            "reuna",
            List.of(alice)));

    StringBuilder out = new StringBuilder();
    out.append("{\n");
    out.append("  \"generator\": \"trident\",\n");
    out.append("  \"version\": \"1.0.0\",\n");
    out.append(
        "  \"note\": \"Generated offline by conformance/trident. Every value is trident output,"
            + " never ocaml-tron output. Regenerated and diffed in CI.\",\n");
    out.append("  \"reference_block\": {\n");
    out.append("    \"number\": ").append(REF_BLOCK_NUMBER).append(",\n");
    out.append("    \"id\": \"").append(REF_BLOCK_ID).append("\",\n");
    out.append("    \"ref_block_bytes\": \"").append(Numeric.toHexStringNoPrefix(refBlockBytes)).append("\",\n");
    out.append("    \"ref_block_hash\": \"").append(Numeric.toHexStringNoPrefix(refBlockHash)).append("\"\n");
    out.append("  },\n");

    out.append("  \"accounts\": [\n");
    for (int i = 0; i < accounts.size(); i++) {
      Account a = accounts.get(i);
      out.append("    {\n");
      out.append("      \"private_key\": \"").append(a.privateKey).append("\",\n");
      out.append("      \"public_key\": \"").append(a.publicKey).append("\",\n");
      out.append("      \"address_hex\": \"").append(a.addressHex).append("\",\n");
      out.append("      \"address_base58\": \"").append(a.addressBase58).append("\"\n");
      out.append("    }").append(i + 1 < accounts.size() ? "," : "").append("\n");
    }
    out.append("  ],\n");

    out.append("  \"transactions\": [\n");
    for (int i = 0; i < cases.size(); i++) {
      Case c = cases.get(i);
      Chain.Transaction.raw raw =
          Chain.Transaction.raw.newBuilder()
              .setRefBlockBytes(ByteString.copyFrom(refBlockBytes))
              .setRefBlockHash(ByteString.copyFrom(refBlockHash))
              .setExpiration(EXPIRATION)
              .setTimestamp(TIMESTAMP)
              .setData(ByteString.copyFromUtf8(c.memo))
              .setFeeLimit(c.feeLimit)
              .addContract(
                  Chain.Transaction.Contract.newBuilder()
                      .setType(c.type)
                      .setPermissionId(c.permissionId)
                      .setParameter(
                          com.google.protobuf.Any.newBuilder()
                              .setTypeUrl(c.typeUrl)
                              .setValue(c.payload)
                              .build())
                      .build())
              .build();

      byte[] rawBytes = raw.toByteArray();
      byte[] txId = sha256(rawBytes);

      List<String> signatures = new ArrayList<>();
      for (Account signer : c.signers) {
        signatures.add(sign(signer, txId));
      }

      out.append("    {\n");
      out.append("      \"name\": \"").append(c.name).append("\",\n");
      out.append("      \"note\": \"").append(c.note.replace("\"", "\\\"")).append("\",\n");
      out.append("      \"raw_data_hex\": \"").append(Numeric.toHexStringNoPrefix(rawBytes)).append("\",\n");
      out.append("      \"txID\": \"").append(Numeric.toHexStringNoPrefix(txId)).append("\",\n");
      out.append("      \"signatures\": [");
      for (int j = 0; j < signatures.size(); j++) {
        out.append("\"").append(signatures.get(j)).append("\"");
        if (j + 1 < signatures.size()) out.append(", ");
      }
      out.append("]\n");
      out.append("    }").append(i + 1 < cases.size() ? "," : "").append("\n");
    }
    out.append("  ]\n");
    out.append("}\n");

    Path target = outDir.resolve("trident-1.0.0.json");
    Files.writeString(target, out.toString());
    System.out.println("wrote " + target.toAbsolutePath());
  }

  private static ByteString transfer(Account from, Account to, long amount) {
    return Contract.TransferContract.newBuilder()
        .setOwnerAddress(ByteString.copyFrom(Numeric.hexStringToByteArray(from.addressHex)))
        .setToAddress(ByteString.copyFrom(Numeric.hexStringToByteArray(to.addressHex)))
        .setAmount(amount)
        .build()
        .toByteString();
  }

  private static ByteString trigger(Account owner, String contract, String dataHex) {
    return Contract.TriggerSmartContract.newBuilder()
        .setOwnerAddress(ByteString.copyFrom(Numeric.hexStringToByteArray(owner.addressHex)))
        .setContractAddress(ByteString.copyFrom(Numeric.hexStringToByteArray(contract)))
        .setData(ByteString.copyFrom(Numeric.hexStringToByteArray(dataHex)))
        .build()
        .toByteString();
  }

  /**
   * Built through trident's own ABI encoder rather than by hand, so this is
   * genuinely a second implementation rather than a restatement.
   *
   * <p>trident's Address takes the 21-byte hex form and drops the 0x41 prefix
   * when it encodes the word. That is the one Tron-specific rule in the whole
   * ABI, and the one most worth a second opinion.
   */
  private static String trc20Transfer(Account to, BigInteger amount) {
    Function fn =
        new Function(
            "transfer",
            List.<Type>of(new Address(to.addressHex), new Uint256(amount)),
            List.of());
    return Numeric.cleanHexPrefix(FunctionEncoder.encode(fn));
  }

  private static byte[] sha256(byte[] b) throws Exception {
    return java.security.MessageDigest.getInstance("SHA-256").digest(b);
  }

  /**
   * 65 bytes, r then s then v, via trident's own transaction signer.
   *
   * <p>trident writes v as the raw recovery id, where TronWeb writes recovery
   * id + 27. java-tron accepts both and both appear on chain; that divergence
   * is the reason for having two oracles rather than one.
   */
  private static String sign(Account signer, byte[] digest) {
    KeyPair kp = new KeyPair(signer.privateKey);
    return Numeric.toHexStringNoPrefix(KeyPair.signTransaction(digest, kp));
  }

  private static final class Account {
    final String privateKey;
    final String publicKey;
    final String addressHex;
    final String addressBase58;

    private Account(String privateKey, String publicKey, String addressHex, String addressBase58) {
      this.privateKey = privateKey;
      this.publicKey = publicKey;
      this.addressHex = addressHex;
      this.addressBase58 = addressBase58;
    }

    static Account of(String privateKey) {
      KeyPair kp = new KeyPair(privateKey);
      String hex = kp.toHexAddress();
      return new Account(privateKey, kp.toPublicKey(), hex, kp.toBase58CheckAddress());
    }
  }

  private static final class Case {
    final String name;
    final String note;
    final ByteString payload;
    final String typeUrl;
    final Chain.Transaction.Contract.ContractType type;
    final int permissionId;
    final long feeLimit;
    final String memo;
    final List<Account> signers;

    Case(String name, String note, ByteString payload, String typeUrl,
        Chain.Transaction.Contract.ContractType type, int permissionId, long feeLimit,
        String memo, List<Account> signers) {
      this.name = name;
      this.note = note;
      this.payload = payload;
      this.typeUrl = typeUrl;
      this.type = type;
      this.permissionId = permissionId;
      this.feeLimit = feeLimit;
      this.memo = memo;
      this.signers = signers;
    }
  }
}
