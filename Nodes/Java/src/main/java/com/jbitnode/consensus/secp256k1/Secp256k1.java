package com.jbitnode.consensus.secp256k1;

import com.jbitnode.consensus.script.ScriptHash;
import com.jbitnode.consensus.script.ScriptVerifyProfiler;
import java.math.BigInteger;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** secp256k1 ECDSA verify/sign (mirrors TypeScriptNode/src/consensus/secp256k1.ts). */
public final class Secp256k1 {

  public static final BigInteger P =
      new BigInteger(
          "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F", 16);
  public static final BigInteger N =
      new BigInteger(
          "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16);
  public static final BigInteger A = BigInteger.ZERO;
  public static final BigInteger B = BigInteger.valueOf(7);
  public static final BigInteger GX =
      new BigInteger(
          "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798", 16);
  public static final BigInteger GY =
      new BigInteger(
          "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8", 16);

  private Secp256k1() {}

  public static final class Secp256k1Error extends RuntimeException {
    public Secp256k1Error(String message) {
      super(message);
    }
  }

  private record Point(BigInteger x, BigInteger y) {}

  public enum Backend {
    PURE_JAVA,
    NATIVE
  }

  public static final class VerificationCache {
    private final Map<String, Point> secPubkeys = new ConcurrentHashMap<>();
    private final Map<String, Point> xonlyPubkeys = new ConcurrentHashMap<>();
  }

  private static final Point GENERATOR = new Point(GX, GY);
  private static final Point[] GENERATOR_DOUBLES = buildGeneratorDoubles();
  private static volatile Secp256k1Backend backend = selectedBackend();

  private static Secp256k1Backend selectedBackend() {
    String raw = System.getenv().getOrDefault("SECP256K1_BACKEND", "native");
    if ("native".equalsIgnoreCase(raw)) {
      return NativeSecp256k1.INSTANCE;
    }
    return PureJavaSecp256k1Backend.INSTANCE;
  }

  /**
   * Enforces the native libsecp256k1 backend for live node runtimes. The pure-Java backend exists
   * only as a local test/reference comparator; the node must not validate consensus with it. Call
   * from node entrypoints before any block connect so the process fails fast when native is
   * unavailable or another backend was requested.
   */
  public static void ensureNativeRuntimeBackend(Map<String, String> env) {
    String requested =
        env.getOrDefault("SECP256K1_BACKEND", "native").trim().toLowerCase(java.util.Locale.ROOT);
    if (!"native".equals(requested)) {
      throw new Secp256k1Error(
          "node runtime requires SECP256K1_BACKEND=native (libsecp256k1); got '"
              + requested
              + "' — pure_java is a test-only comparator");
    }
    if (!nativeBackendAvailable()) {
      throw new Secp256k1Error(
          "native libsecp256k1 backend is unavailable on this platform; "
              + "enable the fr.acinq.secp256k1 JNI natives before running the node");
    }
    backend = NativeSecp256k1.INSTANCE;
  }

  public static String selectedBackendName() {
    if (backend == NativeSecp256k1.INSTANCE) {
      return "libsecp256k1-acinq";
    }
    return "pure_java";
  }

  public static boolean nativeBackendAvailable() {
    try {
      NativeSecp256k1.api();
      return true;
    } catch (RuntimeException | UnsatisfiedLinkError error) {
      return false;
    }
  }

  public static String nativeBackendImplementation() {
    return nativeBackendAvailable() ? "libsecp256k1-acinq" : "unavailable";
  }

  public static String taprootTweakBackendName() {
    return backend == NativeSecp256k1.INSTANCE ? "libsecp256k1-acinq" : selectedBackendName();
  }

  static void useNativeBackendForTests(boolean enabled) {
    backend = enabled ? NativeSecp256k1.INSTANCE : PureJavaSecp256k1Backend.INSTANCE;
  }

  static void useBackendForTests(Backend backendForTest) {
    backend =
        switch (backendForTest) {
          case PURE_JAVA -> PureJavaSecp256k1Backend.INSTANCE;
          case NATIVE -> NativeSecp256k1.INSTANCE;
        };
  }

  private static Point[] buildGeneratorDoubles() {
    Point[] points = new Point[N.bitLength()];
    points[0] = GENERATOR;
    for (int index = 1; index < points.length; index++) {
      points[index] = pointAdd(points[index - 1], points[index - 1]);
    }
    return points;
  }

  public static BigInteger modN(BigInteger value) {
    return mod(value, N);
  }

  private static BigInteger mod(BigInteger value, BigInteger modulus) {
    BigInteger result = value.mod(modulus);
    return result.signum() < 0 ? result.add(modulus) : result;
  }

  private static BigInteger modPow(BigInteger base, BigInteger exponent, BigInteger modulus) {
    return base.modPow(exponent, modulus);
  }

  private static BigInteger modInv(BigInteger value, BigInteger modulus) {
    return modPow(mod(value, modulus), modulus.subtract(BigInteger.TWO), modulus);
  }

  private static Point decompressPubkey(byte[] data) {
    return ScriptVerifyProfiler.measure("script_pubkey_decode_or_lift", () -> decompressPubkeyUnprofiled(data));
  }

  private static Point decompressPubkey(byte[] data, VerificationCache cache) {
    if (cache == null) {
      return decompressPubkey(data);
    }
    String key = Base64.getEncoder().encodeToString(data);
    return cache.secPubkeys.computeIfAbsent(key, ignored -> decompressPubkey(data));
  }

  private static Point decompressPubkeyUnprofiled(byte[] data) {
    if (data.length == 33 && (data[0] == 2 || data[0] == 3)) {
      BigInteger x = new BigInteger(1, Arrays.copyOfRange(data, 1, 33));
      BigInteger ySquared = mod(modPow(x, BigInteger.valueOf(3), P).add(B), P);
      BigInteger y = modPow(ySquared, P.add(BigInteger.ONE).shiftRight(2), P);
      if (y.mod(BigInteger.TWO).equals(BigInteger.ZERO) != (data[0] == 2)) {
        y = P.subtract(y);
      }
      return new Point(x, y);
    }
    if (data.length == 65 && data[0] == 4) {
      BigInteger x = new BigInteger(1, Arrays.copyOfRange(data, 1, 33));
      BigInteger y = new BigInteger(1, Arrays.copyOfRange(data, 33, 65));
      return new Point(x, y);
    }
    throw new Secp256k1Error("invalid public key encoding");
  }

  private static Point pointAdd(Point p1, Point p2) {
    if (p1 == null) {
      return p2;
    }
    if (p2 == null) {
      return p1;
    }
    if (p1.x.equals(p2.x) && mod(p1.y.add(p2.y), P).equals(BigInteger.ZERO)) {
      return null;
    }
    BigInteger slope;
    if (p1.x.equals(p2.x) && p1.y.equals(p2.y)) {
      slope = mod(
          BigInteger.valueOf(3).multiply(p1.x).multiply(p1.x).add(A)
              .multiply(modInv(BigInteger.TWO.multiply(p1.y), P)),
          P);
    } else {
      slope = mod((p2.y.subtract(p1.y)).multiply(modInv(p2.x.subtract(p1.x), P)), P);
    }
    BigInteger x3 = mod(slope.multiply(slope).subtract(p1.x).subtract(p2.x), P);
    BigInteger y3 = mod(slope.multiply(p1.x.subtract(x3)).subtract(p1.y), P);
    return new Point(x3, y3);
  }

  static Point scalarMult(BigInteger scalar, Point point) {
    Point result = null;
    Point addend = point;
    BigInteger k = scalar;
    while (k.compareTo(BigInteger.ZERO) > 0) {
      if (k.testBit(0)) {
        result = pointAdd(result, addend);
      }
      addend = pointAdd(addend, addend);
      k = k.shiftRight(1);
    }
    return result;
  }

  private static Point fixedBaseScalarMult(BigInteger scalar) {
    Point result = null;
    BigInteger k = scalar;
    int bit = 0;
    while (k.compareTo(BigInteger.ZERO) > 0) {
      if (k.testBit(0)) {
        result = pointAdd(result, GENERATOR_DOUBLES[bit]);
      }
      k = k.shiftRight(1);
      bit += 1;
    }
    return result;
  }

  private static Point doubleScalarMult(BigInteger gScalar, Point point, BigInteger pointScalar) {
    Point result = null;
    int maxBits = Math.max(gScalar.bitLength(), pointScalar.bitLength());
    for (int bit = maxBits - 1; bit >= 0; bit--) {
      if (result != null) {
        result = pointAdd(result, result);
      }
      if (gScalar.testBit(bit)) {
        result = pointAdd(result, GENERATOR);
      }
      if (pointScalar.testBit(bit)) {
        result = pointAdd(result, point);
      }
    }
    return result;
  }

  private static BigInteger[] parseDerSignature(byte[] data) {
    if (data.length < 8 || data[0] != 0x30) {
      throw new Secp256k1Error("invalid DER signature");
    }
    if ((data[1] & 0xff) + 2 != data.length) {
      throw new Secp256k1Error("invalid DER signature length");
    }
    if (data[2] != 0x02) {
      throw new Secp256k1Error("invalid DER signature r marker");
    }
    int rLen = data[3] & 0xff;
    BigInteger r = new BigInteger(1, Arrays.copyOfRange(data, 4, 4 + rLen));
    int offset = 4 + rLen;
    if (data[offset] != 0x02) {
      throw new Secp256k1Error("invalid DER signature s marker");
    }
    int sLen = data[offset + 1] & 0xff;
    BigInteger s = new BigInteger(1, Arrays.copyOfRange(data, offset + 2, offset + 2 + sLen));
    if (r.compareTo(BigInteger.ZERO) <= 0
        || s.compareTo(BigInteger.ZERO) <= 0
        || r.compareTo(N) >= 0
        || s.compareTo(N) >= 0) {
      throw new Secp256k1Error("signature r/s out of range");
    }
    return new BigInteger[] {r, s};
  }

  public static boolean verifyDerSignature(byte[] pubkey, byte[] messageHash, byte[] signature) {
    return verifyDerSignature(pubkey, messageHash, signature, null);
  }

  public static boolean verifyDerSignature(
      byte[] pubkey, byte[] messageHash, byte[] signature, VerificationCache cache) {
    if (messageHash.length != 32) {
      throw new Secp256k1Error("message hash must be 32 bytes");
    }
    return ScriptVerifyProfiler.measure(
        "script_ecdsa_verify",
        () -> {
          try {
            BigInteger[] rs = parseDerSignature(signature);
            return backend.verifyDerSignature(pubkey, messageHash, rs[0], rs[1], cache);
          } catch (Secp256k1Error error) {
            return false;
          }
        });
  }

  public static boolean verifyDerSignatureReference(byte[] pubkey, byte[] messageHash, byte[] signature) {
    if (messageHash.length != 32) {
      throw new Secp256k1Error("message hash must be 32 bytes");
    }
    try {
      BigInteger[] rs = parseDerSignature(signature);
      BigInteger r = rs[0];
      BigInteger s = rs[1];
      Point q = decompressPubkey(pubkey);
      BigInteger z = new BigInteger(1, messageHash);
      BigInteger w = modInv(s, N);
      BigInteger u1 = mod(z.multiply(w), N);
      BigInteger u2 = mod(r.multiply(w), N);
      Point g = new Point(GX, GY);
      Point combined = pointAdd(scalarMult(u1, g), scalarMult(u2, q));
      if (combined == null) {
        return false;
      }
      return mod(combined.x, N).equals(r);
    } catch (Secp256k1Error error) {
      return false;
    }
  }

  private static boolean verifyDerSignatureOptimized(
      byte[] pubkey,
      byte[] messageHash,
      BigInteger r,
      BigInteger s,
      VerificationCache cache) {
      Point q = decompressPubkey(pubkey, cache);
      BigInteger z = new BigInteger(1, messageHash);
      BigInteger w = modInv(s, N);
      BigInteger u1 = mod(z.multiply(w), N);
      BigInteger u2 = mod(r.multiply(w), N);
      Point combined = doubleScalarMult(u1, q, u2);
      if (combined == null) {
        return false;
      }
      return mod(combined.x, N).equals(r);
  }


  public static boolean verifySchnorrSignature(
      byte[] pubkeyXonly, byte[] messageHash, byte[] signature) {
    return verifySchnorrSignature(pubkeyXonly, messageHash, signature, null);
  }

  public static boolean verifySchnorrSignature(
      byte[] pubkeyXonly, byte[] messageHash, byte[] signature, VerificationCache cache) {
    return ScriptVerifyProfiler.measure(
        "script_schnorr_verify",
        () -> {
          try {
            return backend.verifySchnorrSignature(pubkeyXonly, messageHash, signature, cache);
          } catch (Secp256k1Error error) {
            return false;
          }
        });
  }

  public static boolean verifySchnorrSignatureReference(
      byte[] pubkeyXonly, byte[] messageHash, byte[] signature) {
    return verifyBip340SchnorrMessage(pubkeyXonly, messageHash, signature);
  }

  public static boolean verifyBip340SchnorrMessage(
      byte[] pubkeyXonly, byte[] message, byte[] signature) {
    return verifySchnorrSignatureOptimized(pubkeyXonly, message, signature, null);
  }

  private static boolean verifySchnorrSignatureOptimized(
      byte[] pubkeyXonly, byte[] message, byte[] signature, VerificationCache cache) {
    if (pubkeyXonly.length != 32 || signature.length != 64) {
      return false;
    }
    try {
      BigInteger xPub = new BigInteger(1, pubkeyXonly);
      Point pubkeyPoint = liftXOnlyPubkey(xPub, cache, pubkeyXonly);
      if (pubkeyPoint == null) {
        return false;
      }
      BigInteger rx = new BigInteger(1, Arrays.copyOfRange(signature, 0, 32));
      BigInteger s = new BigInteger(1, Arrays.copyOfRange(signature, 32, 64));
      if (rx.compareTo(P) >= 0 || s.compareTo(N) >= 0) {
        return false;
      }
      byte[] challengeInput = concat(Arrays.copyOfRange(signature, 0, 32), pubkeyXonly, message);
      BigInteger e =
          mod(
              new BigInteger(1, ScriptHash.bitcoinTaggedHash("BIP0340/challenge", challengeInput)),
              N);
      Point lhs = fixedBaseScalarMult(s);
      Point rhsAdj = scalarMult(mod(N.subtract(e), N), pubkeyPoint);
      Point rPoint = pointAdd(lhs, rhsAdj);
      if (rPoint == null) {
        return false;
      }
      return hasEvenY(rPoint) && mod(rPoint.x(), P).equals(mod(rx, P));
    } catch (Secp256k1Error | ArithmeticException error) {
      return false;
    }
  }

  private interface Secp256k1Backend {
    boolean verifyDerSignature(
        byte[] pubkey, byte[] messageHash, BigInteger r, BigInteger s, VerificationCache cache);

    boolean verifySchnorrSignature(
        byte[] pubkeyXonly, byte[] messageHash, byte[] signature, VerificationCache cache);

    TaprootTweakResult taprootTweakPubkeyXonly(
        byte[] internalXonly, byte[] merkleRoot, VerificationCache cache);
  }

  private enum PureJavaSecp256k1Backend implements Secp256k1Backend {
    INSTANCE;

    @Override
    public boolean verifyDerSignature(
        byte[] pubkey, byte[] messageHash, BigInteger r, BigInteger s, VerificationCache cache) {
      try {
        return verifyDerSignatureOptimized(pubkey, messageHash, r, s, cache);
      } catch (Secp256k1Error error) {
        return false;
      }
    }

    @Override
    public boolean verifySchnorrSignature(
        byte[] pubkeyXonly, byte[] messageHash, byte[] signature, VerificationCache cache) {
      return verifySchnorrSignatureOptimized(pubkeyXonly, messageHash, signature, cache);
    }

    @Override
    public TaprootTweakResult taprootTweakPubkeyXonly(
        byte[] internalXonly, byte[] merkleRoot, VerificationCache cache) {
      return taprootTweakPubkeyXonlyPureJava(internalXonly, merkleRoot, cache);
    }
  }

  public static byte[] signBip340Schnorr(BigInteger secretKey, byte[] message) {
    if (message.length != 32) {
      throw new Secp256k1Error("message hash must be 32 bytes");
    }
    BigInteger d0 = mod(secretKey, N);
    if (d0.compareTo(BigInteger.ZERO) <= 0 || d0.compareTo(N) >= 0) {
      throw new Secp256k1Error("invalid secret key");
    }
    Point gPoint = new Point(GX, GY);
    Point pPoint = scalarMult(d0, gPoint);
    if (pPoint == null) {
      throw new Secp256k1Error("invalid public point");
    }
    BigInteger d = d0;
    if (!hasEvenY(pPoint)) {
      d = N.subtract(d);
      pPoint = scalarMult(d, gPoint);
      if (pPoint == null) {
        throw new Secp256k1Error("invalid public point");
      }
    }
    byte[] pkXBytes = toFixedBytes(pPoint.x(), 32);
    byte[] dBytes = toFixedBytes(d, 32);
    byte[] auxRandInput =
        concat("pbn(aux)".getBytes(java.nio.charset.StandardCharsets.UTF_8), dBytes, message);
    byte[] auxRand;
    try {
      auxRand = MessageDigest.getInstance("SHA-256").digest(auxRandInput);
    } catch (NoSuchAlgorithmException error) {
      throw new Secp256k1Error("SHA-256 unavailable");
    }
    byte[] auxHash = ScriptHash.bitcoinTaggedHash("BIP0340/aux", auxRand);
    byte[] t = new byte[32];
    for (int index = 0; index < 32; index++) {
      t[index] = (byte) (dBytes[index] ^ auxHash[index]);
    }
    byte[] nonceInput = concat(t, pkXBytes, message);
    BigInteger k0 =
        mod(new BigInteger(1, ScriptHash.bitcoinTaggedHash("BIP0340/nonce", nonceInput)), N);
    if (k0.equals(BigInteger.ZERO)) {
      throw new Secp256k1Error("signing failure (retry)");
    }
    Point rPoint = scalarMult(k0, gPoint);
    if (rPoint == null) {
      throw new Secp256k1Error("signing failure (retry)");
    }
    BigInteger k = hasEvenY(rPoint) ? k0 : N.subtract(k0);
    byte[] rBytes = toFixedBytes(rPoint.x(), 32);
    byte[] challengeInput = concat(rBytes, pkXBytes, message);
    BigInteger e =
        mod(
            new BigInteger(1, ScriptHash.bitcoinTaggedHash("BIP0340/challenge", challengeInput)),
            N);
    byte[] sig = concat(rBytes, toFixedBytes(mod(k.add(e.multiply(d)), N), 32));
    if (!verifySchnorrSignature(pkXBytes, message, sig)) {
      throw new Secp256k1Error("internal Schnorr signing failed sanity check");
    }
    return sig;
  }

  public static byte[] taprootOutputKeyXonly(byte[] internalXonly, byte[] merkleRoot) {
    return taprootTweakPubkeyXonly(internalXonly, merkleRoot).outputXonly();
  }

  public record TaprootTweakResult(int parity, byte[] outputXonly) {}

  public static TaprootTweakResult taprootTweakPubkeyXonly(byte[] internalXonly, byte[] merkleRoot) {
    return taprootTweakPubkeyXonly(internalXonly, merkleRoot, null);
  }

  public static TaprootTweakResult taprootTweakPubkeyXonly(
      byte[] internalXonly, byte[] merkleRoot, VerificationCache cache) {
    return backend.taprootTweakPubkeyXonly(internalXonly, merkleRoot, cache);
  }

  private static TaprootTweakResult taprootTweakPubkeyXonlyPureJava(
      byte[] internalXonly, byte[] merkleRoot, VerificationCache cache) {
    if (internalXonly.length != 32) {
      throw new Secp256k1Error("internal key must be 32 bytes");
    }
    BigInteger tweak = taprootTweakScalar(internalXonly, merkleRoot);
    Point internal = liftXOnlyPubkey(new BigInteger(1, internalXonly), cache, internalXonly);
    if (internal == null) {
      throw new Secp256k1Error("invalid internal x-only key");
    }
    Point tweaked = pointAdd(internal, scalarMult(tweak, new Point(GX, GY)));
    if (tweaked == null) {
      throw new Secp256k1Error("taproot tweak failed");
    }
    int parity = hasEvenY(tweaked) ? 0 : 1;
    return new TaprootTweakResult(parity, toFixedBytes(tweaked.x(), 32));
  }

  public static BigInteger taprootTweakScalar(byte[] internalXonly, byte[] merkleRoot) {
    byte[] tweakBytes =
        ScriptHash.bitcoinTaggedHash("TapTweak", concat(internalXonly, merkleRoot));
    BigInteger tweak = new BigInteger(1, tweakBytes);
    if (tweak.compareTo(N) >= 0) {
      throw new Secp256k1Error("TapTweak out of range");
    }
    return tweak;
  }

  private static Point liftXOnlyPubkey(BigInteger xCoord) {
    return ScriptVerifyProfiler.measure("script_pubkey_decode_or_lift", () -> liftXOnlyPubkeyUnprofiled(xCoord));
  }

  private static Point liftXOnlyPubkey(BigInteger xCoord, VerificationCache cache, byte[] keyBytes) {
    if (cache == null) {
      return liftXOnlyPubkey(xCoord);
    }
    String key = Base64.getEncoder().encodeToString(keyBytes);
    return cache.xonlyPubkeys.computeIfAbsent(key, ignored -> liftXOnlyPubkey(xCoord));
  }

  private static Point liftXOnlyPubkeyUnprofiled(BigInteger xCoord) {
    if (xCoord.compareTo(P) >= 0) {
      return null;
    }
    BigInteger ySquared = mod(modPow(xCoord, BigInteger.valueOf(3), P).add(B), P);
    BigInteger y = modPow(ySquared, P.add(BigInteger.ONE).shiftRight(2), P);
    if (!modPow(y, BigInteger.TWO, P).equals(ySquared)) {
      return null;
    }
    if (y.testBit(0)) {
      y = P.subtract(y);
    }
    return new Point(xCoord, y);
  }

  private enum NativeSecp256k1 implements Secp256k1Backend {
    INSTANCE;

    private static fr.acinq.secp256k1.Secp256k1 api() {
      return fr.acinq.secp256k1.Secp256k1.get();
    }

    @Override
    public boolean verifyDerSignature(
        byte[] pubkey, byte[] messageHash, BigInteger r, BigInteger s, VerificationCache cache) {
      try {
        byte[] compact = concat(toFixedBytes(r, 32), toFixedBytes(s, 32));
        if (api().verify(compact, messageHash, pubkey)) {
          return true;
        }
        kotlin.Pair<byte[], Boolean> normalized = api().signatureNormalize(compact);
        return normalized.getSecond() && api().verify(normalized.getFirst(), messageHash, pubkey);
      } catch (RuntimeException | UnsatisfiedLinkError error) {
        return false;
      }
    }

    @Override
    public boolean verifySchnorrSignature(
        byte[] pubkeyXonly, byte[] messageHash, byte[] signature, VerificationCache cache) {
      try {
        return api().verifySchnorr(signature, messageHash, pubkeyXonly);
      } catch (RuntimeException | UnsatisfiedLinkError error) {
        return false;
      }
    }

    @Override
    public TaprootTweakResult taprootTweakPubkeyXonly(
        byte[] internalXonly, byte[] merkleRoot, VerificationCache cache) {
      if (internalXonly.length != 32) {
        throw new Secp256k1Error("internal key must be 32 bytes");
      }
      try {
        BigInteger tweak = taprootTweakScalar(internalXonly, merkleRoot);
        byte[] compressed = new byte[33];
        compressed[0] = 0x02;
        System.arraycopy(internalXonly, 0, compressed, 1, 32);
        byte[] tweaked = api().pubKeyTweakAdd(compressed, toFixedBytes(tweak, 32));
        if (tweaked.length != 65 || tweaked[0] != 4) {
          throw new Secp256k1Error("taproot tweak returned invalid public key");
        }
        int parity = tweaked[64] & 1;
        return new TaprootTweakResult(parity, Arrays.copyOfRange(tweaked, 1, 33));
      } catch (Secp256k1Error error) {
        throw error;
      } catch (RuntimeException | UnsatisfiedLinkError error) {
        throw new Secp256k1Error("native taproot tweak failed");
      }
    }
  }

  private static boolean hasEvenY(Point point) {
    return point.y().mod(BigInteger.TWO).equals(BigInteger.ZERO);
  }

  public static byte[] signDer(BigInteger privateKey, byte[] messageHash) {
    if (privateKey.compareTo(BigInteger.ZERO) <= 0 || privateKey.compareTo(N) >= 0) {
      throw new Secp256k1Error("invalid private key");
    }
    if (messageHash.length != 32) {
      throw new Secp256k1Error("message hash must be 32 bytes");
    }
    BigInteger z = new BigInteger(1, messageHash);
    Point g = new Point(GX, GY);
    for (int nonce = 1; nonce < 1000; nonce++) {
      BigInteger k = BigInteger.valueOf(nonce);
      Point point = scalarMult(k, g);
      if (point == null) {
        continue;
      }
      BigInteger r = mod(point.x, N);
      if (r.equals(BigInteger.ZERO)) {
        continue;
      }
      BigInteger s = mod(modInv(k, N).multiply(z.add(r.multiply(privateKey))), N);
      if (s.equals(BigInteger.ZERO)) {
        continue;
      }
      if (s.compareTo(N.shiftRight(1)) > 0) {
        s = N.subtract(s);
      }
      return encodeDerSignature(r, s);
    }
    throw new Secp256k1Error("failed to sign message");
  }

  public static byte[] testPubkeySec1(BigInteger privateKey) {
    Point point = scalarMult(privateKey, new Point(GX, GY));
    if (point == null) {
      throw new Secp256k1Error("invalid private key");
    }
    byte prefix = (byte) (2 + point.y().mod(BigInteger.TWO).intValue());
    byte[] xBytes = toFixedBytes(point.x(), 32);
    byte[] out = new byte[33];
    out[0] = prefix;
    System.arraycopy(xBytes, 0, out, 1, 32);
    return out;
  }

  static byte[] encodeDerSignature(BigInteger r, BigInteger s) {
    byte[] rBytes = stripLeadingZeros(toFixedBytes(r, 32));
    byte[] sBytes = stripLeadingZeros(toFixedBytes(s, 32));
    if ((rBytes[0] & 0x80) != 0) {
      rBytes = concat(new byte[] {0x00}, rBytes);
    }
    if ((sBytes[0] & 0x80) != 0) {
      sBytes = concat(new byte[] {0x00}, sBytes);
    }
    int totalLen = 2 + rBytes.length + 2 + sBytes.length;
    byte[] out = new byte[2 + totalLen];
    out[0] = 0x30;
    out[1] = (byte) totalLen;
    out[2] = 0x02;
    out[3] = (byte) rBytes.length;
    System.arraycopy(rBytes, 0, out, 4, rBytes.length);
    int sOffset = 4 + rBytes.length;
    out[sOffset] = 0x02;
    out[sOffset + 1] = (byte) sBytes.length;
    System.arraycopy(sBytes, 0, out, sOffset + 2, sBytes.length);
    return out;
  }

  private static byte[] stripLeadingZeros(byte[] bytes) {
    int start = 0;
    while (start < bytes.length - 1 && bytes[start] == 0) {
      start += 1;
    }
    return Arrays.copyOfRange(bytes, start, bytes.length);
  }

  private static byte[] toFixedBytes(BigInteger value, int length) {
    byte[] raw = value.toByteArray();
    byte[] out = new byte[length];
    int copyStart = Math.max(0, raw.length - length);
    int copyLen = Math.min(raw.length, length);
    System.arraycopy(raw, copyStart, out, length - copyLen, copyLen);
    return out;
  }

  private static byte[] concat(byte[] a, byte[] b) {
    byte[] out = new byte[a.length + b.length];
    System.arraycopy(a, 0, out, 0, a.length);
    System.arraycopy(b, 0, out, a.length, b.length);
    return out;
  }
  private static byte[] concat(byte[] a, byte[] b, byte[] c) {
    byte[] out = new byte[a.length + b.length + c.length];
    System.arraycopy(a, 0, out, 0, a.length);
    System.arraycopy(b, 0, out, a.length, b.length);
    System.arraycopy(c, 0, out, a.length + b.length, c.length);
    return out;
  }
}
