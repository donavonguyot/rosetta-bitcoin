using System.Diagnostics;

namespace CsBitNode.Sync;

public interface ITimingSink
{
    void Record(string stage, int height, long elapsedTicks);
    void RecordBlockShape(int height, BlockTimingShape shape) { }
}

public sealed record SyncTimingStageSummary(
    long Count,
    long TotalMicros,
    long P50Micros,
    long P95Micros,
    long MaxMicros);

public sealed record BlockTimingShape(
    int TxCount,
    int VinCount,
    int VoutCount,
    int ScriptInputCount,
    IReadOnlyDictionary<string, int> InputShapeCounts,
    IReadOnlyDictionary<string, int> SpentPrevoutScriptTypes,
    IReadOnlyDictionary<string, int> OutputScriptTypes);

public sealed record SlowBlockTimingSummary(
    int Height,
    long Micros,
    int TxCount,
    int VinCount,
    int VoutCount,
    int ScriptInputCount,
    IReadOnlyDictionary<string, int> InputShapeCounts,
    IReadOnlyDictionary<string, int> SpentPrevoutScriptTypes,
    IReadOnlyDictionary<string, int> OutputScriptTypes);

public sealed record SyncTimingSummary(
    string Unit,
    IReadOnlyDictionary<string, SyncTimingStageSummary> Stages,
    IReadOnlyList<SlowBlockTimingSummary>? SlowBlocks = null)
{
    public static SyncTimingSummary Empty { get; } = new("microseconds", new Dictionary<string, SyncTimingStageSummary>());
}

public class SyncTimingCollector : ITimingSink
{
    private readonly Dictionary<string, List<(int Height, long Ticks)>> _ticksByStage = new();
    private readonly Dictionary<int, BlockTimingShape> _blockShapes = new();

    public virtual void Record(string stage, int height, long elapsedTicks)
    {
        if (!_ticksByStage.TryGetValue(stage, out var ticks))
        {
            ticks = [];
            _ticksByStage[stage] = ticks;
        }
        ticks.Add((height, elapsedTicks));
    }

    public virtual void RecordBlockShape(int height, BlockTimingShape shape)
    {
        _blockShapes[height] = shape;
    }

    public IReadOnlyList<long> ValuesMicros(string stage) =>
        _ticksByStage.TryGetValue(stage, out var ticks)
            ? ticks.Select(row => TicksToMicros(row.Ticks)).ToList()
            : [];

    public long TotalMicros(string stage) => ValuesMicros(stage).Sum();

    public SyncTimingSummary Snapshot()
    {
        return new SyncTimingSummary(
            "microseconds",
            _ticksByStage.ToDictionary(
                pair => pair.Key,
                pair =>
                {
                    var micros = pair.Value.Select(row => TicksToMicros(row.Ticks)).OrderBy(value => value).ToArray();
                    return new SyncTimingStageSummary(
                        micros.Length,
                        micros.Sum(),
                        PercentileSorted(micros, 50),
                        PercentileSorted(micros, 95),
                        micros.DefaultIfEmpty(0).Max());
                }),
            SlowBlocks());
    }

    private IReadOnlyList<SlowBlockTimingSummary> SlowBlocks()
    {
        if (!_ticksByStage.TryGetValue("block_connect_store_commit", out var blockTicks))
            return [];
        return blockTicks
            .OrderByDescending(row => row.Ticks)
            .Take(10)
            .Select(row =>
            {
                _blockShapes.TryGetValue(row.Height, out var shape);
                shape ??= new BlockTimingShape(0, 0, 0, 0, new Dictionary<string, int>(), new Dictionary<string, int>(), new Dictionary<string, int>());
                return new SlowBlockTimingSummary(
                    row.Height,
                    TicksToMicros(row.Ticks),
                    shape.TxCount,
                    shape.VinCount,
                    shape.VoutCount,
                    shape.ScriptInputCount,
                    shape.InputShapeCounts,
                    shape.SpentPrevoutScriptTypes,
                    shape.OutputScriptTypes);
            })
            .ToList();
    }

    public static long TicksToMicros(long elapsedTicks) =>
        (long)Math.Round(elapsedTicks * 1_000_000.0 / Stopwatch.Frequency);

    public static long TicksToMillis(long elapsedTicks) =>
        (long)Math.Round(elapsedTicks * 1_000.0 / Stopwatch.Frequency);

    private static long PercentileSorted(IReadOnlyList<long> sortedValues, int percentile)
    {
        if (sortedValues.Count == 0)
            return 0;
        var index = (int)Math.Ceiling((percentile / 100.0) * sortedValues.Count) - 1;
        return sortedValues[Math.Clamp(index, 0, sortedValues.Count - 1)];
    }
}
