using System.Text.Json;
using System.Text.Json.Nodes;
using CsBitNode.Consensus.Script;
using CsBitNode.Util;

namespace CsBitNode.Cli;

public static class TestCapabilityService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public static int Run(string[] args, IDictionary<string, string?> env, TextWriter output)
    {
        var kind = ArgValue(args, "--kind", "");
        var outcomePath = ArgValue(args, "--outcome-path", "");
        if (kind.Length == 0 || outcomePath.Length == 0)
            throw new ArgumentException("--kind and --outcome-path are required");
        if (!Secp256k1.NativeBackendAvailable())
            throw new InvalidOperationException("native secp256k1 backend unavailable");

        var outcomes = kind switch
        {
            "crypto-vectors" => CryptoVectorOutcomes(),
            "block-connect-backend" => BlockConnectOutcomes(env),
            _ => throw new ArgumentException($"unknown kind: {kind}")
        };
        var doc = new JsonObject
        {
            ["port"] = "csharp",
            ["backend"] = "libsecp256k1-secp256k1.net",
            ["outcomes"] = outcomes
        };
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outcomePath))!);
        File.WriteAllText(outcomePath, JsonSerializer.Serialize(doc, JsonOptions) + Environment.NewLine);
        output.WriteLine(outcomePath);
        return 0;
    }

    private static JsonArray CryptoVectorOutcomes()
    {
        Environment.SetEnvironmentVariable("SECP256K1_BACKEND", "native");
        var root = RepoRoot();
        var bip = RunBip340(Path.Combine(root, "Nodes/Shared/testing/fixtures/bip340/test-vectors.csv"));
        var native = RunNativeVectors(Path.Combine(root, "Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json"));
        return new JsonArray
        {
            Outcome("crypto_bip340_vectors", bip),
            Outcome("crypto_libsecp256k1_equivalence", new OutcomeResult(
                bip.Passed + native.Passed,
                bip.Total + native.Total,
                JoinNotes(bip.Notes, native.Notes)))
        };
    }

    private static OutcomeResult RunBip340(string path)
    {
        var passed = 0;
        var total = 0;
        var failures = new List<string>();
        foreach (var line in File.ReadLines(path).Skip(1))
        {
            var fields = line.Split(',');
            if (fields.Length < 7)
                throw new InvalidOperationException("malformed BIP340 vector row");
            total++;
            var expected = fields[6] == "TRUE";
            var actual = false;
            try
            {
                actual = global::Secp256k1Net.Secp256k1.VerifySchnorr(
                    Hex.Decode(fields[5]),
                    Hex.Decode(fields[4]),
                    Hex.Decode(fields[2]));
            }
            catch
            {
                actual = false;
            }
            if (actual == expected)
                passed++;
            else
                failures.Add(fields[0]);
        }
        return failures.Count == 0
            ? new OutcomeResult(passed, total, "all BIP340 vectors matched expected verification result")
            : new OutcomeResult(passed, total, "mismatched BIP340 vector indexes: " + string.Join(",", failures));
    }

    private static OutcomeResult RunNativeVectors(string path)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var passed = 0;
        var failures = new List<string>();
        foreach (var vector in doc.RootElement.GetProperty("vectors").EnumerateArray())
        {
            if (NativeVectorMatches(vector))
                passed++;
            else
                failures.Add(vector.GetProperty("id").GetString()!);
        }
        var total = doc.RootElement.GetProperty("vectors").GetArrayLength();
        return failures.Count == 0
            ? new OutcomeResult(passed, total, $"native crypto vectors {passed}/{total}")
            : new OutcomeResult(passed, total, "native vector failures: " + string.Join(",", failures));
    }

    private static bool NativeVectorMatches(JsonElement vector)
    {
        var expected = vector.GetProperty("expected").GetString();
        return vector.GetProperty("operation").GetString() switch
        {
            "verify_ecdsa" => VerifyResult(expected, Secp256k1.VerifyDerSignature(
                Hex.Decode(vector.GetProperty("pubkey_hex").GetString()!),
                Hex.Decode(vector.GetProperty("msg_hash_hex").GetString()!),
                Hex.Decode(vector.GetProperty("signature_hex").GetString()!))),
            "verify_schnorr" => VerifyResult(expected, Secp256k1.VerifySchnorrSignature(
                Hex.Decode(vector.GetProperty("xonly_pubkey_hex").GetString()!),
                Hex.Decode(vector.GetProperty("msg_hash_hex").GetString()!),
                Hex.Decode(vector.GetProperty("signature_hex").GetString()!))),
            "taproot_tweak_xonly" => TaprootVectorMatches(vector, expected),
            _ => false
        };
    }

    private static bool TaprootVectorMatches(JsonElement vector, string? expected)
    {
        try
        {
            var result = Secp256k1.TaprootTweakPubkeyXOnly(
                Hex.Decode(vector.GetProperty("xonly_pubkey_hex").GetString()!),
                Hex.Decode(vector.GetProperty("merkle_root_hex").GetString()!));
            var matches = result.Parity == vector.GetProperty("expected_parity").GetInt32()
                && Hex.Encode(result.OutputXOnly) == vector.GetProperty("expected_output_xonly_hex").GetString();
            return VerifyResult(expected, matches);
        }
        catch (Secp256k1Exception)
        {
            return expected != "valid";
        }
    }

    private static JsonArray BlockConnectOutcomes(IDictionary<string, string?> env)
    {
        var root = RepoRoot();
        var fixtures = new[] { "scripts.p2pkh_sighash_single_38010", "scripts.p2tr_scriptpath_44295" };
        var passed = 0;
        var notes = new List<string>();
        foreach (var fixture in fixtures)
        {
            var temp = Path.Combine(Path.GetTempPath(), $"csbitnode_{fixture.Replace('.', '_')}_{Guid.NewGuid():N}.json");
            try
            {
                using var writer = new StringWriter();
                var exit = ScriptCorpusService.Run(
                    new[] {
                        "--result-path", temp,
                        "--fixture-id", fixture,
                        "--manifest", Path.Combine(root, "Nodes/Shared/conformance/fixtures/scripts/manifest.json")
                    },
                    env,
                    writer);
                using var doc = JsonDocument.Parse(File.ReadAllText(temp));
                if (exit == 0 && doc.RootElement.GetProperty("result").GetString() == "passed" && doc.RootElement.GetProperty("passed").GetInt32() == 1)
                    passed++;
                notes.Add($"{fixture} result={doc.RootElement.GetProperty("result").GetString()}");
            }
            finally
            {
                File.Delete(temp);
            }
        }
        return new JsonArray { Outcome("block_connect_with_backend", new OutcomeResult(passed, fixtures.Length, string.Join("; ", notes))) };
    }

    private static JsonObject Outcome(string capability, OutcomeResult result) => new()
    {
        ["capability"] = capability,
        ["status"] = result.Passed == result.Total ? "pass" : "fail",
        ["case_passed"] = result.Passed,
        ["case_total"] = result.Total,
        ["notes"] = result.Notes
    };

    private static bool VerifyResult(string? expected, bool actual) =>
        (expected == "valid" && actual) || (expected != "valid" && !actual);

    private static string JoinNotes(string first, string second) =>
        first.Length == 0 ? second : second.Length == 0 ? first : first + "; " + second;

    private static string ArgValue(string[] args, string name, string fallback)
    {
        for (var i = 0; i + 1 < args.Length; i++)
            if (args[i] == name)
                return args[i + 1];
        return fallback;
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (dir is not null)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "Nodes/Shared")) && Directory.Exists(Path.Combine(dir.FullName, "Nodes/CSharp")))
                return dir.FullName;
            dir = dir.Parent;
        }
        throw new InvalidOperationException("could not locate repository root");
    }

    private sealed record OutcomeResult(int Passed, int Total, string Notes);
}
