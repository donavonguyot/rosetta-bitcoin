namespace CsBitNode.Storage;

public sealed class DatadirLockBusyException : Exception
{
    public DatadirLockBusyException(string message) : base(message) { }
}

public sealed class DatadirLock : IDisposable
{
    private readonly FileStream? _stream;
    private readonly string _path;

    private DatadirLock(FileStream stream, string path)
    {
        _stream = stream;
        _path = path;
    }

    private DatadirLock(string path)
    {
        _path = path;
    }

    public static DatadirLock Acquire(string dataDir)
    {
        Directory.CreateDirectory(dataDir);
        var path = Path.Combine(dataDir, Config.NodePaths.LockFileName);
        try
        {
            var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            var pidLine = $"{Environment.ProcessId} {Environment.CommandLine}\n";
            stream.SetLength(0);
            using var writer = new StreamWriter(stream, leaveOpen: true);
            writer.Write(pidLine);
            writer.Flush();
            stream.Position = 0;
            return new DatadirLock(stream, path);
        }
        catch (IOException ex)
        {
            throw new DatadirLockBusyException($"datadir lock busy at {path}: {ex.Message}");
        }
    }

    public static DatadirLock Noop(string dataDir) =>
        new(Path.Combine(dataDir, Config.NodePaths.LockFileName));

    public static (bool Busy, int? Pid, string? Command) Inspect(string dataDir)
    {
        var path = Path.Combine(dataDir, Config.NodePaths.LockFileName);
        if (!File.Exists(path))
            return (false, null, null);
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None);
            using var reader = new StreamReader(stream);
            var line = reader.ReadLine() ?? "";
            var parts = line.Split(' ', 2);
            var pid = int.TryParse(parts[0], out var p) ? p : (int?)null;
            return (false, pid, parts.Length > 1 ? parts[1] : null);
        }
        catch (IOException)
        {
            return (true, null, null);
        }
    }

    public void Dispose()
    {
        _stream?.Dispose();
        try { File.Delete(_path); } catch { /* best effort */ }
    }
}
