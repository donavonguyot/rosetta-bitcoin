using System.Numerics;
using System.Security.Cryptography;

namespace CsBitNode.Consensus.Script;

public static class Secp256k1
{
    private static readonly BigInteger P = ParseUnsignedHex(
        "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F");
    private static readonly BigInteger N = ParseUnsignedHex(
        "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");
    private const long B = 7;
    private static readonly BigInteger Gx = ParseUnsignedHex(
        "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798");
    private static readonly BigInteger Gy = ParseUnsignedHex(
        "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8");

    public sealed record TaprootTweakResult(int Parity, byte[] OutputXOnly);

    private static BigInteger ParseUnsignedHex(string hex) =>
        new(Convert.FromHexString(hex), isUnsigned: true, isBigEndian: true);

    public static string SelectedBackendName() =>
        UseNativeBackend() ? "libsecp256k1-secp256k1.net" : "pure_csharp";

    public static bool NativeBackendAvailable()
    {
        try
        {
            return NativeVerifyEcdsa(
                Convert.FromHexString("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"),
                Convert.FromHexString("281dd50f6f56bc6e867fe73dd614a73c55a647a479704f64804b574cafb0f5c5"),
                Convert.FromHexString("3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4"));
        }
        catch
        {
            return false;
        }
    }

    public static string TaprootTweakBackendName() =>
        UseNativeBackend() ? "libsecp256k1-secp256k1.net" : "pure_csharp";

    public static bool VerifyDerSignature(ReadOnlySpan<byte> pubkey, ReadOnlySpan<byte> messageHash, ReadOnlySpan<byte> signature)
    {
        if (UseNativeBackend())
            return NativeVerifyEcdsa(pubkey, messageHash, signature);
        return VerifyDerSignatureReference(pubkey, messageHash, signature);
    }

    public static bool VerifyDerSignatureReference(ReadOnlySpan<byte> pubkey, ReadOnlySpan<byte> messageHash, ReadOnlySpan<byte> signature)
    {
        if (messageHash.Length != 32)
            return false;
        try
        {
            var (r, s) = ParseDerSignature(signature);
            var (qx, qy) = DecompressPubkey(pubkey);
            var z = new BigInteger(messageHash, isUnsigned: true, isBigEndian: true);
            var w = ModInv(s, N);
            var u1 = (z * w) % N;
            var u2 = (r * w) % N;
            var point = PointAdd(ScalarMult(u1, (Gx, Gy)), ScalarMult(u2, (qx, qy)));
            if (point is null)
                return false;
            return point.Value.X % N == r;
        }
        catch (Secp256k1Exception)
        {
            return false;
        }
    }

    public static bool VerifySchnorrSignature(ReadOnlySpan<byte> pubkeyXOnly, ReadOnlySpan<byte> messageHash, ReadOnlySpan<byte> signature)
    {
        if (pubkeyXOnly.Length != 32 || messageHash.Length != 32 || signature.Length != 64)
            return false;
        try
        {
            return global::Secp256k1Net.Secp256k1.VerifySchnorr(signature, messageHash, pubkeyXOnly);
        }
        catch
        {
            return false;
        }
    }

    public static TaprootTweakResult TaprootTweakPubkeyXOnly(ReadOnlySpan<byte> internalXOnly, ReadOnlySpan<byte> merkleRoot)
    {
        if (internalXOnly.Length != 32)
            throw new Secp256k1Exception("internal key must be 32 bytes");
        if (merkleRoot.Length is not 0 and not 32)
            throw new Secp256k1Exception("merkle root must be empty or 32 bytes");

        var tweak = TaprootTweakScalar(internalXOnly, merkleRoot);
        if (UseNativeBackend())
        {
            try
            {
                var compressedInternal = new byte[33];
                compressedInternal[0] = 0x02;
                internalXOnly.CopyTo(compressedInternal.AsSpan(1));
                var tweaked = global::Secp256k1Net.Secp256k1.TweakPublicKeyAdd(compressedInternal, tweak, compressed: true);
                if (tweaked.Length != 33 || tweaked[0] is not (0x02 or 0x03))
                    throw new Secp256k1Exception("taproot tweak returned invalid public key");
                return new TaprootTweakResult(tweaked[0] & 1, tweaked[1..]);
            }
            catch (Secp256k1Exception)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new Secp256k1Exception($"native taproot tweak failed: {ex.Message}");
            }
        }

        var internalPoint = LiftX(internalXOnly);
        var tweakScalar = new BigInteger(tweak, isUnsigned: true, isBigEndian: true);
        if (tweakScalar >= N)
            throw new Secp256k1Exception("taproot tweak scalar out of range");
        var tweakedPoint = PointAdd(internalPoint, ScalarMult(tweakScalar, (Gx, Gy)))
            ?? throw new Secp256k1Exception("taproot tweak produced point at infinity");
        return new TaprootTweakResult(tweakedPoint.Y.IsEven ? 0 : 1, ToFixedBytes(tweakedPoint.X, 32));
    }

    public static byte[] SignDer(int privateKey, ReadOnlySpan<byte> messageHash)
    {
        var d = (BigInteger)privateKey;
        if (d <= 0 || d >= N)
            throw new Secp256k1Exception("invalid private key");
        if (messageHash.Length != 32)
            throw new Secp256k1Exception("message hash must be 32 bytes");

        var z = new BigInteger(messageHash, isUnsigned: true, isBigEndian: true);
        for (var nonce = 1; nonce < 1000; nonce++)
        {
            var k = (BigInteger)nonce;
            var point = ScalarMult(k, (Gx, Gy));
            if (point is null)
                continue;
            var r = point.Value.X % N;
            if (r == 0)
                continue;
            var s = (ModInv(k, N) * (z + r * d)) % N;
            if (s == 0)
                continue;
            if (s > N / 2)
                s = N - s;
            var rBytes = TrimBigInteger(r, 32);
            var sBytes = TrimBigInteger(s, 32);
            return
            [
                0x30, (byte)(4 + rBytes.Length + sBytes.Length), 0x02, (byte)rBytes.Length,
                ..rBytes,
                0x02, (byte)sBytes.Length,
                ..sBytes
            ];
        }
        throw new Secp256k1Exception("failed to sign message");
    }

    private static bool UseNativeBackend()
    {
        var backend = Environment.GetEnvironmentVariable("SECP256K1_BACKEND")
            ?? Environment.GetEnvironmentVariable("CSBITNODE_SECP256K1_BACKEND")
            ?? "pure_csharp";
        return backend.Equals("native", StringComparison.OrdinalIgnoreCase);
    }

    private static bool NativeVerifyEcdsa(ReadOnlySpan<byte> pubkey, ReadOnlySpan<byte> messageHash, ReadOnlySpan<byte> derSignature)
    {
        if (messageHash.Length != 32)
            return false;
        try
        {
            var (r, s) = ParseDerSignature(derSignature);
            var compact = new byte[64];
            ToFixedBytes(r, 32).CopyTo(compact, 0);
            ToFixedBytes(s, 32).CopyTo(compact, 32);
            if (global::Secp256k1Net.Secp256k1.Verify(compact, messageHash, pubkey))
                return true;
            var normalized = global::Secp256k1Net.Secp256k1.NormalizeSignature(compact);
            return global::Secp256k1Net.Secp256k1.Verify(normalized, messageHash, pubkey);
        }
        catch
        {
            return false;
        }
    }

    private static byte[] TaprootTweakScalar(ReadOnlySpan<byte> internalXOnly, ReadOnlySpan<byte> merkleRoot)
    {
        var payload = new byte[internalXOnly.Length + merkleRoot.Length];
        internalXOnly.CopyTo(payload);
        merkleRoot.CopyTo(payload.AsSpan(internalXOnly.Length));
        return TaggedHash("TapTweak", payload);
    }

    private static byte[] TaggedHash(string tag, ReadOnlySpan<byte> payload)
    {
        var tagHash = SHA256.HashData(System.Text.Encoding.ASCII.GetBytes(tag));
        var buffer = new byte[tagHash.Length * 2 + payload.Length];
        tagHash.CopyTo(buffer, 0);
        tagHash.CopyTo(buffer, tagHash.Length);
        payload.CopyTo(buffer.AsSpan(tagHash.Length * 2));
        return SHA256.HashData(buffer);
    }

    private static (BigInteger X, BigInteger Y) LiftX(ReadOnlySpan<byte> xBytes)
    {
        var x = new BigInteger(xBytes, isUnsigned: true, isBigEndian: true);
        if (x >= P)
            throw new Secp256k1Exception("x coordinate out of range");
        var ySquared = (BigInteger.ModPow(x, 3, P) + B) % P;
        var y = BigInteger.ModPow(ySquared, (P + 1) / 4, P);
        if ((y * y - ySquared) % P != 0)
            throw new Secp256k1Exception("x coordinate is not on curve");
        if (!y.IsEven)
            y = P - y;
        return (x, y);
    }

    private static byte[] ToFixedBytes(BigInteger value, int length)
    {
        var bytes = value.ToByteArray(isUnsigned: true, isBigEndian: true);
        if (bytes.Length > length)
            throw new Secp256k1Exception("integer does not fit");
        var output = new byte[length];
        bytes.CopyTo(output.AsSpan(length - bytes.Length));
        return output;
    }

    private static (BigInteger R, BigInteger S) ParseDerSignature(ReadOnlySpan<byte> data)
    {
        if (data.Length < 8 || data[0] != 0x30 || data[1] + 2 != data.Length || data[2] != 0x02)
            throw new Secp256k1Exception("invalid DER signature");
        var rLen = data[3];
        var r = new BigInteger(data.Slice(4, rLen), isUnsigned: true, isBigEndian: true);
        var offset = 4 + rLen;
        if (data[offset] != 0x02)
            throw new Secp256k1Exception("invalid DER signature s marker");
        var sLen = data[offset + 1];
        var s = new BigInteger(data.Slice(offset + 2, sLen), isUnsigned: true, isBigEndian: true);
        if (r <= 0 || s <= 0 || r >= N || s >= N)
            throw new Secp256k1Exception("signature r/s out of range");
        return (r, s);
    }

    private static (BigInteger X, BigInteger Y) DecompressPubkey(ReadOnlySpan<byte> data)
    {
        if (data.Length == 33 && data[0] is 0x02 or 0x03)
        {
            var x = new BigInteger(data[1..], isUnsigned: true, isBigEndian: true);
            var ySquared = (BigInteger.ModPow(x, 3, P) + B) % P;
            var y = BigInteger.ModPow(ySquared, (P + 1) / 4, P);
            if ((y.IsEven != (data[0] == 0x02)))
                y = P - y;
            return (x, y);
        }
        if (data.Length == 65 && data[0] == 0x04)
        {
            var x = new BigInteger(data[1..33], isUnsigned: true, isBigEndian: true);
            var y = new BigInteger(data[33..65], isUnsigned: true, isBigEndian: true);
            return (x, y);
        }
        throw new Secp256k1Exception("invalid public key encoding");
    }

    private static (BigInteger X, BigInteger Y)? PointAdd((BigInteger X, BigInteger Y)? p1, (BigInteger X, BigInteger Y)? p2)
    {
        if (p1 is null)
            return p2;
        if (p2 is null)
            return p1;
        var (x1, y1) = p1.Value;
        var (x2, y2) = p2.Value;
        if (x1 == x2 && (y1 + y2) % P == 0)
            return null;
        BigInteger slope;
        if (p1.Value == p2.Value)
            slope = (3 * x1 * x1 * ModInv(2 * y1, P)) % P;
        else
            slope = ((y2 - y1) * ModInv(x2 - x1, P)) % P;
        var x3 = (slope * slope - x1 - x2) % P;
        var y3 = (slope * (x1 - x3) - y1) % P;
        return (x3, y3);
    }

    private static (BigInteger X, BigInteger Y)? ScalarMult(BigInteger k, (BigInteger X, BigInteger Y) point)
    {
        (BigInteger X, BigInteger Y)? result = null;
        var addend = point;
        while (k > 0)
        {
            if ((k & 1) == 1)
                result = PointAdd(result, addend);
            addend = PointAdd(addend, addend)!.Value;
            k >>= 1;
        }
        return result;
    }

    private static BigInteger ModInv(BigInteger value, BigInteger modulus) =>
        BigInteger.ModPow(value, modulus - 2, modulus);

    private static byte[] TrimBigInteger(BigInteger value, int maxLen)
    {
        var bytes = value.ToByteArray(isUnsigned: true, isBigEndian: true);
        var start = 0;
        while (start < bytes.Length - 1 && bytes[start] == 0)
            start++;
        bytes = bytes[start..];
        if (bytes.Length == 0)
            return [0x00];
        return bytes;
    }
}

public sealed class Secp256k1Exception : Exception
{
    public Secp256k1Exception(string message) : base(message) { }
}
