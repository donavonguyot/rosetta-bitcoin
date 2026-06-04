using System.Diagnostics;

namespace CsBitNode.Sync;

public interface ITimingSink
{
    void Record(string stage, int height, long elapsedTicks);
}

public sealed record SyncTimingStageSummary(
    long Count,
    long TotalMicros,
    long P50Micros,
    long P95Micros,
    long MaxMicros);

public sealed record SyncTimingSummary(
    string Unit,
    IReadOnlyDictionary<string, SyncTimingStageSummary> Stages)
{
    public static SyncTimingSummary Empty { get; } = new("microseconds", new Dictionary<string, SyncTimingStageSummary>());
}

public class SyncTimingCollector : ITimingSink
{
    private readonly Dictionary<string, List<long>> _ticksByStage = new();

    public virtual void Record(string stage, int height, long elapsedTicks)
    {
        if (!_ticksByStage.TryGetValue(stage, out var ticks))
        {
            ticks = [];
            _ticksByStage[stage] = ticks;
        }
        ticks.Add(elapsedTicks);
    }

    public IReadOnlyList<long> ValuesMicros(string stage) =>
        _ticksByStage.TryGetValue(stage, out var ticks)
            ? ticks.Select(TicksToMicros).ToList()
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
                    var micros = pair.Value.Select(TicksToMicros).OrderBy(value => value).ToArray();
                    return new SyncTimingStageSummary(
                        micros.Length,
                        micros.Sum(),
                        PercentileSorted(micros, 50),
                        PercentileSorted(micros, 95),
                        micros.DefaultIfEmpty(0).Max());
                }));
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
