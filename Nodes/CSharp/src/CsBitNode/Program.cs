namespace CsBitNode;

public static class Program
{
    public static int Main(string[] args)
    {
        var tool = Environment.GetEnvironmentVariable("CSBITNODE_TOOL");
        if (tool == "sync" || (args.Length > 0 && args[0] == "sync"))
            return Cli.SyncLocalCoreProgram.Run(Shift(args));
        if (tool == "storage-proof" || args.Contains("--storage-proof"))
            return Cli.StorageProofService.Run(
                Environment.GetEnvironmentVariables()
                    .Cast<System.Collections.DictionaryEntry>()
                    .ToDictionary(e => e.Key.ToString()!, e => e.Value?.ToString()),
                Console.Out);
        if (tool == "storage-proof-seed" || args.Contains("--storage-proof-seed"))
            return Cli.StorageProofService.SeedProofDatadir(
                Environment.GetEnvironmentVariables()
                    .Cast<System.Collections.DictionaryEntry>()
                    .ToDictionary(e => e.Key.ToString()!, e => e.Value?.ToString()),
                Console.Out);
        if (tool == "blocker-diagnostics" || args.Contains("--blocker-diagnostics"))
            return Cli.BlockerDiagnosticsProgram.Run(Shift(args));
        return Cli.NodeStatusProgram.Run(args);
    }

    private static string[] Shift(string[] args) =>
        args.Length > 0 && (args[0] == "sync" || args[0] == "status" || args[0] == "--blocker-diagnostics") ? args[1..] : args;
}
