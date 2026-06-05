using System.Text.Json;
using System.Text.Json.Nodes;
using CsBitNode.Consensus.Script;
using CsBitNode.Consensus.Tx;
using CsBitNode.Util;

namespace CsBitNode.Cli;

public static class ScriptCorpusService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public static int Run(string[] args, IDictionary<string, string?> env, TextWriter output)
    {
        if (!Secp256k1.NativeBackendAvailable())
            throw new InvalidOperationException("native secp256k1 backend unavailable");
        if (!string.Equals(Env(env, "SECP256K1_BACKEND") ?? Env(env, "CSBITNODE_SECP256K1_BACKEND") ?? "native", "native", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("script corpus requires SECP256K1_BACKEND=native");

        var root = RepoRoot();
        var manifestPath = Path.GetFullPath(ArgValue(args, "--manifest", Path.Combine(root, "Nodes/Shared/conformance/fixtures/scripts/manifest.json")));
        var resultPath = Path.GetFullPath(ArgValue(args, "--result-path", Path.Combine(root, $"Nodes/Shared/conformance/results/csharp_script_corpus_{DateTime.UtcNow:yyyy-MM-dd}.json")));
        var runtimeSurface = ArgValue(args, "--runtime-surface", Env(env, "RUNTIME_SURFACE") ?? "host");
        var fixtureId = ArgValue(args, "--fixture-id", "");
        var manifest = JsonNode.Parse(File.ReadAllText(manifestPath))!.AsObject();
        var results = new JsonArray();
        var passed = 0;
        var failed = 0;

        foreach (var fixture in manifest["fixtures"]!.AsArray().OfType<JsonObject>())
        {
            if (fixtureId.Length > 0 && fixtureId != Text(fixture, "fixture_id"))
                continue;
            var row = RunFixture(manifestPath, fixture);
            if (Text(row, "result") == "passed")
                passed++;
            else
                failed++;
            results.Add(row);
        }

        var doc = new JsonObject
        {
            ["schema"] = "port.script_corpus_result.v1",
            ["implementation"] = "CSharpNode",
            ["port"] = "csharp",
            ["category"] = "script_corpus",
            ["runtime_surface"] = runtimeSurface,
            ["native_crypto_backend"] = Secp256k1.SelectedBackendName(),
            ["captured_at"] = DateTime.UtcNow.ToString("O"),
            ["commit"] = GitCommit(root),
            ["manifest"] = Path.GetRelativePath(root, manifestPath).Replace('\\', '/'),
            ["fixture_count"] = results.Count,
            ["passed"] = passed,
            ["failed"] = failed,
            ["result"] = failed == 0 ? "passed" : "failed",
            ["verifier"] = new JsonObject
            {
                ["engine"] = "csharp_native",
                ["crypto_backend"] = Secp256k1.SelectedBackendName(),
                ["source"] = "Nodes/CSharp/src/CsBitNode/Consensus/Script"
            },
            ["results"] = results
        };

        Directory.CreateDirectory(Path.GetDirectoryName(resultPath)!);
        File.WriteAllText(resultPath, JsonSerializer.Serialize(doc, JsonOptions) + Environment.NewLine);
        output.WriteLine(JsonSerializer.Serialize(new JsonObject
        {
            ["fixture_count"] = results.Count,
            ["passed"] = passed,
            ["failed"] = failed,
            ["result"] = failed == 0 ? "passed" : "failed",
            ["result_path"] = resultPath
        }, JsonOptions));
        return failed == 0 ? 0 : 1;
    }

    private static JsonObject RunFixture(string manifestPath, JsonObject fixture)
    {
        var inputIndex = Int(fixture, "input_index", 0);
        var row = new JsonObject
        {
            ["fixture_id"] = Text(fixture, "fixture_id"),
            ["height"] = Int(fixture, "height", -1),
            ["txid"] = Text(fixture, "txid"),
            ["input_index"] = inputIndex,
            ["required_rules"] = fixture["required_rules"]?.DeepClone() ?? new JsonArray(),
            ["missing_rule"] = Text(fixture, "missing_rule")
        };
        try
        {
            var tx = ReadTransaction(manifestPath, fixture);
            var prevouts = AlignPrevouts(manifestPath, fixture, tx);
            if (inputIndex >= prevouts.Count)
                throw new InvalidOperationException("fixture input_index has no matching prevout");
            var target = prevouts[inputIndex];
            ScriptVerify.VerifyTransactionInput(tx, inputIndex, new ScriptVerify.VerifyInputOptions(target.ScriptPubKey, target.Amount, prevouts));
            row["result"] = "passed";
            row["failure"] = "";
            row["failure_type"] = "";
            row["failure_stage"] = "";
        }
        catch (Exception error)
        {
            row["result"] = "failed";
            row["failure"] = error.Message;
            row["failure_type"] = error.GetType().Name;
            row["failure_stage"] = FailureStage(error.Message);
        }
        return row;
    }

    private static Transaction ReadTransaction(string manifestPath, JsonObject fixture)
    {
        var raw = Hex.Decode(ReadHex(FirstFile(manifestPath, fixture, "tx")));
        var offset = 0;
        var tx = TransactionParser.Parse(raw, ref offset, witnessEnabled: true);
        if (offset != raw.Length)
            throw new InvalidOperationException($"transaction parser consumed {offset} of {raw.Length}");
        return tx;
    }

    private static IReadOnlyList<ScriptVerify.SpentPrevout> AlignPrevouts(string manifestPath, JsonObject fixture, Transaction tx)
    {
        var prevouts = ReadPrevouts(manifestPath, fixture).ToList();
        if (prevouts.Count == tx.Inputs.Count)
            return prevouts;
        var inputIndex = Int(fixture, "input_index", 0);
        var target = TargetPrevout(manifestPath, fixture, prevouts.Count > 0 ? prevouts[0] : null);
        while (prevouts.Count < tx.Inputs.Count)
            prevouts.Add(new ScriptVerify.SpentPrevout(0, Array.Empty<byte>()));
        prevouts[inputIndex] = target;
        return prevouts;
    }

    private static IReadOnlyList<ScriptVerify.SpentPrevout> ReadPrevouts(string manifestPath, JsonObject fixture)
    {
        var prevoutsFile = OptionalFile(manifestPath, fixture, "prevouts");
        if (prevoutsFile.Length == 0)
            return new[] { TargetPrevout(manifestPath, fixture, null) };
        var parsed = JsonNode.Parse(File.ReadAllText(prevoutsFile))!.AsArray();
        return parsed.OfType<JsonObject>()
            .Select(row => new ScriptVerify.SpentPrevout(Long(row, "amount", "amount_sats", "value"), Hex.Decode(FirstText(row, "spk", "script_pubkey", "scriptPubKey"))))
            .ToList();
    }

    private static ScriptVerify.SpentPrevout TargetPrevout(string manifestPath, JsonObject fixture, ScriptVerify.SpentPrevout? fallback)
    {
        var amount = fixture.TryGetPropertyValue("prev_amount_sats", out var amountNode) && amountNode is not null
            ? amountNode.GetValue<long>()
            : long.MinValue;
        var spk = Text(fixture, "spent_script_pubkey");
        var prevSpkFile = OptionalFile(manifestPath, fixture, "prev_spk");
        if (prevSpkFile.Length > 0)
            spk = ReadHex(prevSpkFile);
        if (amount != long.MinValue && spk.Length > 0)
            return new ScriptVerify.SpentPrevout(amount, Hex.Decode(spk));
        if (fallback is not null)
            return fallback;
        throw new InvalidOperationException($"fixture has no usable prevout data: {Text(fixture, "fixture_id")}");
    }

    private static string FirstFile(string manifestPath, JsonObject fixture, string category)
    {
        var path = OptionalFile(manifestPath, fixture, category);
        if (path.Length == 0)
            throw new InvalidOperationException($"fixture has no {category} file: {Text(fixture, "fixture_id")}");
        return path;
    }

    private static string OptionalFile(string manifestPath, JsonObject fixture, string category)
    {
        if (fixture["files"] is not JsonObject files || files[category] is not JsonArray values || values.Count == 0)
            return "";
        return Path.Combine(Path.GetDirectoryName(manifestPath)!, values[0]!.GetValue<string>());
    }

    private static string ReadHex(string path) => File.ReadAllText(path).Trim();

    private static string ArgValue(string[] args, string name, string fallback)
    {
        for (var i = 0; i + 1 < args.Length; i++)
            if (args[i] == name)
                return args[i + 1];
        return fallback;
    }

    private static string? Env(IDictionary<string, string?> env, string key) =>
        env.TryGetValue(key, out var value) ? value : null;

    private static string Text(JsonObject row, string field) =>
        row.TryGetPropertyValue(field, out var value) && value is not null ? value.GetValue<string>() : "";

    private static int Int(JsonObject row, string field, int fallback) =>
        row.TryGetPropertyValue(field, out var value) && value is not null ? value.GetValue<int>() : fallback;

    private static long Long(JsonObject row, params string[] fields)
    {
        foreach (var field in fields)
            if (row.TryGetPropertyValue(field, out var value) && value is not null)
                return value.GetValue<long>();
        throw new InvalidOperationException("missing amount field");
    }

    private static string FirstText(JsonObject row, params string[] fields)
    {
        foreach (var field in fields)
        {
            var value = Text(row, field);
            if (value.Length > 0)
                return value;
        }
        throw new InvalidOperationException("missing scriptPubKey field");
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
        throw new InvalidOperationException("could not locate RB workspace root");
    }

    private static string GitCommit(string root)
    {
        try
        {
            using var process = new System.Diagnostics.Process();
            process.StartInfo.FileName = "git";
            process.StartInfo.ArgumentList.Add("rev-parse");
            process.StartInfo.ArgumentList.Add("--short=12");
            process.StartInfo.ArgumentList.Add("HEAD");
            process.StartInfo.WorkingDirectory = root;
            process.StartInfo.RedirectStandardOutput = true;
            process.Start();
            return process.StandardOutput.ReadToEnd().Trim();
        }
        catch
        {
            return "";
        }
    }

    private static string FailureStage(string message)
    {
        var text = message.ToLowerInvariant();
        if (text.Contains("taproot") || text.Contains("tapscript")) return "taproot";
        if (text.Contains("sighash")) return "sighash";
        if (text.Contains("opcode") || text.Contains("op_")) return "opcode";
        if (text.Contains("stack")) return "stack";
        if (text.Contains("template") || text.Contains("scriptpubkey")) return "template";
        if (text.Contains("signature") || text.Contains("secp256k1") || text.Contains("schnorr")) return "crypto";
        return "unknown";
    }
}
