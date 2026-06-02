package com.jbitnode.consensus.script;

import com.jbitnode.consensus.script.ScriptInterpreter.EvalContext;
import com.jbitnode.consensus.tx.Transaction;
import java.util.Arrays;
import java.util.List;

/** scriptPubKey template detection (early testnet4 spend paths). */
public final class ScriptTemplates {

  /** Max script size for consensus bare-legacy template gate (matches {@link ScriptVerify}). */
  public static final int MAX_CONSENSUS_SCRIPT_SIZE = 10_000;

  private ScriptTemplates() {}

  public static boolean isP2pkh(byte[] scriptPubKey) {
    return scriptPubKey.length == 25
        && (scriptPubKey[0] & 0xff) == OpCodes.OP_DUP
        && (scriptPubKey[1] & 0xff) == OpCodes.OP_HASH160
        && (scriptPubKey[2] & 0xff) == 0x14
        && (scriptPubKey[23] & 0xff) == OpCodes.OP_EQUALVERIFY
        && (scriptPubKey[24] & 0xff) == OpCodes.OP_CHECKSIG;
  }

  public static boolean isP2pk(byte[] scriptPubKey) {
    if (scriptPubKey.length == 35) {
      return (scriptPubKey[0] & 0xff) == 33
          && (scriptPubKey[34] & 0xff) == OpCodes.OP_CHECKSIG;
    }
    if (scriptPubKey.length == 67) {
      return (scriptPubKey[0] & 0xff) == 65
          && (scriptPubKey[66] & 0xff) == OpCodes.OP_CHECKSIG;
    }
    return false;
  }

  public static boolean isP2wpkh(byte[] scriptPubKey) {
    return scriptPubKey.length == 22
        && (scriptPubKey[0] & 0xff) == 0x00
        && (scriptPubKey[1] & 0xff) == 0x14;
  }

  public static boolean isP2sh(byte[] scriptPubKey) {
    return scriptPubKey.length == 23
        && (scriptPubKey[0] & 0xff) == OpCodes.OP_HASH160
        && (scriptPubKey[1] & 0xff) == 0x14
        && (scriptPubKey[22] & 0xff) == OpCodes.OP_EQUAL;
  }

  public static boolean isP2wsh(byte[] scriptPubKey) {
    return scriptPubKey.length == 34
        && (scriptPubKey[0] & 0xff) == 0x00
        && (scriptPubKey[1] & 0xff) == 0x20;
  }

  public static boolean isP2tr(byte[] scriptPubKey) {
    return scriptPubKey.length == 34
        && (scriptPubKey[0] & 0xff) == OpCodes.OP_1
        && (scriptPubKey[1] & 0xff) == 32;
  }

  /**
   * Bare legacy output: OP_1..OP_16 / OP_1NEGATE, optionally followed by one push (empty scriptSig
   * satisfies; terminal success uses relaxed top-of-stack rule like Core).
   */
  public static boolean isBareOpN(byte[] scriptPubKey) {
    if (scriptPubKey.length == 0) {
      return false;
    }
    int opcode = scriptPubKey[0] & 0xff;
    if (!((opcode >= OpCodes.OP_1 && opcode <= OpCodes.OP_16) || opcode == OpCodes.OP_1NEGATE)) {
      return false;
    }
    if (scriptPubKey.length == 1) {
      return true;
    }
    if (isP2tr(scriptPubKey) || isP2wpkh(scriptPubKey) || isP2wsh(scriptPubKey)) {
      return false;
    }
    int pushOpcode = scriptPubKey[1] & 0xff;
    if (pushOpcode == OpCodes.OP_0
        || (pushOpcode >= OpCodes.OP_1 && pushOpcode <= OpCodes.OP_16)
        || pushOpcode == OpCodes.OP_1NEGATE) {
      return false;
    }
    try {
      ScriptPush.PushResult push = ScriptPush.readPush(scriptPubKey, 1);
      return push.nextOffset() == scriptPubKey.length;
    } catch (ScriptError error) {
      return false;
    }
  }

  private static final int MAX_PUBKEYS_PER_MULTISIG = 20;

  static boolean isEcdsaPubkey(byte[] item) {
    if (item.length == 33) {
      return (item[0] & 0xff) == 0x02 || (item[0] & 0xff) == 0x03;
    }
    if (item.length == 65) {
      return (item[0] & 0xff) == 0x04;
    }
    return false;
  }

  /** Bare m-of-n multisig: OP_m &lt;pubkeys...&gt; OP_n OP_CHECKMULTISIG (legacy, pre-P2SH). */
  /**
   * Any other consensus-sized bare legacy script (not P2PKH/P2SH/witness nor the narrow
   * {@link #isBareOpN}/{@link #isBareMultisig} templates). Testnet4 uses large bare puzzles at
   * height 118555+.
   */
  public static boolean isBareLegacyScript(byte[] scriptPubKey) {
    if (scriptPubKey.length == 0 || scriptPubKey.length > MAX_CONSENSUS_SCRIPT_SIZE) {
      return false;
    }
    if (witnessProgramVersion(scriptPubKey) != null) {
      return false;
    }
    // OP_RETURN and other small provably-unspendable templates are not bare legacy puzzles.
    if (scriptPubKey.length <= 83 && (scriptPubKey[0] & 0xff) == 0x6a) {
      return false;
    }
    return !(isP2pk(scriptPubKey)
        || isP2pkh(scriptPubKey)
        || isP2wpkh(scriptPubKey)
        || isP2wsh(scriptPubKey)
        || isP2sh(scriptPubKey)
        || isP2tr(scriptPubKey)
        || isBareOpN(scriptPubKey)
        || isBareMultisig(scriptPubKey));
  }

  public static boolean isBareMultisig(byte[] scriptPubKey) {
    if (scriptPubKey.length < 4) {
      return false;
    }
    int offset = 0;
    int mOpcode = scriptPubKey[offset] & 0xff;
    if (mOpcode < OpCodes.OP_1 || mOpcode > OpCodes.OP_16) {
      return false;
    }
    int required = mOpcode - OpCodes.OP_1 + 1;
    offset += 1;

    java.util.ArrayList<byte[]> pubkeys = new java.util.ArrayList<>();
    try {
      while (offset < scriptPubKey.length) {
        int opcode = scriptPubKey[offset] & 0xff;
        if (opcode >= OpCodes.OP_1 && opcode <= OpCodes.OP_16) {
          break;
        }
        ScriptPush.PushResult push = ScriptPush.readPush(scriptPubKey, offset);
        offset = push.nextOffset();
        if (!isEcdsaPubkey(push.item())) {
          return false;
        }
        pubkeys.add(push.item());
        if (pubkeys.size() > MAX_PUBKEYS_PER_MULTISIG) {
          return false;
        }
      }
    } catch (ScriptError error) {
      return false;
    }

    if (pubkeys.isEmpty() || pubkeys.size() < required) {
      return false;
    }
    if (offset >= scriptPubKey.length) {
      return false;
    }

    int nOpcode = scriptPubKey[offset] & 0xff;
    if (nOpcode < OpCodes.OP_1 || nOpcode > OpCodes.OP_16) {
      return false;
    }
    if (nOpcode - OpCodes.OP_1 + 1 != pubkeys.size()) {
      return false;
    }
    offset += 1;
    if (offset >= scriptPubKey.length || (scriptPubKey[offset] & 0xff) != OpCodes.OP_CHECKMULTISIG) {
      return false;
    }
    offset += 1;
    return offset == scriptPubKey.length;
  }

  public static Integer witnessProgramVersion(byte[] scriptPubKey) {
    if (scriptPubKey.length < 4) {
      return null;
    }
    int versionByte = scriptPubKey[0] & 0xff;
    int version;
    if (versionByte == OpCodes.OP_0) {
      version = 0;
    } else if (versionByte >= OpCodes.OP_1 && versionByte <= OpCodes.OP_16) {
      version = versionByte - OpCodes.OP_1 + 1;
    } else {
      return null;
    }
    int pc = 1;
    if (pc >= scriptPubKey.length) {
      return null;
    }
    int opcode = scriptPubKey[pc] & 0xff;
    int pushLen;
    int dataStart;
    if (opcode >= 1 && opcode <= 75) {
      pushLen = opcode;
      dataStart = pc + 1;
    } else if (opcode == OpCodes.OP_PUSHDATA1) {
      if (pc + 1 >= scriptPubKey.length) {
        return null;
      }
      pushLen = scriptPubKey[pc + 1] & 0xff;
      dataStart = pc + 2;
    } else if (opcode == OpCodes.OP_PUSHDATA2) {
      if (pc + 2 >= scriptPubKey.length) {
        return null;
      }
      pushLen = (scriptPubKey[pc + 1] & 0xff) | ((scriptPubKey[pc + 2] & 0xff) << 8);
      dataStart = pc + 3;
    } else if (opcode == OpCodes.OP_PUSHDATA4) {
      if (pc + 4 >= scriptPubKey.length) {
        return null;
      }
      pushLen =
          (scriptPubKey[pc + 1] & 0xff)
              | ((scriptPubKey[pc + 2] & 0xff) << 8)
              | ((scriptPubKey[pc + 3] & 0xff) << 16)
              | ((scriptPubKey[pc + 4] & 0xff) << 24);
      dataStart = pc + 5;
    } else {
      return null;
    }
    if (pushLen < 2 || pushLen > 40) {
      return null;
    }
    if (dataStart + pushLen != scriptPubKey.length) {
      return null;
    }
    return version;
  }

  public static byte[] p2pkhScriptCode(byte[] pubkeyHash) {
    byte[] out = new byte[25];
    out[0] = (byte) OpCodes.OP_DUP;
    out[1] = (byte) OpCodes.OP_HASH160;
    out[2] = 0x14;
    System.arraycopy(pubkeyHash, 0, out, 3, 20);
    out[23] = (byte) OpCodes.OP_EQUALVERIFY;
    out[24] = (byte) OpCodes.OP_CHECKSIG;
    return out;
  }

  static List<byte[]> parsePushOnlyScriptSig(byte[] scriptSig) {
    int offset = 0;
    java.util.ArrayList<byte[]> pushes = new java.util.ArrayList<>();
    while (offset < scriptSig.length) {
      int opcode = scriptSig[offset] & 0xff;
      offset += 1;
      if (opcode == OpCodes.OP_0) {
        pushes.add(new byte[0]);
      } else if (opcode >= OpCodes.OP_1 && opcode <= OpCodes.OP_16) {
        pushes.add(ScriptInterpreter.encodeOpN(opcode - OpCodes.OP_1 + 1));
      } else if (opcode == OpCodes.OP_1NEGATE) {
        pushes.add(new byte[] {(byte) 0x81});
      } else if (ScriptInterpreter.isPushOpcode(opcode)) {
        offset -= 1;
        ScriptPush.PushResult push = ScriptPush.readPush(scriptSig, offset);
        offset = push.nextOffset();
        pushes.add(push.item());
      } else {
        throw new ScriptError("non-push opcode in scriptSig");
      }
    }
    return List.copyOf(pushes);
  }
}
