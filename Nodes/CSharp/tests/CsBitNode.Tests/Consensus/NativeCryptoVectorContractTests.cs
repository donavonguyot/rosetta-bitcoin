using System.Text.Json;
using CsBitNode.Consensus.Script;
using CsBitNode.Util;

namespace CsBitNode.Tests.Consensus;

public class NativeCryptoVectorContractTests
{
    [Fact]
    public void ExecutesSharedNativeCryptoVectorContract()
    {
        Environment.SetEnvironmentVariable("SECP256K1_BACKEND", "native");
        using var doc = JsonDocument.Parse(File.ReadAllText(
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "NodeCore", "conformance", "fixtures", "native_crypto_v1_vectors.json"))));
        var root = doc.RootElement;
        Assert.Equal(1, root.GetProperty("version").GetInt32());
        Assert.Equal("libsecp256k1", root.GetProperty("target_backend").GetString());
        Assert.Equal("active", root.GetProperty("status").GetString());
        Assert.True(Secp256k1.NativeBackendAvailable());

        foreach (var vector in root.GetProperty("vectors").EnumerateArray())
            AssertVector(vector);
    }

    private static void AssertVector(JsonElement vector)
    {
        var expected = vector.GetProperty("expected").GetString();
        switch (vector.GetProperty("operation").GetString())
        {
            case "verify_ecdsa":
            {
                var ok = Secp256k1.VerifyDerSignature(
                    Hex.Decode(vector.GetProperty("pubkey_hex").GetString()!),
                    Hex.Decode(vector.GetProperty("msg_hash_hex").GetString()!),
                    Hex.Decode(vector.GetProperty("signature_hex").GetString()!));
                Assert.Equal(expected == "valid", ok);
                break;
            }
            case "verify_schnorr":
            {
                var ok = Secp256k1.VerifySchnorrSignature(
                    Hex.Decode(vector.GetProperty("xonly_pubkey_hex").GetString()!),
                    Hex.Decode(vector.GetProperty("msg_hash_hex").GetString()!),
                    Hex.Decode(vector.GetProperty("signature_hex").GetString()!));
                Assert.Equal(expected == "valid", ok);
                break;
            }
            case "taproot_tweak_xonly":
            {
                if (expected == "valid")
                {
                    var result = Secp256k1.TaprootTweakPubkeyXOnly(
                        Hex.Decode(vector.GetProperty("xonly_pubkey_hex").GetString()!),
                        Hex.Decode(vector.GetProperty("merkle_root_hex").GetString()!));
                    Assert.Equal(vector.GetProperty("expected_parity").GetInt32(), result.Parity);
                    Assert.Equal(
                        vector.GetProperty("expected_output_xonly_hex").GetString(),
                        Hex.Encode(result.OutputXOnly));
                }
                else
                {
                    Assert.Throws<Secp256k1Exception>(() => Secp256k1.TaprootTweakPubkeyXOnly(
                        Hex.Decode(vector.GetProperty("xonly_pubkey_hex").GetString()!),
                        Hex.Decode(vector.GetProperty("merkle_root_hex").GetString()!)));
                }
                break;
            }
            default:
                throw new InvalidOperationException("unknown native crypto operation");
        }
    }
}
