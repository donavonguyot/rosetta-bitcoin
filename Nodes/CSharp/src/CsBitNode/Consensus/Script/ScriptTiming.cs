using System.Diagnostics;
using System.Threading;

namespace CsBitNode.Consensus.Script;

internal readonly record struct ScriptTimingSnapshot(
    long LegacySighashTicks,
    long Bip143SighashTicks,
    long TaprootSighashTicks,
    long EcdsaVerifyTicks,
    long SchnorrVerifyTicks,
    long InterpreterEvalTicks)
{
    public ScriptTimingSnapshot Delta(ScriptTimingSnapshot before) =>
        new(
            LegacySighashTicks - before.LegacySighashTicks,
            Bip143SighashTicks - before.Bip143SighashTicks,
            TaprootSighashTicks - before.TaprootSighashTicks,
            EcdsaVerifyTicks - before.EcdsaVerifyTicks,
            SchnorrVerifyTicks - before.SchnorrVerifyTicks,
            InterpreterEvalTicks - before.InterpreterEvalTicks);
}

internal static class ScriptTiming
{
    private static long _legacySighashTicks;
    private static long _bip143SighashTicks;
    private static long _taprootSighashTicks;
    private static long _ecdsaVerifyTicks;
    private static long _schnorrVerifyTicks;
    private static long _interpreterEvalTicks;

    public static ScriptTimingSnapshot Snapshot() =>
        new(
            Interlocked.Read(ref _legacySighashTicks),
            Interlocked.Read(ref _bip143SighashTicks),
            Interlocked.Read(ref _taprootSighashTicks),
            Interlocked.Read(ref _ecdsaVerifyTicks),
            Interlocked.Read(ref _schnorrVerifyTicks),
            Interlocked.Read(ref _interpreterEvalTicks));

    public static T MeasureLegacySighash<T>(Func<T> action) => Measure(ref _legacySighashTicks, action);
    public static T MeasureBip143Sighash<T>(Func<T> action) => Measure(ref _bip143SighashTicks, action);
    public static T MeasureTaprootSighash<T>(Func<T> action) => Measure(ref _taprootSighashTicks, action);
    public static T MeasureEcdsaVerify<T>(Func<T> action) => Measure(ref _ecdsaVerifyTicks, action);
    public static T MeasureSchnorrVerify<T>(Func<T> action) => Measure(ref _schnorrVerifyTicks, action);
    public static void MeasureInterpreterEval(Action action) => Measure(ref _interpreterEvalTicks, action);

    public static void AddLegacySighash(long ticks) => Interlocked.Add(ref _legacySighashTicks, ticks);
    public static void AddBip143Sighash(long ticks) => Interlocked.Add(ref _bip143SighashTicks, ticks);
    public static void AddTaprootSighash(long ticks) => Interlocked.Add(ref _taprootSighashTicks, ticks);
    public static void AddEcdsaVerify(long ticks) => Interlocked.Add(ref _ecdsaVerifyTicks, ticks);
    public static void AddSchnorrVerify(long ticks) => Interlocked.Add(ref _schnorrVerifyTicks, ticks);
    public static void AddInterpreterEval(long ticks) => Interlocked.Add(ref _interpreterEvalTicks, ticks);

    private static T Measure<T>(ref long counter, Func<T> action)
    {
        var started = Stopwatch.GetTimestamp();
        try
        {
            return action();
        }
        finally
        {
            Interlocked.Add(ref counter, Stopwatch.GetTimestamp() - started);
        }
    }

    private static void Measure(ref long counter, Action action)
    {
        var started = Stopwatch.GetTimestamp();
        try
        {
            action();
        }
        finally
        {
            Interlocked.Add(ref counter, Stopwatch.GetTimestamp() - started);
        }
    }
}
