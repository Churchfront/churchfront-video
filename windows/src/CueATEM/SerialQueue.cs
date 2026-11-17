using System.Collections.Concurrent;

namespace CueATEM;

/// <summary>
/// One background thread that runs work in order, like a serial DispatchQueue on the Mac:
/// everything a connection does happens here, so its state needs no locks.
/// </summary>
public sealed class SerialQueue : IDisposable
{
    private readonly BlockingCollection<Action> _work = new();
    private readonly Thread _thread;
    private readonly string _name;

    public SerialQueue(string name)
    {
        _name = name;
        _thread = new Thread(Run) { IsBackground = true, Name = name };
        _thread.Start();
    }

    public bool IsCurrent => Thread.CurrentThread == _thread;

    public void Post(Action a)
    {
        try { _work.Add(a); } catch (InvalidOperationException) { /* shut down */ }
    }

    /// <summary>Runs <paramref name="a"/> on this queue after <paramref name="seconds"/>.</summary>
    public void After(double seconds, Action a)
    {
        Timer? t = null;
        t = new Timer(_ => { t?.Dispose(); Post(a); }, null, TimeSpan.FromSeconds(Math.Max(0, seconds)), Timeout.InfiniteTimeSpan);
    }

    private void Run()
    {
        foreach (var a in _work.GetConsumingEnumerable())
        {
            try { a(); }
            catch (Exception e) { Console.Error.WriteLine($"[{_name}] {e}"); }
        }
    }

    public void Dispose() => _work.CompleteAdding();
}

/// <summary>
/// Where results that the screens show are delivered: the UI thread in the app, a plain
/// background queue in tests and tools. Set <see cref="Poster"/> once at startup.
/// </summary>
public static class MainThread
{
    private static readonly SerialQueue Fallback = new("main");
    public static Action<Action> Poster { get; set; } = Fallback.Post;
    public static Func<bool> IsMainCheck { get; set; } = () => Fallback.IsCurrent;
    public static bool IsMain => IsMainCheck();

    public static void Post(Action a) => Poster(a);

    public static void After(double seconds, Action a)
    {
        Timer? t = null;
        t = new Timer(_ => { t?.Dispose(); Post(a); }, null, TimeSpan.FromSeconds(Math.Max(0, seconds)), Timeout.InfiniteTimeSpan);
    }

    /// <summary>Runs now if already on the main thread, otherwise posts.</summary>
    public static void Run(Action a) { if (IsMain) a(); else Post(a); }
}
