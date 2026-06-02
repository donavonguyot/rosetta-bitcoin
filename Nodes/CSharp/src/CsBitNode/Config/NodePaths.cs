namespace CsBitNode.Config;

public static class NodePaths
{
    public const string DefaultChain = "testnet4";
    public const string DefaultDataDir = "./data-csharp";
    public const string DbFileName = "csbitnode.db";
    public const string LockFileName = ".csbitnode.lock";

    public static string DataDirFromEnv(string? dataDir) =>
        Path.GetFullPath(dataDir ?? Environment.GetEnvironmentVariable("DATA_DIR") ?? DefaultDataDir);

    public static string DbPathFromEnv(string? dataDir = null, string? dbPath = null)
    {
        if (!string.IsNullOrWhiteSpace(dbPath))
            return Path.GetFullPath(dbPath);
        var dir = DataDirFromEnv(dataDir);
        return Path.Combine(dir, DbFileName);
    }

    public static string ChainFromEnv() =>
        Environment.GetEnvironmentVariable("CHAIN") ?? DefaultChain;
}

public static class PeerConfig
{
    public sealed record PeerEndpoint(string Host, int Port);

    public static IReadOnlyList<PeerEndpoint> ParsePeers(string? peersEnv, int defaultPort)
    {
        var raw = peersEnv ?? Environment.GetEnvironmentVariable("PEERS") ?? "127.0.0.1:48333";
        return raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(part =>
            {
                var idx = part.LastIndexOf(':');
                if (idx <= 0)
                    return new PeerEndpoint(part, defaultPort);
                return new PeerEndpoint(part[..idx], int.Parse(part[(idx + 1)..]));
            })
            .ToList();
    }

    public static int ParseInt(string? value, int defaultValue) =>
        int.TryParse(value, out var parsed) ? parsed : defaultValue;

    public static bool ParseBool(string? value, bool defaultValue) =>
        value switch
        {
            null => defaultValue,
            "" => defaultValue,
            "1" => true,
            "0" => false,
            _ when bool.TryParse(value, out var b) => b,
            _ => defaultValue
        };
}
