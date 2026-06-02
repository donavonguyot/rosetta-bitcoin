import { describe, expect, it } from "vitest";

import { hash160 } from "../src/consensus/hash.js";
import {
  Gx,
  Gy,
  N,
  scalarMult,
  signBip340Schnorr,
  signDer,
  taprootTweakPubkeyXonly,
} from "../src/consensus/secp256k1.js";
import {
  isP2pk,
  isP2pkh,
  isP2tr,
  verifyScript,
  witnessProgramVersion,
} from "../src/consensus/script/interpreter.js";
import {
  OP_1,
  OP_16,
  OP_CHECKLOCKTIMEVERIFY,
  OP_CHECKSIG,
  WITNESS_V1_TAPROOT_XONLY_PK_LEN,
} from "../src/consensus/script/opcodes.js";
import {
  legacySighash,
  tapleafHash,
  taprootSignatureHash,
  taprootTweakPubkeyHash,
} from "../src/consensus/script/sighash.js";
import { verifyTransactionInput } from "../src/consensus/script/verify.js";
import { transactionDeserialize, type Transaction } from "../src/messages/transaction.js";
import {
  cltvRedeemScript,
  makeSignedP2pkSpend,
  makeSignedP2pkhSpend,
  makeSignedP2shCltvSpend,
  makeSignedP2shCsvSpend,
  makeSignedP2shMultisigSpend,
  makeSignedP2shP2pkhSpend,
  makeSignedP2wpkhSpend,
  makeSignedP2wshCltvSpend,
  makeSignedP2wshCsvSpend,
  makeSignedP2wshMultisigSpend,
  makeSignedP2wshP2pkhSpend,
  multisigRedeemScript,
  p2pkScriptPubKey,
  p2pkhScriptPubKey,
  p2shScriptPubKey,
  pushData,
  testPubkeySec1,
} from "./helpers/scriptHelpers.js";

function normalizedXonlyPubkey(secret: bigint): [bigint, Buffer] {
  const d0 = secret % N || 1n;
  let point = scalarMult(d0, [Gx, Gy]);
  expect(point).not.toBeNull();
  let d = d0;
  if (point![1] % 2n !== 0n) {
    d = N - d;
  }
  point = scalarMult(d, [Gx, Gy]);
  expect(point).not.toBeNull();
  expect(point![1] % 2n).toBe(0n);
  return [d, Buffer.from(point![0].toString(16).padStart(64, "0"), "hex")];
}

describe("taproot script verification", () => {
  it("detects witness program versions", () => {
    expect(witnessProgramVersion(Buffer.from("0014" + "ab".repeat(20), "hex"))).toBe(0);
    expect(
      witnessProgramVersion(Buffer.from("5120" + "cd".repeat(32), "hex")),
    ).toBe(1);
    expect(
      witnessProgramVersion(Buffer.from("5220" + "ee".repeat(32), "hex")),
    ).toBe(2);
  });

  it("detects P2TR scriptPubKey", () => {
    const spk = Buffer.concat([
      Buffer.from([OP_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]),
      Buffer.alloc(32, 0x11),
    ]);
    expect(isP2tr(spk)).toBe(true);
  });

  it("accepts synthetic script-path OP_1 spend", () => {
    const internalPriv = 42n;
    let point = scalarMult(internalPriv, [Gx, Gy]);
    expect(point).not.toBeNull();
    let xCoord = point![0];
    if (point![1] % 2n !== 0n) {
      point = scalarMult(N - internalPriv, [Gx, Gy]);
      expect(point).not.toBeNull();
      xCoord = point![0];
    }
    const internalX = Buffer.from(xCoord.toString(16).padStart(64, "0"), "hex");
    const tapscript = Buffer.from([0x51]);
    const merkle = tapleafHash(0xc0, tapscript);
    const [parityQ, outputXonly] = taprootTweakPubkeyXonly(internalX, merkle);
    const scriptPubKey = Buffer.concat([
      Buffer.from([OP_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]),
      outputXonly,
    ]);
    const controlBlock = Buffer.concat([
      Buffer.from([0xc0 | (parityQ & 1)]),
      internalX,
    ]);

    const amt = 123_456_789;
    const spend: Transaction = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0x33), index: 0 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xfffffffd,
        },
      ],
      outputs: [{ value: amt - 10_000, scriptPubKey: Buffer.from([OP_1]) }],
      lockTime: 0,
      witness: [[tapscript, controlBlock]],
    };
    const spentPrevouts = [[amt, scriptPubKey] as const];
    verifyTransactionInput(spend, 0, {
      scriptPubKey,
      amount: amt,
      spentPrevouts,
    });
  });

  it("accepts real testnet4 block 6975 key-path spend", () => {
    const txHex =
      "020000000001016760fe836cb885189111d4e3cdb8c66446cdc85c1f4b2b43fdd8eea2fe0b0b96" +
      "0100000000fdffffff02899b92f80e000000225120640d6c0f4087e81de6e82df09435fb9d4628999d38c124eaaecc98f165c889b0" +
      "a086010000000000225120b6ce5933c68826bb261fe730f4f8a78b8a9f8898e1ce794d664abf0a9494ac59" +
      "0140ecba16793ec416745da044701928f046da5761eacb384892cbde3c3706187251d3ca3c78adfde0eb560b0" +
      "de89d4124023f0536be3d5e900960816780ae3d97f53d1b0000";
    const payload = Buffer.from(txHex, "hex");
    const [tx, consumed] = transactionDeserialize(payload, 0);
    expect(consumed).toBe(payload.length);

    const prevSpk = Buffer.from(
      "512096519126915cde17e68250819b504b3fda380b8d98e3540a3f2baa3b011eb29c",
      "hex",
    );
    const spentPrevouts = [[64_300_000_000, prevSpk] as const];
    verifyTransactionInput(tx, 0, {
      scriptPubKey: prevSpk,
      amount: 64_300_000_000,
      spentPrevouts,
    });
  });

  it("accepts script-path tapscript CHECKSIG spend", () => {
    const [secret, pkXonly] = normalizedXonlyPubkey(1_234_567n);

    const leafVersion = 0xc0;
    const tapscript = Buffer.concat([
      Buffer.from([pkXonly.length]),
      pkXonly,
      Buffer.from([OP_CHECKSIG]),
    ]);
    const leafDigest = tapleafHash(leafVersion, tapscript);

    const [parity, outputX] = taprootTweakPubkeyXonly(pkXonly, leafDigest);
    const controlBlock = Buffer.concat([Buffer.from([leafVersion | parity]), pkXonly]);
    const scriptPubKey = Buffer.concat([
      Buffer.from([OP_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]),
      outputX,
    ]);

    const unsigned: Transaction = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0xee), index: 5 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xfffffffd,
        },
      ],
      outputs: [{ value: 99_998_999, scriptPubKey: Buffer.from([OP_1]) }],
      lockTime: 0,
      witness: [],
    };

    const amt = 100_000_000;
    const spentPrevouts = [[amt, scriptPubKey] as const];
    const digest = taprootSignatureHash(unsigned, 0, spentPrevouts, {
      hashType: 0,
      annex: null,
      extFlag: 1,
      tapleafHash: leafDigest,
      tapscriptCodeseparatorPos: 0xffffffff,
    });

    const signed: Transaction = {
      ...unsigned,
      witness: [[signBip340Schnorr(secret, digest), tapscript, controlBlock]],
    };

    verifyTransactionInput(signed, 0, {
      scriptPubKey,
      amount: amt,
      spentPrevouts,
    });
  });

  it("roundtrips key-path sign and verify", () => {
    const [secret, pkXonly] = normalizedXonlyPubkey(99n);
    const [parity, outputX] = taprootTweakPubkeyXonly(pkXonly, Buffer.alloc(0));
    expect(parity).toBeGreaterThanOrEqual(0);
    const scriptPubKey = Buffer.concat([
      Buffer.from([OP_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]),
      outputX,
    ]);

    const tx: Transaction = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0x01), index: 0 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffffffff,
        },
      ],
      outputs: [{ value: 49_000, scriptPubKey: Buffer.from([OP_1]) }],
      lockTime: 0,
      witness: [],
    };
    const amt = 50_000;
    const spentPrevouts = [[amt, scriptPubKey] as const];
    const digest = taprootSignatureHash(tx, 0, spentPrevouts, { hashType: 0 });
    const tweak = BigInt(`0x${taprootTweakPubkeyHash(pkXonly, Buffer.alloc(0)).toString("hex")}`);
    const tweakedSecret = (secret + tweak) % N;
    const sig = signBip340Schnorr(tweakedSecret, digest);

    expect(
      verifyScript(Buffer.alloc(0), scriptPubKey, {
        tx: { ...tx, witness: [[sig]] },
        inputIndex: 0,
        amount: amt,
        witness: [sig],
        spentPrevouts,
      }),
    ).toBe(true);
  });

  it("accepts non-0xc0 leaf without tapscript execution", () => {
    const leafVersion = 0xfe;
    const [, pkXonly] = normalizedXonlyPubkey(333n);
    const tapscript = Buffer.concat([Buffer.from([0xff]), Buffer.alloc(200, 0x00)]);
    const leafDigest = tapleafHash(leafVersion, tapscript);
    const [parity, outputX] = taprootTweakPubkeyXonly(pkXonly, leafDigest);
    const controlBlock = Buffer.concat([Buffer.from([leafVersion | parity]), pkXonly]);
    const scriptPubKey = Buffer.concat([
      Buffer.from([OP_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]),
      outputX,
    ]);

    const amt = 8_888_888;
    const tx: Transaction = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0xfe), index: 12 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffffffff,
        },
      ],
      outputs: [{ value: 1000, scriptPubKey: Buffer.from([OP_1]) }],
      lockTime: 0,
      witness: [[tapscript, controlBlock]],
    };
    verifyTransactionInput(tx, 0, {
      scriptPubKey,
      amount: amt,
      spentPrevouts: [[amt, scriptPubKey] as const],
    });
  });

  it("rejects script-path merkle mismatch", () => {
    const [secret, pkXonly] = normalizedXonlyPubkey(444n);
    const leafVersion = 0xc0;
    const tapscript = Buffer.concat([
      Buffer.from([pkXonly.length]),
      pkXonly,
      Buffer.from([OP_CHECKSIG]),
    ]);
    const [, correctOut] = taprootTweakPubkeyXonly(
      pkXonly,
      tapleafHash(leafVersion, tapscript),
    );
    const wrongOut = Buffer.from(correctOut);
    wrongOut[0]! ^= 0x01;
    const scriptPubKey = Buffer.concat([
      Buffer.from([OP_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]),
      wrongOut,
    ]);

    const [parity] = taprootTweakPubkeyXonly(pkXonly, tapleafHash(leafVersion, tapscript));
    const controlBlock = Buffer.concat([Buffer.from([leafVersion | parity]), pkXonly]);

    const unsigned: Transaction = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0xdd), index: 0 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffffffff,
        },
      ],
      outputs: [{ value: 1, scriptPubKey: Buffer.from([OP_1]) }],
      lockTime: 0,
      witness: [],
    };
    const amt = 1000;
    const spentPrevouts = [[amt, scriptPubKey] as const];
    const digest = taprootSignatureHash(unsigned, 0, spentPrevouts, {
      hashType: 0,
      extFlag: 1,
      tapleafHash: tapleafHash(leafVersion, tapscript),
    });
    const signed: Transaction = {
      ...unsigned,
      witness: [[signBip340Schnorr(secret, digest), tapscript, controlBlock]],
    };

    expect(() =>
      verifyTransactionInput(signed, 0, {
        scriptPubKey,
        amount: amt,
        spentPrevouts,
      }),
    ).toThrow(/script verification failed/);
  });
});

describe("legacy script verification", () => {
  const prevAmount = 5_000_000_000;
  const outputValue = 4_900_000_000;

  it("roundtrips P2SH P2PKH spend", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2shP2pkhSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("roundtrips P2WPKH spend", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2wpkhSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("roundtrips P2WSH P2PKH spend", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2wshP2pkhSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("documents 2-of-2 multisig redeem script shape", () => {
    const pkA = testPubkeySec1(1n);
    const pkB = testPubkeySec1(2n);
    const script = multisigRedeemScript(2, [pkA, pkB]);
    expect(script[0]).toBe(0x52);
    expect(script[script.length - 2]).toBe(0x52);
    expect(script[script.length - 1]).toBe(0xae);
  });

  it("roundtrips P2SH 2-of-2 multisig spend", () => {
    const pkA = testPubkeySec1(1n);
    const pkB = testPubkeySec1(2n);
    const [signed, scriptPubKey] = makeSignedP2shMultisigSpend({
      privateKeys: [1n, 2n],
      pubkeys: [pkA, pkB],
      required: 2,
      prevTxid: Buffer.alloc(32, 0x03),
      prevAmount,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("roundtrips P2WSH 2-of-2 multisig spend", () => {
    const pkA = testPubkeySec1(1n);
    const pkB = testPubkeySec1(2n);
    const [signed, scriptPubKey] = makeSignedP2wshMultisigSpend({
      privateKeys: [1n, 2n],
      pubkeys: [pkA, pkB],
      required: 2,
      prevTxid: Buffer.alloc(32, 0x04),
      prevAmount,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("documents CLTV redeem script shape", () => {
    const pk = testPubkeySec1(1n);
    const script = cltvRedeemScript(100, pk);
    expect(script.subarray(0, 2).equals(Buffer.from([1, 100]))).toBe(true);
    expect(script.includes(OP_CHECKLOCKTIMEVERIFY)).toBe(true);
    expect(script[script.length - 1]).toBe(0xac);
  });

  it("roundtrips P2SH CLTV spend", () => {
    const pk = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2shCltvSpend({
      privateKey: 1n,
      pubkey: pk,
      locktimeValue: 100,
      txLockTime: 100,
      inputSequence: 0xffff_fffe,
      prevTxid: Buffer.alloc(32, 0x07),
      prevAmount,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("roundtrips P2WSH CLTV spend", () => {
    const pk = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2wshCltvSpend({
      privateKey: 1n,
      pubkey: pk,
      locktimeValue: 100,
      txLockTime: 100,
      inputSequence: 0xffff_fffe,
      prevTxid: Buffer.alloc(32, 0x08),
      prevAmount,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("roundtrips P2SH CSV spend", () => {
    const pk = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2shCsvSpend({
      privateKey: 1n,
      pubkey: pk,
      csvOperand: 10,
      inputSequence: 10,
      prevTxid: Buffer.alloc(32, 0x0a),
      prevAmount,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("roundtrips P2WSH CSV spend", () => {
    const pk = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2wshCsvSpend({
      privateKey: 1n,
      pubkey: pk,
      csvOperand: 10,
      inputSequence: 10,
      prevTxid: Buffer.alloc(32, 0x0b),
      prevAmount,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("roundtrips P2PK spend", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2pkSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("detects compressed P2PK script template", () => {
    const pubkey = testPubkeySec1(1n);
    const script = p2pkScriptPubKey(pubkey);
    expect(script.length).toBe(35);
    expect(isP2pk(script)).toBe(true);
  });

  it("detects uncompressed P2PK script template", () => {
    const point = scalarMult(1n, [Gx, Gy]);
    expect(point).not.toBeNull();
    const pubkeyUncompressed = Buffer.concat([
      Buffer.from([0x04]),
      Buffer.from(point![0].toString(16).padStart(64, "0"), "hex"),
      Buffer.from(point![1].toString(16).padStart(64, "0"), "hex"),
    ]);
    const script = p2pkScriptPubKey(pubkeyUncompressed);
    expect(script.length).toBe(67);
    expect(isP2pk(script)).toBe(true);
  });

  it("roundtrips P2PKH spend", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2pkhSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount });
  });

  it("detects P2PKH script template", () => {
    const script = p2pkhScriptPubKey(
      Buffer.from("5b6462475454710f3c22f5fdf0b40704c92f25c3", "hex"),
    );
    expect(script.length).toBe(25);
    expect(isP2pkh(script)).toBe(true);
  });

  it("rejects bad signature via verifyScript", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2pkhSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    const badSig = Buffer.from(signed.inputs[0]!.scriptSig);
    badSig[5]! ^= 0xff;
    const badTx: Transaction = {
      ...signed,
      inputs: [
        {
          previousOutput: signed.inputs[0]!.previousOutput,
          scriptSig: badSig,
          sequence: signed.inputs[0]!.sequence,
        },
      ],
    };
    expect(
      verifyScript(badTx.inputs[0]!.scriptSig, scriptPubKey, {
        tx: badTx,
        inputIndex: 0,
        amount: prevAmount,
        witness: [],
      }),
    ).toBe(false);
  });

  it("rejects unsupported scriptPubKey template", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed] = makeSignedP2pkhSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    expect(() =>
      verifyTransactionInput(signed, 0, {
        scriptPubKey: Buffer.from([OP_1]),
        amount: prevAmount,
      }),
    ).toThrow(/unsupported scriptPubKey/);
  });

  it("rejects P2SH scriptPubKey hash mismatch", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed] = makeSignedP2shP2pkhSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    const wrongOuter = p2shScriptPubKey(hash160(Buffer.alloc(32, 0xfe)));
    expect(() =>
      verifyTransactionInput(signed, 0, { scriptPubKey: wrongOuter, amount: prevAmount }),
    ).toThrow();
  });

  it("rejects P2WSH witness program commitment mismatch", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed, goodSpk] = makeSignedP2wshP2pkhSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    const badSpk = Buffer.from(goodSpk);
    badSpk[11]! ^= 0xff;
    expect(() =>
      verifyTransactionInput(signed, 0, { scriptPubKey: badSpk, amount: prevAmount }),
    ).toThrow();
  });

  it("rejects corrupted P2PK signature", () => {
    const pubkey = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2pkSpend({
      privateKey: 1n,
      prevTxid: Buffer.alloc(32, 0x02),
      prevAmount,
      pubkey,
      outputValue,
    });
    const badSig = Buffer.from(signed.inputs[0]!.scriptSig);
    badSig[badSig.length - 2]! ^= 0xff;
    const badTx: Transaction = {
      ...signed,
      inputs: [
        {
          previousOutput: signed.inputs[0]!.previousOutput,
          scriptSig: badSig,
          sequence: signed.inputs[0]!.sequence,
        },
      ],
    };
    expect(
      verifyScript(badTx.inputs[0]!.scriptSig, scriptPubKey, {
        tx: badTx,
        inputIndex: 0,
        amount: prevAmount,
        witness: [],
      }),
    ).toBe(false);
  });

  it("rejects P2SH multisig with insufficient signatures", () => {
    const pkA = testPubkeySec1(1n);
    const pkB = testPubkeySec1(2n);
    const [signed, scriptPubKey] = makeSignedP2shMultisigSpend({
      privateKeys: [1n],
      pubkeys: [pkA, pkB],
      required: 2,
      prevTxid: Buffer.alloc(32, 0x05),
      prevAmount,
      outputValue,
    });
    expect(() =>
      verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount }),
    ).toThrow(/script verification failed/);
  });

  it("rejects P2SH multisig when signature order does not match pubkeys", () => {
    const pkA = testPubkeySec1(1n);
    const pkB = testPubkeySec1(2n);
    const redeem = multisigRedeemScript(2, [pkA, pkB]);
    const scriptPubKey = p2shScriptPubKey(hash160(redeem));
    const unsigned: Transaction = {
      version: 1,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0x06), index: 0 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffff_ffff,
        },
      ],
      outputs: [{ value: outputValue, scriptPubKey: Buffer.from([OP_1]) }],
      lockTime: 0,
      witness: [],
    };
    const sighash = legacySighash(unsigned, 0, redeem, 1);
    const sigA = Buffer.concat([signDer(1n, sighash), Buffer.from([1])]);
    const sigB = Buffer.concat([signDer(2n, sighash), Buffer.from([1])]);
    const badScriptSig = Buffer.concat([
      Buffer.from([0x00]),
      pushData(sigB),
      pushData(sigA),
      pushData(redeem),
    ]);
    const badTx: Transaction = {
      version: unsigned.version,
      inputs: [
        {
          previousOutput: unsigned.inputs[0]!.previousOutput,
          scriptSig: badScriptSig,
          sequence: unsigned.inputs[0]!.sequence,
        },
      ],
      outputs: unsigned.outputs,
      lockTime: unsigned.lockTime,
      witness: [],
    };
    expect(() =>
      verifyTransactionInput(badTx, 0, { scriptPubKey, amount: prevAmount }),
    ).toThrow(/script verification failed/);
  });

  it("rejects P2SH CLTV when locktime is unsatisfied", () => {
    const pk = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2shCltvSpend({
      privateKey: 1n,
      pubkey: pk,
      locktimeValue: 200,
      txLockTime: 100,
      inputSequence: 0xffff_fffe,
      prevTxid: Buffer.alloc(32, 0x09),
      prevAmount,
      outputValue,
    });
    expect(() =>
      verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount }),
    ).toThrow(/script verification failed/);
  });

  it("rejects P2SH CSV when input sequence is insufficient", () => {
    const pk = testPubkeySec1(1n);
    const [signed, scriptPubKey] = makeSignedP2shCsvSpend({
      privateKey: 1n,
      pubkey: pk,
      csvOperand: 20,
      inputSequence: 10,
      prevTxid: Buffer.alloc(32, 0x0c),
      prevAmount,
      outputValue,
    });
    expect(() =>
      verifyTransactionInput(signed, 0, { scriptPubKey, amount: prevAmount }),
    ).toThrow(/script verification failed/);
  });

  it("rejects witness v2 program spend", () => {
    const program = Buffer.alloc(32, 0xbe);
    const scriptPubKey = Buffer.concat([Buffer.from([0x52, program.length]), program]);
    expect(witnessProgramVersion(scriptPubKey)).toBe(2);

    const spend: Transaction = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0x03), index: 0 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffff_ffff,
        },
      ],
      outputs: [{ value: outputValue, scriptPubKey: Buffer.from([OP_1]) }],
      lockTime: 0,
      witness: [[Buffer.from([0x01])]],
    };
    expect(() =>
      verifyTransactionInput(spend, 0, { scriptPubKey, amount: prevAmount }),
    ).toThrow(/unsupported witness program version 2/);
  });

  it("rejects witness v16 program spend", () => {
    const program = Buffer.alloc(40, 0xca);
    const scriptPubKey = Buffer.concat([Buffer.from([OP_16, program.length]), program]);
    expect(witnessProgramVersion(scriptPubKey)).toBe(16);

    const spend: Transaction = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0x04), index: 0 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffff_ffff,
        },
      ],
      outputs: [{ value: 1, scriptPubKey: Buffer.from([OP_1]) }],
      lockTime: 0,
      witness: [[program]],
    };
    expect(() =>
      verifyTransactionInput(spend, 0, { scriptPubKey, amount: prevAmount }),
    ).toThrow(/unsupported witness program version 16/);
  });
});
